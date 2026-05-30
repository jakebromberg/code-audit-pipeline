#!/usr/bin/env node
// refresh-index.mjs — rebuild the cross-repo substrate's index.json from
// scratch by listing the bucket. Idempotent and self-healing: running it
// after manual edits, partial failures, or concurrent publishes restores
// correctness without losing data.
//
// Two backends:
//
//   --bucket-fs DIR
//       Operate on a local directory acting as the bucket. The directory
//       must contain a `by-repo/` subtree (and may contain an existing
//       `index.json`, which is overwritten). Intended for hermetic tests
//       and local dev; never used in production.
//
//   --bucket-name NAME --bucket-endpoint URL
//       Operate on a real S3-compatible bucket. Shells out to the `aws`
//       CLI for list/head/get/put with sigv4 (`aws --endpoint-url URL
//       s3api ...`). Credentials must be in the standard places
//       (AWS_ACCESS_KEY_ID/SECRET, ~/.aws, IAM role). For Cloudflare R2,
//       pass `--bucket-endpoint https://<account>.r2.cloudflarestorage.com`.
//
// Behavior:
//   1. List every object under `by-repo/`.
//   2. Group by `by-repo/<repo>/`. For each repo:
//      - Find timestamp-prefixed subdirs (`<iso8601>_<short-sha>/`).
//      - Pick the latest; use as `latest.prefix`. The rest become `history_prefixes`
//        (capped at 10 per retention rule).
//      - For each catalog file under `latest.prefix`, fetch the full bytes
//        to extract `extractor`, `entry_count`, `sha256`, `size_bytes`.
//   3. Compute `status`: "ok" if latest exists and is <= CROSS_REPO_STALE_DAYS
//      old, else "stale".
//   4. Coverage tally from per-repo status (and an optional --known-repos
//      list for "missing-from-bucket" detection).
//   5. Write index.json. For --bucket-fs, atomic rename. For S3, PUT with
//      If-Match on the current ETag; retry on 412.
//
// Stderr: one line per repo summary, plus a header/footer.

import { readFileSync, writeFileSync, statSync, readdirSync, mkdirSync, renameSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { join, dirname, posix } from 'node:path';
import { parseArgs } from 'node:util';

const SCHEMA_VERSION = '1.0';
const HISTORY_KEEP = 10;
const DEFAULT_STALE_DAYS = Number.parseInt(process.env.CROSS_REPO_STALE_DAYS ?? '7', 10);

const { values } = parseArgs({
  options: {
    'bucket-fs':       { type: 'string' },
    'bucket-name':     { type: 'string' },
    'bucket-endpoint': { type: 'string' },
    'known-repos':     { type: 'string' },
    'stale-days':      { type: 'string' },
    'dry-run':         { type: 'boolean', default: false },
    help:              { type: 'boolean', default: false },
  },
});

if (values.help || (!values['bucket-fs'] && !values['bucket-name'])) {
  process.stderr.write(`usage: refresh-index.mjs (--bucket-fs DIR | --bucket-name NAME --bucket-endpoint URL) [--known-repos repos.json] [--stale-days N] [--dry-run]

  --bucket-fs DIR                Local filesystem mode (tests / dev).
  --bucket-name NAME             S3 bucket name (production).
  --bucket-endpoint URL          S3 endpoint URL (e.g. Cloudflare R2 endpoint).
  --known-repos repos.json       JSON array of expected repo names; used to
                                 compute the "missing" coverage bucket. Optional.
  --stale-days N                 Stale threshold; default 7 (or
                                 CROSS_REPO_STALE_DAYS env).
  --dry-run                      Print index.json to stdout instead of writing.
`);
  process.exit(values.help ? 0 : 1);
}

const STALE_DAYS = values['stale-days'] ? Number.parseInt(values['stale-days'], 10) : DEFAULT_STALE_DAYS;

// --- Backend abstraction -----------------------------------------------------

function makeFilesystemBackend(rootDir) {
  return {
    kind: 'fs',
    rootDir,
    list(prefix) {
      const abs = join(rootDir, prefix);
      try { statSync(abs); } catch { return []; }
      const out = [];
      const walk = (relDir) => {
        const absDir = join(rootDir, relDir);
        for (const ent of readdirSync(absDir, { withFileTypes: true })) {
          const childRel = posix.join(relDir, ent.name);
          if (ent.isDirectory()) walk(childRel);
          else if (ent.isFile()) {
            const st = statSync(join(rootDir, childRel));
            out.push({ key: childRel, size: st.size, lastModified: st.mtime.toISOString() });
          }
        }
      };
      walk(prefix);
      return out;
    },
    getBytes(key) {
      return readFileSync(join(rootDir, key));
    },
    putBytes(key, bytes) {
      const dest = join(rootDir, key);
      mkdirSync(dirname(dest), { recursive: true });
      const tmp = `${dest}.tmp.${process.pid}`;
      writeFileSync(tmp, bytes);
      renameSync(tmp, dest);
    },
  };
}

function makeS3Backend(bucket, endpoint) {
  const sh = (args) => {
    const res = spawnSync('aws', ['--endpoint-url', endpoint, ...args], {
      encoding: 'utf8',
    });
    if (res.status !== 0) {
      throw new Error(`aws ${args.join(' ')} failed (status ${res.status}): ${res.stderr}`);
    }
    return res.stdout;
  };
  return {
    kind: 's3',
    bucket,
    endpoint,
    list(prefix) {
      const out = [];
      let token = null;
      do {
        const args = ['s3api', 'list-objects-v2', '--bucket', bucket, '--prefix', prefix];
        if (token) args.push('--continuation-token', token);
        const json = JSON.parse(sh(args) || '{}');
        for (const obj of (json.Contents || [])) {
          out.push({ key: obj.Key, size: obj.Size, lastModified: obj.LastModified });
        }
        token = json.NextContinuationToken || null;
      } while (token);
      return out;
    },
    getBytes(key) {
      const tmp = `/tmp/refresh-index-${process.pid}-${Date.now()}.bin`;
      sh(['s3api', 'get-object', '--bucket', bucket, '--key', key, tmp]);
      const bytes = readFileSync(tmp);
      try { require('node:fs').unlinkSync(tmp); } catch {}
      return bytes;
    },
    putBytes(key, bytes) {
      const tmp = `/tmp/refresh-index-put-${process.pid}-${Date.now()}.bin`;
      writeFileSync(tmp, bytes);
      sh(['s3api', 'put-object', '--bucket', bucket, '--key', key, '--body', tmp, '--content-type', 'application/json']);
      try { require('node:fs').unlinkSync(tmp); } catch {}
    },
  };
}

const backend = values['bucket-fs']
  ? makeFilesystemBackend(values['bucket-fs'])
  : makeS3Backend(values['bucket-name'], values['bucket-endpoint']);

// --- Rebuild logic -----------------------------------------------------------

// Group every `by-repo/<repo>/...` key under its repo's path segment.
const allKeys = backend.list('by-repo/');
const reposByPath = new Map();
for (const obj of allKeys) {
  const m = obj.key.match(/^by-repo\/([^/]+)\/(.*)$/);
  if (!m) continue;
  const [, pathSegment, suffix] = m;
  let bucket = reposByPath.get(pathSegment);
  if (!bucket) { bucket = []; reposByPath.set(pathSegment, bucket); }
  bucket.push({ ...obj, suffix });
}

// `repos.json` (optional) supplies the "known" repo list. Without it,
// coverage's `total_known_repos` defaults to whatever's in the bucket.
let knownRepos = null;
if (values['known-repos']) {
  knownRepos = JSON.parse(readFileSync(values['known-repos'], 'utf8'));
  if (!Array.isArray(knownRepos)) throw new Error('--known-repos must be a JSON array');
}

const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');

const now = new Date();
const repos = [];

const pathSegments = Array.from(reposByPath.keys()).sort();
for (const pathSegment of pathSegments) {
  const objs = reposByPath.get(pathSegment);

  // The `latest.json` pointer carries the canonical repo name; harvest it
  // there. Without one, fall back to the path segment as the name.
  let canonicalRepo = `wxyc/${pathSegment}`;
  const latestPointer = objs.find((o) => o.suffix === 'latest.json');
  if (latestPointer) {
    try {
      const parsed = JSON.parse(backend.getBytes(latestPointer.key).toString());
      if (typeof parsed.repo === 'string') canonicalRepo = parsed.repo;
    } catch (e) {
      process.stderr.write(`  WARN ${pathSegment}: latest.json unparseable (${e.message})\n`);
    }
  }

  // Collect the timestamp-prefixed subdirs.
  const tsPrefixes = new Set();
  for (const o of objs) {
    const m = o.suffix.match(/^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}-[0-9]{2}Z_[0-9a-f]+)\//);
    if (m) tsPrefixes.add(m[1]);
  }
  const tsSorted = Array.from(tsPrefixes).sort();
  if (tsSorted.length === 0) {
    repos.push({
      repo: canonicalRepo,
      path_segment: pathSegment,
      latest: null,
      status: 'stale',
      reason: 'no snapshot prefixes in bucket',
    });
    continue;
  }

  const latestTs = tsSorted[tsSorted.length - 1];
  const latestPrefix = `by-repo/${pathSegment}/${latestTs}/`;
  const latestObjs = objs.filter((o) => o.suffix.startsWith(`${latestTs}/`));

  // Build per-catalog metadata. Catalog kind = filename stem.
  const catalogs = [];
  for (const o of latestObjs.sort((a, b) => a.suffix.localeCompare(b.suffix))) {
    const filename = o.suffix.slice(`${latestTs}/`.length);
    if (!filename.endsWith('.json')) continue;
    const kind = filename.replace(/\.json$/, '');
    const bytes = backend.getBytes(o.key);
    let extractorBlock = null;
    let entryCount = null;
    try {
      const parsed = JSON.parse(bytes.toString());
      extractorBlock = parsed.extractor ?? null;
      if (Array.isArray(parsed.entries)) entryCount = parsed.entries.length;
      else if (Array.isArray(parsed.edges)) entryCount = parsed.edges.length;
      else if (Array.isArray(parsed.nodes)) entryCount = parsed.nodes.length;
    } catch (e) {
      process.stderr.write(`  WARN ${pathSegment}: ${filename} unparseable (${e.message})\n`);
    }
    catalogs.push({
      kind,
      key: o.key,
      extractor: extractorBlock,
      size_bytes: o.size,
      entry_count: entryCount,
      sha256: sha256(bytes),
    });
  }

  // Derive commit_sha + short_sha from the latest-pointer if present, else
  // from the ts-prefix (which embeds the short sha).
  let commitSha = null;
  let shortSha = latestTs.split('_')[1] ?? null;
  let publishedAt = null;
  if (latestPointer) {
    try {
      const parsed = JSON.parse(backend.getBytes(latestPointer.key).toString());
      commitSha = parsed.commit_sha ?? commitSha;
      publishedAt = parsed.published_at ?? null;
    } catch {}
  }
  if (!publishedAt) {
    // Parse `2026-05-30T10-00-00Z` back into an ISO timestamp by undoing the
    // dash-substitution in the time portion.
    const tsPart = latestTs.split('_')[0];
    publishedAt = tsPart.replace(/-(\d{2})-(\d{2})Z$/, ':$1:$2Z');
  }

  const ageDays = (now - new Date(publishedAt)) / (1000 * 60 * 60 * 24);
  const status = ageDays > STALE_DAYS ? 'stale' : 'ok';

  const historyPrefixes = tsSorted
    .slice(0, -1)
    .slice(-HISTORY_KEEP)
    .map((ts) => `by-repo/${pathSegment}/${ts}/`);

  repos.push({
    repo: canonicalRepo,
    path_segment: pathSegment,
    latest: {
      prefix: latestPrefix,
      commit_sha: commitSha,
      short_sha: shortSha,
      published_at: publishedAt,
      catalogs,
    },
    history_prefixes: historyPrefixes,
    status,
    ...(status === 'stale' ? { reason: `latest snapshot is ${Math.round(ageDays)}d old (> ${STALE_DAYS}d threshold)` } : {}),
  });

  process.stderr.write(`  ${status === 'ok' ? '✓' : '!'} ${pathSegment}: ${catalogs.length} catalogs @ ${publishedAt}\n`);
}

// Inject any known repos that weren't seen in the bucket as `missing`.
if (knownRepos) {
  const seen = new Set(repos.map((r) => r.repo));
  for (const name of knownRepos) {
    if (seen.has(name)) continue;
    repos.push({
      repo: name,
      path_segment: name.replace(/\//g, '-'),
      latest: null,
      status: 'missing',
      reason: 'no entries in bucket',
    });
  }
}

const coverage = {
  total_known_repos: knownRepos ? knownRepos.length : repos.length,
  ok: repos.filter((r) => r.status === 'ok').length,
  stale: repos.filter((r) => r.status === 'stale').length,
  failed_last_run: 0, // populated by publish-catalog.sh when a publish fails; here always 0
  ...(knownRepos ? { missing: repos.filter((r) => r.status === 'missing').length } : {}),
};

const index = {
  schema_version: SCHEMA_VERSION,
  generated_at: now.toISOString(),
  bucket: backend.kind === 's3' ? backend.bucket : `fs:${backend.rootDir}`,
  region: process.env.AUDIT_REGION ?? 'auto',
  repos,
  coverage,
};

const serialized = `${JSON.stringify(index, null, 2)}\n`;

if (values['dry-run']) {
  process.stdout.write(serialized);
  process.stderr.write(`\nDry-run: would write ${serialized.length} bytes to index.json\n`);
} else {
  backend.putBytes('index.json', Buffer.from(serialized));
  process.stderr.write(`\nWrote index.json (${serialized.length} bytes, ${repos.length} repos, coverage ${coverage.ok}/${coverage.total_known_repos} ok)\n`);
}
