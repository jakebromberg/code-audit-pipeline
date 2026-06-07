#!/usr/bin/env node
// pre-commit-audit.mjs — non-blocking pre-commit hook for catalog-relevant changes.
//
// Scope: child of #120, refining #124. Invoked by the `pre-commit` framework
// via the repo's `.pre-commit-hooks.yaml`. Pure Node, no shell wrapper.
//
// Flow (issue §functional 4, summarized):
//   a. Take staged files from argv (pre-commit `pass_filenames: true`); fall
//      back to `git diff --cached --name-only -z` if argv is empty.
//   b. Pipe through the type-extractor's `--list-relevant` predicate (#159).
//   c. Drop paths marked `linguist-generated=true` via `git check-attr`.
//   d. If empty: silent exit 0.
//   e. Check `.git/audit/catalog.{json,meta.json}` validity (mtimes + 24h TTL).
//   f. On hit, run the three cluster queries (exact-duplicates,
//      name-collisions, near-duplicates) against the cached catalog in
//      JSONL mode via `jq`, filter to rows that touch a staged file.
//   g. On miss, rebuild the full-repo catalog by invoking the extractor.
//      If the estimated cost is > 5s, spawn the rebuild detached and exit 0
//      (the next commit benefits).
//   h. Write `.git/audit/last-report.md`, print a 3-line digest, exit 0.
//
// Invariants:
//   - Always exits 0 (issue §non-goals 1). Any uncaught exception, extractor
//     crash, jq error, or wall-clock overrun degrades to "skipped" mode.
//   - Strictly offline. No network. No telemetry.
//   - TypeScript only at MVP.
//   - Honors `.gitattributes linguist-generated` and predicate skip-dirs.
//
// See `docs/integrations/pre-commit-hook.md` for the user-facing rationale.

import { spawn, spawnSync } from 'node:child_process';
import {
  mkdirSync,
  writeFileSync,
  appendFileSync,
  readFileSync,
  existsSync,
  statSync,
  unlinkSync,
  renameSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HOOK_DIR = dirname(fileURLToPath(import.meta.url));
const PIPELINE_ROOT = resolve(HOOK_DIR, '..');

// ─── Wall-clock guard ─────────────────────────────────────────────────────
// Hard ceiling: if the synchronous path hasn't exited by 5s, force exit 0.
// This is the last-ditch defense against extractor pathology in real repos.
// Cleared by `cleanExit` before normal exit so the timer doesn't keep the
// event loop alive past the work.

const WALL_CLOCK_MS = 5000;
const wallClockTimer = setTimeout(() => {
  process.stderr.write('code-audit: skipped (wall-clock budget exceeded)\n');
  process.exit(0);
}, WALL_CLOCK_MS).unref();

function cleanExit(code = 0) {
  clearTimeout(wallClockTimer);
  process.exit(code);
}

// ─── Configuration ────────────────────────────────────────────────────────

const SCHEMA_VERSION = '1.1';
const CACHE_TTL_MS = 24 * 60 * 60 * 1000;

// Test seam: override the cold-path-per-file cost estimate. Used by tests
// that need to force the detached-rebuild branch without seeding a large repo.
const COLD_PATH_OVERRIDE_MS = process.env.CODE_AUDIT_COLD_PATH_PER_FILE_MS;

// Cold-path cost estimate: ~25ms per file for the type-catalog extractor on
// a typical repo. If `nFiles * COLD_PATH_PER_FILE_MS > WALL_CLOCK_MS`, defer
// to a detached rebuild and exit immediately. Overridable by the test seam
// `CODE_AUDIT_COLD_PATH_PER_FILE_MS` so the detached branch can be exercised
// against a small fixture repo.
const COLD_PATH_PER_FILE_MS = COLD_PATH_OVERRIDE_MS
  ? Number(COLD_PATH_OVERRIDE_MS)
  : 25;

const EXTRACTOR_DEFAULT = join(
  PIPELINE_ROOT,
  'extractors',
  'typescript',
  'type-catalog.mjs',
);
const EXTRACTOR_PATH = process.env.CODE_AUDIT_EXTRACTOR || EXTRACTOR_DEFAULT;
const QUERIES_DIR = process.env.CODE_AUDIT_QUERIES_DIR || join(PIPELINE_ROOT, 'pipeline', 'queries');
const NEAR_DUP_THRESHOLD = process.env.CODE_AUDIT_NEAR_DUP_THRESHOLD || '0.7';
const TIMING_ENABLED = process.env.CODE_AUDIT_TIMING === '1';
const INCLUDE_TESTS = process.env.CODE_AUDIT_INCLUDE_TESTS === '1';

// `CODE_AUDIT_FAKE_BARE_REPO=1` is a test seam: forces the hook into the
// "no .git" defensive branch even when one exists. Used by integration tests
// to verify the never-block contract.
const FAKE_BARE = process.env.CODE_AUDIT_FAKE_BARE_REPO === '1';

// `CODE_AUDIT_REBUILD_ONLY=1` is the entrypoint mode used by the detached
// rebuild subprocess (see spawnDetachedRebuild). When set, the hook does not
// process a staged file list — it just runs buildCatalog() against the repo
// root, which writes catalog.json + catalog.meta.json atomically (tmp + rename),
// then exits. Keeping the rebuild inside this file (instead of invoking the
// extractor directly from the parent) preserves two invariants the inline
// extractor invocation cannot: atomic catalog write, and the meta file getting
// written at all — without which isCacheValid would never accept the rebuild's
// output and every subsequent commit would re-take the detached branch.
const REBUILD_ONLY = process.env.CODE_AUDIT_REBUILD_ONLY === '1';

const QUERIES = [
  { id: 'exact-duplicates', path: join(QUERIES_DIR, 'exact-duplicates.jq'), args: [] },
  { id: 'name-collisions',  path: join(QUERIES_DIR, 'name-collisions.jq'),  args: [] },
  { id: 'near-duplicates',  path: join(QUERIES_DIR, 'near-duplicates.jq'),  args: ['--argjson', 'threshold', NEAR_DUP_THRESHOLD] },
];

// ─── Exported helpers (consumed by hooks/test/unit.test.mjs) ──────────────

/**
 * Read staged paths from argv (preferred, used by the pre-commit framework
 * via `pass_filenames: true`) or fall back to `git diff --cached --name-only -z`
 * when invoked outside the framework. Returns repo-root-relative paths.
 *
 * Stdin support is not currently wired — the pre-commit framework always
 * passes filenames via argv, and the `git diff` fallback covers ad-hoc
 * invocation. The `stdin` parameter is retained as a future seam but
 * accepted as `null` by every current caller.
 */
export async function parseArgvOrStdin(argv, { stdin = null, repoRoot = null } = {}) {
  if (Array.isArray(argv) && argv.length > 0) return argv;
  if (!repoRoot) return [];
  const res = spawnSync('git', ['diff', '--cached', '--name-only', '-z'], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
  if (res.status !== 0) return [];
  return res.stdout.split('\0').filter(Boolean);
}

/**
 * Cluster-touched join: true iff at least one member of the cluster (or one
 * endpoint of a pair) touches a file in `touchedSet`.
 *
 * Cluster envelope shapes per ADR-0003 / `_canonical.jq` header:
 *   shape: "cluster" → `members[].file`
 *   shape: "pair"    → `left.file` / `right.file`
 *   shape: "metric"  → never touched-filtered (no member set)
 *
 * Returns false defensively for malformed rows so the digest renderer
 * doesn't have to special-case bad input.
 */
export function isClusterTouched(row, touchedSet) {
  if (!row || typeof row !== 'object') return false;
  if (row.shape === 'cluster' && Array.isArray(row.members)) {
    return row.members.some((m) => m && touchedSet.has(m.file));
  }
  if (row.shape === 'pair') {
    if (row.left && touchedSet.has(row.left.file)) return true;
    if (row.right && touchedSet.has(row.right.file)) return true;
    return false;
  }
  return false;
}

/**
 * Build a `{ relPath: mtimeMs }` map for the given relative paths (rooted
 * at `repoRoot`). Missing files are silently dropped — common when a
 * deletion is staged but the file no longer exists on disk.
 */
export function computeMtimeMap(repoRoot, relPaths) {
  const out = {};
  for (const p of relPaths) {
    try {
      const st = statSync(join(repoRoot, p));
      out[p] = st.mtimeMs;
    } catch {
      // missing — skip
    }
  }
  return out;
}

// ─── Internal helpers ─────────────────────────────────────────────────────

function findRepoRoot(startDir) {
  const res = spawnSync('git', ['rev-parse', '--show-toplevel'], {
    cwd: startDir,
    encoding: 'utf8',
  });
  if (res.status !== 0) return null;
  return res.stdout.trim();
}

function gitDir(repoRoot) {
  const res = spawnSync('git', ['rev-parse', '--git-dir'], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
  if (res.status !== 0) return join(repoRoot, '.git');
  const out = res.stdout.trim();
  return out.startsWith('/') ? out : join(repoRoot, out);
}

function skipped(reason) {
  process.stderr.write(`code-audit: skipped (${reason})\n`);
  cleanExit(0);
}

function logTiming(repoRoot, line) {
  if (!TIMING_ENABLED) return;
  try {
    const auditDir = join(gitDir(repoRoot), 'audit');
    mkdirSync(auditDir, { recursive: true });
    const stamp = new Date().toISOString();
    // appendFileSync avoids the O(N) read+rewrite cost as timing.log grows;
    // a developer running the hook hundreds of times a week would otherwise
    // pay an increasing per-commit penalty just to record the timing line.
    appendFileSync(join(auditDir, 'timing.log'), `${stamp} ${line}\n`);
  } catch {
    // Never let timing instrumentation break the hook.
  }
}

/**
 * Run the extractor's --list-relevant mode against a list of paths.
 * Returns the kept subset. On any extractor error, returns null (the
 * caller short-circuits to "skipped" mode).
 */
function listRelevant(paths) {
  if (paths.length === 0) return [];
  const args = ['--list-relevant'];
  if (INCLUDE_TESTS) args.push('--include-tests');
  const res = spawnSync('node', [EXTRACTOR_PATH, ...args], {
    input: paths.join('\n') + '\n',
    encoding: 'utf8',
  });
  if (res.error || res.status !== 0) return null;
  return res.stdout.split('\n').filter(Boolean);
}

/**
 * Filter out paths marked `linguist-generated=true` in `.gitattributes`.
 * The shared `--list-relevant` predicate does not currently honor this
 * attribute (see docs/plans/159-implementation.md §"Behavior gap"); the
 * hook applies the filter directly. Falls back to the unfiltered list on
 * any git invocation failure (the hook's never-block contract).
 */
function dropLinguistGenerated(repoRoot, paths) {
  if (paths.length === 0) return paths;
  const res = spawnSync(
    'git',
    ['check-attr', '-z', 'linguist-generated', '--stdin'],
    {
      cwd: repoRoot,
      input: paths.join('\0'),
      encoding: 'utf8',
    },
  );
  if (res.status !== 0) return paths; // defensive
  // Output is NUL-separated triples: <path>\0<attr>\0<value>\0...
  const parts = res.stdout.split('\0');
  const generated = new Set();
  for (let i = 0; i + 2 < parts.length; i += 3) {
    const path = parts[i];
    // parts[i+1] is 'linguist-generated'
    const value = parts[i + 2];
    if (value === 'true' || value === 'set') generated.add(path);
  }
  return paths.filter((p) => !generated.has(p));
}

/**
 * Enumerate every relevant TypeScript file in the repo using the
 * extractor's `--list-relevant` predicate plus `git ls-files`. Used to
 * compute the cache's full mtime map. Falls back to a best-effort empty
 * list on git invocation failure.
 */
function enumerateRelevantRepoFiles(repoRoot) {
  const res = spawnSync('git', ['ls-files', '-z'], {
    cwd: repoRoot,
    encoding: 'utf8',
  });
  if (res.status !== 0) return [];
  const all = res.stdout.split('\0').filter(Boolean);
  const kept = listRelevant(all);
  if (!kept) return [];
  return dropLinguistGenerated(repoRoot, kept);
}

function loadCachedMeta(auditDir) {
  const metaPath = join(auditDir, 'catalog.meta.json');
  if (!existsSync(metaPath)) return null;
  try {
    return JSON.parse(readFileSync(metaPath, 'utf8'));
  } catch {
    return null;
  }
}

/**
 * Validate the cached catalog against the live repo state.
 *   1. schema_version must match the extractor's.
 *   2. extractor_version must match.
 *   3. built_at must be within CACHE_TTL_MS.
 *   4. Every currently-relevant file's mtime must be <= cached mtime.
 *   5. No file appearing in the live repo may be absent from cached mtimes.
 *
 * Returns { valid: boolean, reason?: string }.
 */
function isCacheValid(meta, repoRoot, relevantFiles, extractorVersion) {
  if (!meta) return { valid: false, reason: 'no-meta' };
  if (meta.schema_version !== SCHEMA_VERSION) return { valid: false, reason: 'schema-version' };
  if (meta.extractor_version !== extractorVersion) return { valid: false, reason: 'extractor-version' };
  if (typeof meta.built_at !== 'number') return { valid: false, reason: 'no-built-at' };
  if (Date.now() - meta.built_at > CACHE_TTL_MS) return { valid: false, reason: 'ttl-expired' };
  if (!meta.mtimes || typeof meta.mtimes !== 'object') return { valid: false, reason: 'no-mtimes' };

  for (const rel of relevantFiles) {
    const cached = meta.mtimes[rel];
    if (cached === undefined) return { valid: false, reason: `new-file:${rel}` };
    let liveMtime;
    try {
      liveMtime = statSync(join(repoRoot, rel)).mtimeMs;
    } catch {
      continue; // file deleted; not a freshness violation
    }
    // Allow tiny epsilon for filesystem timestamp granularity.
    if (liveMtime - cached > 1) return { valid: false, reason: `stale:${rel}` };
  }
  return { valid: true };
}

function getExtractorVersion() {
  try {
    const pkg = JSON.parse(readFileSync(
      join(dirname(EXTRACTOR_PATH), 'package.json'),
      'utf8',
    ));
    return pkg.version;
  } catch {
    return 'unknown';
  }
}

/**
 * Build the full-repo catalog by invoking the extractor against repoRoot.
 * Writes catalog + meta atomically (write to .tmp, rename). Returns
 * { catalogPath, meta } or null on failure.
 */
function buildCatalog(repoRoot, auditDir, relevantFiles, extractorVersion) {
  mkdirSync(auditDir, { recursive: true });
  const catalogPath = join(auditDir, 'catalog.json');
  const metaPath = join(auditDir, 'catalog.meta.json');
  const tmpCatalog = catalogPath + '.tmp';

  const res = spawnSync('node', [
    EXTRACTOR_PATH,
    '--root', repoRoot,
    '--output', tmpCatalog,
  ], { encoding: 'utf8' });
  if (res.error || res.status !== 0) {
    try { unlinkSync(tmpCatalog); } catch { /* ignore */ }
    return null;
  }

  // Rename to final (atomic on same filesystem, which `.git/audit/` always is).
  try {
    renameSync(tmpCatalog, catalogPath);
  } catch {
    try { unlinkSync(tmpCatalog); } catch { /* ignore */ }
    return null;
  }

  const meta = {
    schema_version: SCHEMA_VERSION,
    extractor_version: extractorVersion,
    built_at: Date.now(),
    mtimes: computeMtimeMap(repoRoot, relevantFiles),
  };
  writeFileSync(metaPath, JSON.stringify(meta));
  return { catalogPath, meta };
}

/**
 * Detach a background process that rebuilds the catalog. Used when the
 * estimated cold-path cost exceeds the wall-clock budget. The next commit
 * benefits; this commit goes through without delay.
 *
 * The detached process is THIS hook file, re-invoked with
 * `CODE_AUDIT_REBUILD_ONLY=1`. That branch runs `buildCatalog`, which writes
 * `catalog.json` and `catalog.meta.json` atomically (tmp + rename) — both
 * are required so `isCacheValid` will accept the rebuild's output on the
 * NEXT commit. Spawning the extractor directly with `--output catalog.json`
 * would skip the meta-write entirely and leave the cache permanently
 * invalid, defeating the "next commit benefits" promise.
 *
 * `cwd` is set to `repoRoot` so the rebuild subprocess's findRepoRoot() lands
 * on the same repo as the parent.
 */
function spawnDetachedRebuild(repoRoot) {
  try {
    const child = spawn('node', [fileURLToPath(import.meta.url)], {
      cwd: repoRoot,
      env: { ...process.env, CODE_AUDIT_REBUILD_ONLY: '1' },
      detached: true,
      stdio: 'ignore',
    });
    child.unref();
  } catch {
    // Best-effort; if the spawn itself fails, the next commit will try
    // again on the synchronous path.
  }
}

/**
 * Run jq against the catalog in JSONL mode, returning parsed rows.
 * On jq failure returns null (caller skips that query gracefully).
 */
function runQuery(query, catalogPath) {
  const res = spawnSync('jq', [
    '-L', QUERIES_DIR,
    '-r',
    ...query.args,
    '-f', query.path,
    catalogPath,
  ], {
    encoding: 'utf8',
    env: { ...process.env, OUTPUT_FORMAT: 'jsonl' },
  });
  if (res.error || res.status !== 0) return null;
  const rows = [];
  for (const line of res.stdout.split('\n')) {
    if (!line) continue;
    try {
      rows.push(JSON.parse(line));
    } catch {
      // Skip malformed rows (shouldn't happen with -r + @json, but defensive).
    }
  }
  return rows;
}

/**
 * Render the digest + full report. Digest is the 3-line summary printed to
 * stderr (so it doesn't pollute any caller capturing stdout); the full
 * report is written to `last-report.md`.
 */
function renderAndWrite(auditDir, results, touchedRel) {
  const reportLines = [];
  reportLines.push('# code-audit pre-commit report');
  reportLines.push('');
  reportLines.push(`Generated: ${new Date().toISOString()}`);
  reportLines.push(`Touched files (${touchedRel.length}):`);
  for (const p of touchedRel) reportLines.push(`  - ${p}`);
  reportLines.push('');

  const summary = {
    'exact-duplicates': 0,
    'name-collisions': 0,
    'near-duplicates': 0,
  };

  for (const { query, rows } of results) {
    summary[query] = rows.length;
    reportLines.push(`## ${query} (${rows.length})`);
    reportLines.push('');
    if (rows.length === 0) {
      reportLines.push('_no touched clusters_');
      reportLines.push('');
      continue;
    }
    for (const row of rows) {
      reportLines.push(`- \`${row.cluster_id || query}\``);
      if (row.shape === 'cluster' && row.members) {
        for (const m of row.members) {
          reportLines.push(`    - \`${m.package || 'main'}:${m.file}:${m.line || '?'}\` (\`${m.kind || row.query}\`)`);
        }
      } else if (row.shape === 'pair') {
        const lf = row.left || {};
        const rf = row.right || {};
        if (typeof row.jacc === 'number') {
          reportLines.push(`    - jaccard=${row.jacc.toFixed(2)}`);
        }
        reportLines.push(`    - left:  \`${lf.package || 'main'}:${lf.file}:${lf.line || '?'}\` (\`${lf.name || ''}\`)`);
        reportLines.push(`    - right: \`${rf.package || 'main'}:${rf.file}:${rf.line || '?'}\` (\`${rf.name || ''}\`)`);
      }
    }
    reportLines.push('');
  }

  const reportPath = join(auditDir, 'last-report.md');
  writeFileSync(reportPath, reportLines.join('\n'));

  // 3-line digest (issue §summary). Printed only when there's at least one
  // cluster — silence on a clean diff is the desired UX.
  const total = summary['exact-duplicates'] + summary['name-collisions'] + summary['near-duplicates'];
  if (total > 0) {
    process.stderr.write(
      `code-audit: ${total} cluster(s) touch staged files ` +
      `(exact=${summary['exact-duplicates']} name-coll=${summary['name-collisions']} near=${summary['near-duplicates']})\n` +
      `code-audit: full report at .git/audit/last-report.md\n` +
      `code-audit: non-blocking — commit proceeding\n`,
    );
  }
  return summary;
}

// ─── Main ─────────────────────────────────────────────────────────────────

async function main() {
  const t0 = Date.now();

  const cwd = process.cwd();
  const repoRoot = FAKE_BARE ? null : findRepoRoot(cwd);
  if (!repoRoot) {
    // Not a git repo (or test seam triggered). Bail silently — pre-commit
    // can be invoked in odd contexts; the never-block contract trumps.
    return cleanExit(0);
  }
  const auditDir = join(gitDir(repoRoot), 'audit');

  // Detached-rebuild entrypoint mode: parent commit decided the cold-path
  // cost was too high to do inline, and re-invoked this script with
  // CODE_AUDIT_REBUILD_ONLY=1. Just rebuild the catalog + meta and exit.
  // No staged-file processing, no jq queries, no digest.
  if (REBUILD_ONLY) {
    const extractorVersion = getExtractorVersion();
    const repoFiles = enumerateRelevantRepoFiles(repoRoot);
    buildCatalog(repoRoot, auditDir, repoFiles, extractorVersion);
    return cleanExit(0);
  }

  // argv[2..] is the pre-commit framework's filename list.
  const argvFiles = process.argv.slice(2);
  let staged;
  try {
    staged = await parseArgvOrStdin(argvFiles, { repoRoot });
  } catch {
    return skipped('argv-parse');
  }

  // Pipe through --list-relevant. The predicate is the source of truth for
  // "what the extractor would index"; the hook MUST mirror it exactly.
  const relevant = listRelevant(staged);
  if (relevant === null) return skipped('extractor-list-relevant');
  const stagedRelevant = dropLinguistGenerated(repoRoot, relevant);

  if (stagedRelevant.length === 0) {
    logTiming(repoRoot, `total_ms=${Date.now() - t0} verdict=no-relevant`);
    return cleanExit(0);
  }

  const extractorVersion = getExtractorVersion();
  const repoFiles = enumerateRelevantRepoFiles(repoRoot);

  // Cache check.
  const meta = loadCachedMeta(auditDir);
  const cacheCheck = isCacheValid(meta, repoRoot, repoFiles, extractorVersion);

  let catalogPath = join(auditDir, 'catalog.json');

  if (!cacheCheck.valid) {
    // Estimate cold-path cost. If it exceeds the wall-clock budget by a
    // safety margin, defer to a detached rebuild and exit immediately.
    const estimateMs = repoFiles.length * COLD_PATH_PER_FILE_MS;
    const elapsedSoFar = Date.now() - t0;
    if (estimateMs + elapsedSoFar > WALL_CLOCK_MS) {
      spawnDetachedRebuild(repoRoot);
      process.stderr.write('code-audit: cache rebuild in background\n');
      logTiming(repoRoot, `total_ms=${Date.now() - t0} verdict=detached estimate_ms=${estimateMs} files=${repoFiles.length}`);
      return cleanExit(0);
    }
    const built = buildCatalog(repoRoot, auditDir, repoFiles, extractorVersion);
    if (!built) return skipped('extractor-build');
    catalogPath = built.catalogPath;
  }

  if (!existsSync(catalogPath)) return skipped('no-catalog');

  // Run the three cluster queries. Each is independently fault-tolerant:
  // a single query failure doesn't sink the digest.
  const touchedSet = new Set(stagedRelevant);
  const results = [];
  for (const q of QUERIES) {
    const rows = runQuery(q, catalogPath);
    if (rows === null) {
      // Skip this query but keep the others.
      results.push({ query: q.id, rows: [] });
      continue;
    }
    const filtered = rows.filter((row) => isClusterTouched(row, touchedSet));
    results.push({ query: q.id, rows: filtered });
  }

  // Ensure auditDir exists before writing the report (cache-hit path
  // might've skipped buildCatalog, which is where mkdirSync usually fires).
  mkdirSync(auditDir, { recursive: true });
  const summary = renderAndWrite(auditDir, results, stagedRelevant);

  logTiming(
    repoRoot,
    `total_ms=${Date.now() - t0} verdict=ok cache=${cacheCheck.valid ? 'hit' : 'miss'} ` +
    `staged=${stagedRelevant.length} exact=${summary['exact-duplicates']} ` +
    `name-coll=${summary['name-collisions']} near=${summary['near-duplicates']}`,
  );

  return cleanExit(0);
}

// Top-level guard + entrypoint: only fire when invoked as a script, not when
// imported by the unit test suite. import.meta.main lands in Node 24+; fall
// back to comparing argv[1] for older Node so the same file works on the
// Node 20 CI image and Node 26 dev machines.
const IS_ENTRYPOINT = (typeof import.meta.main === 'boolean')
  ? import.meta.main
  : (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1]));

if (IS_ENTRYPOINT) {
  process.on('uncaughtException', (err) => {
    process.stderr.write(`code-audit: skipped (uncaught: ${err.message || err})\n`);
    cleanExit(0);
  });
  process.on('unhandledRejection', (err) => {
    process.stderr.write(`code-audit: skipped (rejection: ${err?.message || err})\n`);
    cleanExit(0);
  });

  main().catch((err) => {
    process.stderr.write(`code-audit: skipped (main: ${err.message || err})\n`);
    cleanExit(0);
  });
} else {
  // Importer (e.g. unit tests) — defuse the wall-clock guard so the timer
  // doesn't keep the test process alive past its own work.
  clearTimeout(wallClockTimer);
}
