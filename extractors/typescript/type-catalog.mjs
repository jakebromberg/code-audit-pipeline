#!/usr/bin/env node
// type-catalog.mjs
//
// Walks every .ts / .tsx source file under --root (and optionally --shared) and emits
// one JSON record per declared type / interface / Zod schema / Drizzle table.
// Each record carries a deterministic `shape_sig` so downstream cluster queries
// can group duplicates with `jq`.
//
// See ../../docs/pipeline-contract.md for the emitted schema.

import ts from 'typescript';
import { readFileSync, writeFileSync, readdirSync, existsSync, statSync, realpathSync } from 'node:fs';
import { join, relative, resolve, dirname, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import { createHash } from 'node:crypto';
import { execSync } from 'node:child_process';
import { homedir } from 'node:os';
import {
  BUILTIN_TYPE_DENYLIST,
  extractReferences,
  genericsList,
  getLeftmostIdentifierText,
  pushNamedRef,
  refsForDecl,
} from './_lib/references.mjs';
import { isTestPath } from './_lib/paths.mjs';
import { EXT_RE, SKIP_DIRS, streamRelevantPaths } from './_lib/walk-predicate.mjs';
import { compareBy } from './_lib/sort.mjs';
import { writeSiblingArtifact } from './_lib/artifacts.mjs';
import { resolveOriginPackage } from './_lib/origin-package.mjs';

const EXTRACTOR_DIR = dirname(fileURLToPath(import.meta.url));
const EXTRACTOR_VERSION = JSON.parse(readFileSync(join(EXTRACTOR_DIR, 'package.json'), 'utf8')).version;
const SCHEMA_VERSION = '2.0';
const FINGERPRINT_V = 'shape_sig:1';
const LANGUAGE = 'typescript';

// Compute extractor source_sha once at startup. Shells out to git; falls back
// to "unknown" with a stderr warning when the extractor source isn't in a
// git checkout (vendored binary, embedded-and-extracted via `code-audit init`,
// or git missing from PATH).
//
// The challenge: when the extractor is laid down under ~/.config/audit/
// extractors/typescript/ (the embedded-install path from `code-audit init`)
// and the user's $HOME is itself a git checkout (dotfiles, home-manager),
// a naive `git rev-parse HEAD` walks up the directory tree and returns the
// dotfiles HEAD, silently misattributing source_sha to an unrelated repo.
//
// Solution: walk up from EXTRACTOR_DIR ourselves. At each ancestor, run
// `git rev-parse --show-toplevel`; the FIRST ancestor whose toplevel equals
// itself IS the extractor's own repo root, and we read its HEAD. Stop the
// walk at $HOME (or filesystem root, or a defensive depth bound) — anything
// at or above $HOME is by construction NOT the extractor's repo. The
// dotfiles case (`$HOME/.git`) is never reached because the loop exits at
// $HOME. The normal in-repo case (`<repo>/extractors/typescript/`) finds
// the toplevel at `<repo>` within two hops. The embedded case
// (`~/.config/audit/extractors/typescript/`) walks up to `.config`, none
// of those levels is a git toplevel, then exits at $HOME and returns
// "unknown" as intended.
//
// Per-call options:
//   timeout: 2000ms — without this, a slow or disconnected network FS
//     hosting the search path would hang the extractor at module load
//     with no diagnostic on stderr.
//   GIT_TERMINAL_PROMPT=0 — prevents git from prompting for credentials
//     on any auxiliary config-fetch.
function computeSourceSha() {
  const env = { ...process.env, GIT_TERMINAL_PROMPT: '0' };
  const baseOpts = {
    stdio: ['ignore', 'pipe', 'ignore'],
    encoding: 'utf8',
    timeout: 2000,
    env,
  };
  // Both ends must be in the same canonical form for the equality check below
  // to fire. `import.meta.url` is realpath-resolved by Node when modules load,
  // but `homedir()` returns $HOME verbatim — which on macOS may be `/tmp/...`
  // while realpath produces `/private/tmp/...`, or may carry a trailing slash.
  // Apply realpath to both sides (with a try/catch so a non-existent HOME from
  // a stripped env doesn't crash the extractor before it can warn).
  let home;
  try {
    home = realpathSync(homedir());
  } catch {
    home = homedir();
  }
  let dir;
  try {
    dir = realpathSync(EXTRACTOR_DIR);
  } catch {
    dir = EXTRACTOR_DIR;
  }
  // Defensive depth bound: no realistic project nests deeper than 16 levels
  // under HOME. Loop also exits at $HOME and at the filesystem root.
  for (let i = 0; i < 16; i++) {
    if (!dir || dir === home) break;
    try {
      const toplevel = execSync('git rev-parse --show-toplevel', {
        ...baseOpts,
        cwd: dir,
      }).trim();
      if (toplevel === dir) {
        const sha = execSync('git rev-parse HEAD', {
          ...baseOpts,
          cwd: dir,
        }).trim();
        if (/^[0-9a-f]{40}$/.test(sha)) return sha;
        return unknownSha();
      }
    } catch {
      // not a git dir at this level, or git unavailable; keep walking
    }
    const parent = dirname(dir);
    if (parent === dir) break; // filesystem root
    dir = parent;
  }
  return unknownSha();
}
function unknownSha() {
  process.stderr.write('warning: extractor source not in a git checkout; source_sha recorded as "unknown"\n');
  return 'unknown';
}
const SOURCE_SHA = computeSourceSha();

// One ISO-8601 timestamp per extraction run, shared across every sibling
// artifact emitted by this invocation.
const GENERATED_AT = new Date().toISOString();

// Compute symbol_id per entry. sha1 over (package, file, name, kind) joined
// by NUL bytes (\x00), lowercase hex. See docs/pipeline-contract.md
// "Identity and provenance" for the formal definition.
//
// Why NUL and not `/`: package values legitimately contain forward slashes
// (`Shared/Generated`, `Shared/Analytics`; first-class throughout the
// fixtures and _canonical.jq), and file paths obviously do. A `/`-joined
// formula is not injective — e.g. (package="Shared", file="Generated/X.ts",
// name="X", kind="interface") and (package="Shared/Generated", file="X.ts",
// name="X", kind="interface") flatten to the same string and hash to the
// same sha1, silently merging unrelated entries when cross-repo joins use
// symbol_id as the key. NUL cannot appear in identifiers (every host
// language rejects it in symbol names) and cannot appear in file paths
// (POSIX path separators and identifier rules both exclude it). The choice
// is structurally collision-safe rather than collision-rare.
function computeSymbolId(pkg, file, name, kind) {
  return createHash('sha1').update(`${pkg}\x00${file}\x00${name}\x00${kind}`).digest('hex');
}

// Standard filter-CLI EPIPE handling: a downstream consumer closing the pipe
// (`… | head -1`) shouldn't surface as a stack trace. Set before any write.
process.stdout.on('error', (err) => {
  if (err.code === 'EPIPE') process.exit(0);
  throw err;
});

const { values } = parseArgs({
  options: {
    root:                    { type: 'string' },
    shared:                  { type: 'string' },
    touched:                 { type: 'string' },
    output:                  { type: 'string' },
    'emit-references-graph': { type: 'string' },
    'emit-files':            { type: 'string' },
    'include-imports':       { type: 'boolean', default: false },
    'list-relevant':         { type: 'boolean', default: false },
    'include-tests':         { type: 'boolean', default: false },
    // `-0`/`--null` follows the xargs/find/grep convention for NUL-separated
    // I/O. Node's parseArgs accepts a digit as a short alias.
    'null':                  { type: 'boolean', short: '0', default: false },
    help:                    { type: 'boolean', default: false },
  },
});

const EXTRACTION_FLAGS = ['root', 'shared', 'touched', 'output',
  'emit-references-graph', 'emit-files', 'include-imports'];
const QUERY_FLAGS = ['include-tests', 'null'];

// --help is matched first so `--list-relevant --help` still prints usage.
// Then validate mode/flag pairing so a typo (`--null` without `--list-relevant`,
// or `--root foo --list-relevant`) errors loudly instead of being silently inert.
if (values.help) {
  printUsage(0);
} else if (values['list-relevant']) {
  const stray = EXTRACTION_FLAGS.filter((f) => values[f] !== undefined && values[f] !== false);
  if (stray.length > 0) {
    process.stderr.write(
      `error: --list-relevant is a pure-query mode; the following extraction flags do not apply: ${stray.map((f) => `--${f}`).join(', ')}\n`,
    );
    process.exit(2);
  }
  // --list-relevant: pure-query mode. Reads candidate paths from stdin, applies
  // the walk predicate, prints kept paths to stdout. No --root required, no file
  // parsing. See docs/plans/159-implementation.md.
  try {
    await streamRelevantPaths(process.stdin, process.stdout, {
      includeTests: values['include-tests'],
      nullSeparated: values.null,
    });
  } catch (err) {
    if (err.code !== 'EPIPE') {
      process.stderr.write(`error: --list-relevant: ${err.message}\n`);
      process.exit(1);
    }
  }
  process.exit(0);
} else {
  const stray = QUERY_FLAGS.filter((f) => values[f]);
  if (stray.length > 0) {
    process.stderr.write(
      `error: ${stray.map((f) => `--${f}`).join(', ')} only apply in --list-relevant mode\n`,
    );
    process.exit(2);
  }
}

if (!values.root) {
  printUsage(1);
}

function printUsage(exitCode) {
  process.stderr.write(`usage: type-catalog.mjs --root <path> [--shared <path>] [--touched <json>] [--output <path>] [--emit-references-graph <path>] [--emit-files <path>] [--include-imports]
       type-catalog.mjs --list-relevant [--include-tests] [--null|-0]    # pure-query mode (no --root)

  --root           Required. Root of the codebase to scan.
  --shared         Optional. A secondary package root (canonical types you compare
                   against). Tagged as package="shared" in output.
  --touched        Optional. Path to a JSON array of file paths (relative to --root)
                   to mark as touched_in_window=true.
  --output         Optional. Write JSON to this path. Default: stdout.
  --emit-references-graph <path>
                   Optional. Write a sibling references.json artifact
                   (per docs/pipeline-contract.md §sibling artifacts) to
                   <path>. The file contains an inverted edge list keyed by
                   (package, name); resolution prefers same-package targets,
                   falls back to the shared package, then marks unresolved.
  --emit-files <path>
                   Optional. Write a sibling files.json artifact
                   (per docs/pipeline-contract.md §files artifact) to <path>.
                   The file contains one row per source file with its resolved
                   import / re-export / dynamic-import edges, package-tagged
                   (main / shared / extern). Consumed by the
                   cross-package-backward-imports.jq query (and the future
                   cycle-detection, unused-imports, dependency-mass-per-file
                   queries).
  --include-imports
                   Optional. Emit one \`kind: "import"\` row in the catalog per
                   imported symbol — consumer-edge data for cross-repo queries
                   like consumers-of (#156). Off by default so legacy queries
                   stay byte-stable. See docs/pipeline-contract.md §"Import rows".
  --list-relevant  Optional. Pure-query mode: read candidate paths from stdin,
                   print the subset the walker would visit. No --root required,
                   no file parsing. Use \`--include-tests\` to keep test/spec
                   paths; \`--null\`/\`-0\` for NUL-separated I/O.
                   Consumed by the PR-comment Action (#123) and the pre-commit
                   hook (#124). Example:
                     git diff --name-only main...HEAD \\
                       | node extractors/typescript/type-catalog.mjs --list-relevant
  --include-tests  Optional. With --list-relevant, keep test/spec/fixture/mock
                   paths in the output. (The extraction walker indexes tests
                   regardless; this flag only affects --list-relevant queries.)
  --null, -0       Optional. With --list-relevant, use NUL ('\\0') as the input
                   and output separator instead of newline.

Output: {"schema_version": "${SCHEMA_VERSION}", "extractor": {...}, "entries": [...]}.
Queries that consume the catalog must read from .entries (see _canonical.jq's
"entries" helper, which also accepts the legacy bare-array form for one release).

Test files are always extracted; every row carries an \`is_test\` flag derived
from the file path. To exclude tests post-hoc, pipe through:
  jq '.entries | map(select(.is_test | not))'
`);
  process.exit(exitCode);
}

const ROOT = resolve(values.root);
const SHARED = values.shared ? resolve(values.shared) : null;
const TOUCHED = values.touched
  ? new Set(JSON.parse(readFileSync(values.touched, 'utf8')))
  : new Set();

// SKIP_DIRS and the walk predicate are imported from _lib/walk-predicate.mjs
// so the in-extractor walk and the --list-relevant CLI query stay in lock-step.

// BUILTIN_TYPE_DENYLIST, extractReferences, pushNamedRef, refsForDecl,
// getLeftmostIdentifierText, genericsList are imported from _lib/references.mjs
// (shared with function-catalog.mjs).

// --- Sibling-shared-package detection (warning only) ---

function findSharedCandidates(root) {
  // Look one level up from --root for sibling directories that look like a shared
  // types package: name matches *shared* (case-insensitive) OR package.json `name` matches,
  // and has a `src/` subdirectory.
  const parent = dirname(root);
  const selfName = basename(root);
  let entries;
  try { entries = readdirSync(parent, { withFileTypes: true }); } catch { return []; }
  const matches = [];
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    if (e.name === selfName) continue;
    if (e.name.startsWith('.')) continue;
    const dirPath = join(parent, e.name);
    const srcPath = join(dirPath, 'src');
    if (!existsSync(srcPath)) continue;
    const pkgPath = join(dirPath, 'package.json');
    let pkgName = null;
    if (existsSync(pkgPath)) {
      try { pkgName = JSON.parse(readFileSync(pkgPath, 'utf8')).name ?? null; }
      catch { /* ignore */ }
    }
    const nameSignal = /shared/i.test(e.name) || (pkgName && /shared/i.test(pkgName));
    if (nameSignal) matches.push({ srcPath, dirName: e.name, pkgName });
  }
  return matches;
}

if (!SHARED) {
  const candidates = findSharedCandidates(ROOT);
  if (candidates.length > 0) {
    process.stderr.write(
      `WARNING: --shared was not passed, but ${candidates.length} sibling shared-package candidate(s) ` +
      `were detected. Cross-package shadowing will be undetectable without --shared. Candidates:\n`
    );
    for (const c of candidates) {
      const pkgLabel = c.pkgName ? ` (package "${c.pkgName}")` : '';
      process.stderr.write(`  --shared ${c.srcPath}${pkgLabel}\n`);
    }
    process.stderr.write('\n');
  }
}

function walkDir(root) {
  const out = [];
  function walk(dir) {
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); }
    catch { return; }
    for (const e of entries) {
      const full = join(dir, e.name);
      if (e.isDirectory()) {
        // Skip dotdirs (.git, .claude, .cursor, .idea, .vscode, .next, …) — they
        // typically hold IDE/agent state, generated artifacts, or worktree clones
        // that would inflate the catalog with near-duplicate copies of the same repo.
        if (e.name.startsWith('.')) continue;
        if (SKIP_DIRS.has(e.name)) continue;
        walk(full);
      } else if (e.isFile()) {
        if (!EXT_RE.test(e.name)) continue;
        out.push(full);
      }
    }
  }
  walk(root);
  return out;
}

const normalize = (s) => (s ?? '').replace(/\s+/g, ' ').trim();
const shapeSig = (fields) => [...fields].sort().join('|').toLowerCase();
const typeSig = (text) => normalize(text).toLowerCase();

// Test-path classification. Pattern set is normative — duplicated verbatim in
// docs/pipeline-contract.md so other-language extractors (#115) stay aligned.
// isTestPath imported from _lib/paths.mjs (shared with function-catalog).

// --- Identifier-occurrence counter (for reference_count, grep-approximation) ---
const idCounts = new Map();
function countIdentifiers(text) {
  // Capture identifiers (letter or underscore start). Strings and comments are not stripped —
  // we accept the noise; reference_count is a coarse signal, not a precise one.
  for (const m of text.matchAll(/\b[A-Za-z_][A-Za-z0-9_]*\b/g)) {
    const id = m[0];
    idCounts.set(id, (idCounts.get(id) || 0) + 1);
  }
}

function membersToFields(members, sf, opts) {
  // opts: { ownerName, emitSynthetic, rowDefaults } — when present, nested
  // TypeLiteralNodes on properties emit synthetic catalog entries inheriting
  // their parent record's per-file defaults (package/file/touched/generated/is_test).
  return members
    .filter((m) => ts.isPropertySignature(m) && m.name)
    .map((m) => {
      const name = m.name.getText(sf);
      const optional = m.questionToken ? '?' : '';
      const typeNode = m.type;
      const typeText = typeNode ? normalize(typeNode.getText(sf)) : 'any';
      if (opts && typeNode && ts.isTypeLiteralNode(typeNode)) {
        const propBase = name.replace(/\?$/, '');
        const innerName = `${opts.ownerName}.${propBase}`;
        const innerFields = membersToFields(typeNode.members, sf, { ...opts, ownerName: innerName });
        const { line } = sf.getLineAndCharacterOfPosition(typeNode.getStart(sf));
        opts.emitSynthetic({
          ...opts.rowDefaults,
          line: line + 1,
          name: innerName,
          kind: 'inline-object',
          exported: false,
          generics: null,
          fields: innerFields,
          shape_sig: shapeSig(innerFields),
          extends: [],
          references: [],
          references_count: 0,
          synthetic: true,
          parent: opts.ownerName,
        });
      }
      return `${name}${optional}:${typeText}`;
    });
}

function extractZodObjectFields(arg, sf) {
  if (!arg || !ts.isObjectLiteralExpression(arg)) return null;
  return arg.properties
    .filter((p) => ts.isPropertyAssignment(p) || ts.isShorthandPropertyAssignment(p))
    .map((p) => {
      const fname = p.name.getText(sf);
      const ftype = ts.isPropertyAssignment(p)
        ? normalize(p.initializer.getText(sf)).slice(0, 120)
        : 'shorthand';
      return `${fname}:${ftype}`;
    });
}

function extractDrizzleTableFields(arg, sf) {
  if (!arg || !ts.isObjectLiteralExpression(arg)) return null;
  return arg.properties
    .filter((p) => ts.isPropertyAssignment(p))
    .map((p) => {
      const fname = p.name.getText(sf);
      let cur = p.initializer;
      let baseType = 'unknown';
      // Walk a call chain like `integer('id').primaryKey().notNull()` down to `integer`
      while (cur && ts.isCallExpression(cur)) {
        const callee = cur.expression;
        if (ts.isPropertyAccessExpression(callee)) {
          cur = callee.expression;
        } else {
          baseType = callee.getText(sf);
          break;
        }
      }
      if (baseType === 'unknown' && cur && ts.isIdentifier(cur)) baseType = cur.text;
      return `${fname}:${baseType}`;
    });
}

function isZodObjectCall(call) {
  const callee = call.expression;
  if (!ts.isPropertyAccessExpression(callee)) return false;
  if (callee.name.text !== 'object') return false;
  const base = callee.expression;
  return ts.isIdentifier(base) && base.text === 'z';
}

function isDrizzleTableCall(call) {
  const callee = call.expression;
  if (ts.isIdentifier(callee) && callee.text === 'pgTable') return true;
  if (ts.isPropertyAccessExpression(callee)) {
    if (callee.name.text === 'table' || callee.name.text === 'pgTable') return true;
  }
  return false;
}

function isInferModelType(typeNode, sf) {
  // Modern Drizzle API: `typeof T.$inferSelect` / `typeof T.$inferInsert`. These
  // are TypeQueryNodes (TypeQueryNode → QualifiedName) rather than TypeReferenceNodes,
  // so the legacy InferSelectModel<typeof T> branch below won't see them.
  if (ts.isTypeQueryNode(typeNode) && ts.isQualifiedName(typeNode.exprName)) {
    const prop = typeNode.exprName.right.text;
    if (prop === '$inferSelect' || prop === '$inferInsert') {
      return { kind: prop, table: typeNode.exprName.left.getText(sf) };
    }
  }
  if (!ts.isTypeReferenceNode(typeNode)) return null;
  const refName = typeNode.typeName.getText(sf);
  if (refName !== 'InferSelectModel' && refName !== 'InferInsertModel') return null;
  const args = typeNode.typeArguments;
  if (!args || args.length === 0) return null;
  const arg = args[0];
  if (ts.isTypeQueryNode(arg)) return { kind: refName, table: arg.exprName.getText(sf) };
  return { kind: refName, table: arg.getText(sf) };
}

function exportedMod(node) {
  return !!node.modifiers?.some((m) => m.kind === ts.SyntaxKind.ExportKeyword);
}

// Heritage-clause supertype names for `interface X extends A, B {}`. Returns a
// sorted, deduplicated array of names. `implements` clauses are ignored (TS
// doesn't model implementation as a supertype edge on the declaring side).
//
// Qualified expressions (`extends Namespace.Foo`) round-trip the full dotted
// source text rather than splitting — rare in practice, and the downstream
// resolution pass handles the `(package, name)` lookup uniformly via the
// leftmost identifier.
function extractExtendsFromInterface(node, sf) {
  if (!node.heritageClauses) return [];
  const names = new Set();
  for (const clause of node.heritageClauses) {
    if (clause.token !== ts.SyntaxKind.ExtendsKeyword) continue;
    for (const ewta of clause.types) {
      const expr = ewta.expression;
      if (ts.isIdentifier(expr)) names.add(expr.text);
      else names.add(normalize(expr.getText(sf)));
    }
  }
  return [...names].sort();
}

// --- Per-file import edge resolver (for --emit-files / files.json) ---
//
// The walker itself lives inside extractFromFile so the type-extraction
// recursion can collect dynamic-import calls in the same pass (one tree
// walk per file, not two). What's down here is just the resolver and the
// existence cache it shares across the whole run.
//
// Resolution: relative paths only in v1 (no tsconfig.json `paths` aliases —
// docs/pipeline-contract.md §files artifact spells out the v1 scope).

const RESOLVE_EXTENSIONS = ['.ts', '.tsx', '.mts', '.cts'];

// Memoized across the whole extractor run: the same target gets probed
// repeatedly (every file that imports './shared/x' produces the same set
// of candidates). On a 300-file repo with ~10 imports/file, this collapses
// ~27k stat calls down to ~3k unique paths.
const _existsCache = new Map();
function isExistingFile(absPath) {
  const cached = _existsCache.get(absPath);
  if (cached !== undefined) return cached;
  const stat = statSync(absPath, { throwIfNoEntry: false });
  const result = stat ? stat.isFile() : false;
  _existsCache.set(absPath, result);
  return result;
}

// POSIX-only guard: `relative()` never returns a leading "/" on Linux/macOS,
// so the `!rel.startsWith('/')` clause is dead here. It's kept defensively
// because `path.relative` does return absolute-looking strings on Windows
// when the inputs share no drive root.
function isUnderDir(absPath, dirPath) {
  if (!dirPath) return false;
  const rel = relative(dirPath, absPath);
  return rel !== '' && !rel.startsWith('..') && !rel.startsWith('/');
}

function resolveImportSpec(spec, fromFilePath) {
  if (!spec.startsWith('.')) {
    return { package: 'extern', path: spec };
  }
  const baseAbs = resolve(dirname(fromFilePath), spec);
  // Matches Node's resolver order for TS: exact, then each extension,
  // then each /index.<ext>. First hit wins.
  const candidates = [baseAbs];
  for (const ext of RESOLVE_EXTENSIONS) candidates.push(baseAbs + ext);
  for (const ext of RESOLVE_EXTENSIONS) candidates.push(join(baseAbs, 'index' + ext));
  for (const c of candidates) {
    if (!isExistingFile(c)) continue;
    if (isUnderDir(c, ROOT)) return { package: 'main', path: relative(ROOT, c) };
    if (isUnderDir(c, SHARED)) return { package: 'shared', path: relative(SHARED, c) };
    return { package: 'extern', path: c };
  }
  return { package: 'extern', path: spec };
}

function extractFromFile(filePath, pkgName, pkgRoot, { collectImports, includeImports }) {
  const text = readFileSync(filePath, 'utf8');
  countIdentifiers(text);
  const isTsx = filePath.endsWith('.tsx');
  const sf = ts.createSourceFile(
    filePath,
    text,
    ts.ScriptTarget.Latest,
    true,
    isTsx ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  );
  const relPath = relative(pkgRoot, filePath);
  // touched_in_window meaningful only for main package
  const rowDefaults = {
    package: pkgName,
    file: relPath,
    touched_in_window: pkgName === 'main' && TOUCHED.has(relPath),
    generated: /(^|\/)generated\//.test(relPath) || relPath.endsWith('.d.ts'),
    is_test: isTestPath(relPath),
  };
  const results = [];
  const emitSynthetic = (entry) => results.push(entry);
  // null when --emit-files is off — short-circuits the dynamic-import branch
  // inside visit() below.
  const rawImports = collectImports ? [] : null;

  // Per-symbol `kind: "import"` rows for the type-catalog (gated on
  // --include-imports). Top-level static imports + re-exports are emitted
  // here, ahead of visit(sf) — so within a file the row order is:
  //   1) every top-level import/re-export in source-line order, then
  //   2) declaration + dynamic-import + require rows in AST-walk order.
  // Both halves are deterministic, which is what the catalog contract
  // actually depends on.
  function emitImportRowsForDecl(stmt, specifier, importForm) {
    const declTypeOnly = importForm === 're-export'
      ? stmt.isTypeOnly === true
      : stmt.importClause?.isTypeOnly === true;
    const { origin_package, origin_resolution } = resolveOriginPackage(specifier);
    const pushImport = (extra) => {
      pushBase(stmt, {
        kind: 'import',
        exported: false,
        origin_specifier: specifier,
        origin_package,
        origin_resolution,
        ...extra,
      });
    };

    if (importForm === 're-export') {
      const ec = stmt.exportClause;
      if (!ec) {
        pushImport({ name: '*', imported_as: '*', import_form: 're-export', type_only: declTypeOnly });
      } else if (ts.isNamespaceExport(ec)) {
        pushImport({ name: '*', imported_as: ec.name.text, import_form: 're-export', type_only: declTypeOnly });
      } else if (ts.isNamedExports(ec)) {
        for (const spec of ec.elements) {
          const localName = spec.name.text;
          const originName = spec.propertyName ? spec.propertyName.text : localName;
          pushImport({
            name: originName,
            imported_as: localName,
            import_form: 're-export',
            type_only: declTypeOnly || spec.isTypeOnly === true,
          });
        }
      }
      return;
    }

    const clause = stmt.importClause;
    if (!clause) {
      pushImport({ name: null, imported_as: null, import_form: 'side-effect', type_only: false });
      return;
    }
    let emittedAny = false;
    if (clause.name) {
      pushImport({ name: 'default', imported_as: clause.name.text, import_form: 'default', type_only: declTypeOnly });
      emittedAny = true;
    }
    const nb = clause.namedBindings;
    if (nb && ts.isNamespaceImport(nb)) {
      pushImport({ name: '*', imported_as: nb.name.text, import_form: 'namespace', type_only: declTypeOnly });
      emittedAny = true;
    } else if (nb && ts.isNamedImports(nb)) {
      for (const spec of nb.elements) {
        const localName = spec.name.text;
        const originName = spec.propertyName ? spec.propertyName.text : localName;
        pushImport({
          name: originName,
          imported_as: localName,
          import_form: 'named',
          type_only: declTypeOnly || spec.isTypeOnly === true,
        });
        emittedAny = true;
      }
    }
    // `import {} from "pkg"` parses as a named-imports clause with zero
    // elements — semantically equivalent to a side-effect import. Treat it
    // as such so the consumer edge to `pkg` is still recorded.
    if (!emittedAny) {
      pushImport({ name: null, imported_as: null, import_form: 'side-effect', type_only: false });
    }
  }

  // Dynamic `import(spec)` and `require(spec)` rows. Both live inside visit()
  // because they can appear anywhere in the tree.
  function emitDynamicImportRow(callNode, specifierOrNull) {
    const specifier = specifierOrNull ?? '<computed>';
    const { origin_package, origin_resolution } = specifierOrNull
      ? resolveOriginPackage(specifierOrNull)
      : { origin_package: null, origin_resolution: 'computed' };
    pushBase(callNode, {
      name: '*',
      imported_as: null,
      kind: 'import',
      exported: false,
      import_form: 'dynamic',
      origin_specifier: specifier,
      origin_package,
      origin_resolution,
      type_only: false,
    });
  }

  function emitRequireRows(callNode, specifier) {
    const { origin_package, origin_resolution } = resolveOriginPackage(specifier);
    const pushRequire = (extra) => {
      pushBase(callNode, {
        kind: 'import',
        exported: false,
        import_form: 'require',
        origin_specifier: specifier,
        origin_package,
        origin_resolution,
        type_only: false,
        ...extra,
      });
    };
    const parent = callNode.parent;
    if (parent && ts.isVariableDeclaration(parent)) {
      if (ts.isObjectBindingPattern(parent.name)) {
        let emittedAny = false;
        for (const el of parent.name.elements) {
          if (!ts.isIdentifier(el.name)) continue; // skip nested binding patterns in v1
          const localName = el.name.text;
          const originName = el.propertyName && ts.isIdentifier(el.propertyName)
            ? el.propertyName.text
            : localName;
          pushRequire({ name: originName, imported_as: localName });
          emittedAny = true;
        }
        if (emittedAny) return;
        // Destructure consists entirely of nested binding patterns
        // (`const {a:{b}} = require('pkg')`). Fall through to the bare-call
        // form so at least the package consumer edge is recorded.
      } else if (ts.isIdentifier(parent.name)) {
        pushRequire({ name: '*', imported_as: parent.name.text });
        return;
      }
    }
    // Bare-call require() or unsupported binding pattern: record as namespace
    // form with no local alias.
    pushRequire({ name: '*', imported_as: null });
  }

  if (collectImports || includeImports) {
    for (const stmt of sf.statements) {
      if (ts.isImportDeclaration(stmt) && stmt.moduleSpecifier && ts.isStringLiteral(stmt.moduleSpecifier)) {
        const { line } = sf.getLineAndCharacterOfPosition(stmt.getStart(sf));
        const spec = stmt.moduleSpecifier.text;
        if (collectImports) {
          rawImports.push({
            kind: 'import',
            spec,
            type_only: stmt.importClause?.isTypeOnly === true,
            line: line + 1,
          });
        }
        if (includeImports) {
          emitImportRowsForDecl(stmt, spec, 'static');
        }
      } else if (ts.isExportDeclaration(stmt) && stmt.moduleSpecifier && ts.isStringLiteral(stmt.moduleSpecifier)) {
        const { line } = sf.getLineAndCharacterOfPosition(stmt.getStart(sf));
        const spec = stmt.moduleSpecifier.text;
        if (collectImports) {
          rawImports.push({
            kind: 're-export',
            spec,
            type_only: stmt.isTypeOnly === true,
            line: line + 1,
          });
        }
        if (includeImports) {
          emitImportRowsForDecl(stmt, spec, 're-export');
        }
      }
    }
  }

  function pushBase(node, partial) {
    const { line } = sf.getLineAndCharacterOfPosition(node.getStart(sf));
    const refs = partial.references ?? [];
    results.push({
      ...rowDefaults,
      line: line + 1,
      ...partial,
      extends: partial.extends ?? [],
      // `conforms_to` is the protocol/interface-implementation axis (issue
      // #217). The TS extractor doesn't currently emit class declarations
      // as type records, so `implements` clauses have no decl to attach
      // to — every TS row carries `conforms_to: []` for shape uniformity
      // with the Swift extractor and for forward-compat with any future TS
      // class-emission pass. See docs/pipeline-contract.md § "Heritage split
      // convention".
      conforms_to: partial.conforms_to ?? [],
      references: refs,
      references_count: refs.length,
    });
  }

  function visit(node) {
    if (ts.isInterfaceDeclaration(node)) {
      const fields = membersToFields(node.members, sf, {
        ownerName: node.name.text,
        emitSynthetic,
        rowDefaults,
      });
      const generics = genericsList(node);
      const extendsList = extractExtendsFromInterface(node, sf);
      const referencesList = refsForDecl(node, sf, node.members);
      pushBase(node, {
        name: node.name.text,
        kind: 'interface',
        exported: exportedMod(node),
        generics,
        fields,
        shape_sig: shapeSig(fields),
        extends: extendsList,
        references: referencesList,
      });
    }

    if (ts.isTypeAliasDeclaration(node)) {
      const generics = genericsList(node);
      let kind = 'type-alias-other';
      let fields = null;
      let shape_sig = null;
      let type_text = null;
      let type_sig = null;
      let infer_ref = null;
      let operands = null;

      if (ts.isTypeLiteralNode(node.type)) {
        fields = membersToFields(node.type.members, sf, {
          ownerName: node.name.text,
          emitSynthetic,
          rowDefaults,
        });
        shape_sig = shapeSig(fields);
        kind = 'type-alias-object';
      } else {
        type_text = normalize(node.type.getText(sf)).slice(0, 300);
        type_sig = typeSig(type_text);
        infer_ref = isInferModelType(node.type, sf);
        if (infer_ref) kind = 'type-alias-infer-model';
        else if (ts.isUnionTypeNode(node.type)) kind = 'type-alias-union';
        else if (ts.isIntersectionTypeNode(node.type)) {
          kind = 'type-alias-intersection';
          // Capture operands for second-pass resolution. Inline literals are resolved here
          // (without emitting synthetic catalog entries — intersection operands are not
          // named inner objects). Type references stash their name for later lookup.
          operands = node.type.types.map((t) => {
            if (ts.isTypeLiteralNode(t)) {
              const inlineFields = membersToFields(t.members, sf, null);
              return { kind: 'literal', fields: inlineFields };
            } else if (ts.isTypeReferenceNode(t)) {
              return { kind: 'ref', name: t.typeName.getText(sf) };
            } else {
              return { kind: 'unresolvable', text: normalize(t.getText(sf)).slice(0, 120) };
            }
          });
        }
      }

      const referencesList = refsForDecl(node, sf, [node.type]);
      // Intersection-extends: named operands of `type X = A & B & {...}` go
      // into `extends`. Inline literals don't — they extend an anonymous
      // shape, not a name. Union variants land in `references`, not `extends`,
      // since they describe possible-types not is-a relationships.
      const extendsList = (kind === 'type-alias-intersection' && operands)
        ? [...new Set(operands.filter((op) => op.kind === 'ref').map((op) => op.name))].sort()
        : [];
      pushBase(node, {
        name: node.name.text,
        kind,
        exported: exportedMod(node),
        generics,
        fields,
        shape_sig,
        type_text,
        type_sig,
        infer_ref,
        operands,
        extends: extendsList,
        references: referencesList,
      });
    }

    if (ts.isVariableStatement(node)) {
      const exported = exportedMod(node);
      for (const decl of node.declarationList.declarations) {
        if (!decl.initializer) continue;
        let init = decl.initializer;
        while (ts.isAsExpression(init) || ts.isTypeAssertionExpression?.(init)) init = init.expression;
        if (!ts.isCallExpression(init)) continue;
        const name = decl.name.getText(sf);

        if (isZodObjectCall(init)) {
          const fields = extractZodObjectFields(init.arguments[0], sf);
          pushBase(decl, {
            name,
            kind: 'zod-object',
            exported,
            fields,
            shape_sig: fields ? shapeSig(fields) : null,
          });
        } else if (isDrizzleTableCall(init)) {
          const args = init.arguments;
          const nameArg = args[0];
          let colsArg = args[1];
          if (colsArg && !ts.isObjectLiteralExpression(colsArg)) {
            colsArg = args[2] && ts.isObjectLiteralExpression(args[2]) ? args[2] : colsArg;
          }
          const dbName = nameArg && ts.isStringLiteral(nameArg) ? nameArg.text : null;
          const fields = extractDrizzleTableFields(colsArg, sf);
          pushBase(decl, {
            name,
            kind: 'drizzle-table',
            exported,
            db_table_name: dbName,
            fields,
            shape_sig: fields ? shapeSig(fields) : null,
          });
        }
      }
    }

    // Dynamic imports and CommonJS require() can appear anywhere; piggyback on
    // the type-extraction recursion so we don't pay for a second tree walk.
    if (ts.isCallExpression(node) && node.arguments.length > 0) {
      // Dynamic `import(spec)`: files.json captures string-literal specs only
      // (templated forms aren't statically resolvable for path joins). Catalog
      // import rows record templated forms with origin_resolution: "computed"
      // so they're still visible to consumer-edge queries.
      if (node.expression.kind === ts.SyntaxKind.ImportKeyword) {
        const arg = node.arguments[0];
        const isLiteral = ts.isStringLiteral(arg);
        if (collectImports && isLiteral) {
          const { line } = sf.getLineAndCharacterOfPosition(node.getStart(sf));
          rawImports.push({
            kind: 'dynamic-import',
            spec: arg.text,
            type_only: false,
            line: line + 1,
          });
        }
        if (includeImports) {
          emitDynamicImportRow(node, isLiteral ? arg.text : null);
        }
      } else if (
        includeImports
        && ts.isIdentifier(node.expression)
        && node.expression.text === 'require'
        && ts.isStringLiteral(node.arguments[0])
      ) {
        emitRequireRows(node, node.arguments[0].text);
      }
    }

    ts.forEachChild(node, visit);
  }

  visit(sf);

  let fileRow = null;
  if (collectImports) {
    const imports = rawImports.map((r) => {
      const { package: pkg, path: rpath } = resolveImportSpec(r.spec, filePath);
      return { package: pkg, path: rpath, type_only: r.type_only, kind: r.kind, line: r.line };
    });
    imports.sort(compareBy((r) => r.package, (r) => r.path, (r) => r.kind, (r) => r.line));
    fileRow = {
      path: relPath,
      package: pkgName,
      is_test: rowDefaults.is_test,
      imports,
    };
  }
  return { entries: results, fileRow };
}

// --- Run ---

const mainFiles = walkDir(ROOT);
const sharedFiles = SHARED ? walkDir(SHARED) : [];

process.stderr.write(`main: ${mainFiles.length} files\n`);
if (SHARED) process.stderr.write(`shared: ${sharedFiles.length} files\n`);

const EMIT_FILES = !!values['emit-files'];
const INCLUDE_IMPORTS = !!values['include-imports'];
const all = [];
const fileEntries = [];
let errors = 0;
function indexOne(f, pkg, pkgRoot) {
  const { entries, fileRow } = extractFromFile(f, pkg, pkgRoot, {
    collectImports: EMIT_FILES,
    includeImports: INCLUDE_IMPORTS,
  });
  all.push(...entries);
  if (fileRow) fileEntries.push(fileRow);
}
for (const f of mainFiles) {
  try { indexOne(f, 'main', ROOT); }
  catch (e) { errors++; process.stderr.write(`  ERR ${f}: ${e.message}\n`); }
}
for (const f of sharedFiles) {
  try { indexOne(f, 'shared', SHARED); }
  catch (e) { errors++; process.stderr.write(`  ERR ${f}: ${e.message}\n`); }
}

// --- intersection-type field resolution second pass ---
// Resolve `type X = A & B & { c: number }` intersections by unioning operand field sets.
// Multi-pass to handle transitive cases (`X = A & B; Y = X & C`); fixed point or max 5 iters.
//
// Resolution rules:
//   - 'literal' operand: use its inline fields directly.
//   - 'ref' operand: look up the named type's `fields` in `fieldsByName`. If it has none
//     (unresolved itself, or no shape), this operand is unresolvable this iteration.
//   - 'unresolvable' operand: stays unresolvable.
//
// Output:
//   - All operands resolved → fields = unique union, shape_sig set, resolved_from = "intersection",
//     operands rewritten from {kind, ...} objects to a flat names list for traceability.
//   - At least one operand unresolved after max iters → fields stays null, unresolved = true,
//     unresolved_operands lists the offenders (for debugging).
//
// NOTE: the `operands` field changes shape between the first pass (array of {kind, ...} objects)
// and the resolved post-pass (array of strings). This is intentional and all in-process —
// external consumers reading `catalog.json` only ever see the post-resolution shape.
{
  const MAX_ITERS = 5;
  // fieldsByName: built fresh each iteration so newly-resolved intersections feed transitive cases.
  for (let iter = 0; iter < MAX_ITERS; iter++) {
    const fieldsByName = new Map();
    for (const e of all) {
      if (e.fields && Array.isArray(e.fields)) fieldsByName.set(e.name, e.fields);
    }
    let changed = false;
    for (const e of all) {
      if (e.kind !== 'type-alias-intersection') continue;
      if (e.fields) continue; // already resolved in a prior iter
      if (!e.operands || e.operands.length === 0) continue;
      const collected = [];
      let unresolved = false;
      const unresolvedOps = [];
      for (const op of e.operands) {
        if (op.kind === 'literal') {
          collected.push(...(op.fields || []));
        } else if (op.kind === 'ref') {
          const f = fieldsByName.get(op.name);
          if (f) {
            collected.push(...f);
          } else {
            unresolved = true;
            unresolvedOps.push(op.name);
          }
        } else {
          unresolved = true;
          unresolvedOps.push(op.text || '<unresolvable>');
        }
      }
      if (!unresolved) {
        // Dedupe by field NAME (left of `:`) — same-named field from two operands collapses
        // to the FIRST occurrence in declaration order. TypeScript's true semantics would
        // intersect (`{a:string} & {a:number}` → `a: never`), but the substrate is for
        // clustering, not type-checking — we just need a deterministic `shape_sig`. Order-
        // dependence is documented in `docs/pipeline-contract.md`.
        const seenName = new Set();
        const merged = [];
        for (const f of collected) {
          const fname = f.split(':')[0].replace(/\?$/, '');
          if (seenName.has(fname)) continue;
          seenName.add(fname);
          merged.push(f);
        }
        merged.sort();
        e.fields = merged;
        e.shape_sig = shapeSig(merged);
        e.resolved_from = 'intersection';
        e.operands = e.operands.map((op) => op.kind === 'ref' ? op.name : op.kind === 'literal' ? '<literal>' : op.text);
        changed = true;
      } else if (iter === MAX_ITERS - 1) {
        // Final pass: mark anything still unresolved
        e.unresolved = true;
        e.unresolved_operands = unresolvedOps;
      }
    }
    if (!changed) break;
  }
}

// --- reference_count second pass ---
// reference_count = total identifier occurrences across all scanned files MINUS the number of
// catalog entries declaring that name. Synthetic ("Outer.prop") names contain `.` and won't match
// identifier regex, so they get 0 — correct (synthetics aren't named in source).
const declCountByName = new Map();
for (const e of all) {
  declCountByName.set(e.name, (declCountByName.get(e.name) || 0) + 1);
}
for (const e of all) {
  if (e.synthetic) {
    e.reference_count = 0;
  } else {
    const total = idCounts.get(e.name) || 0;
    const decls = declCountByName.get(e.name) || 1;
    e.reference_count = Math.max(0, total - decls);
  }
}

process.stderr.write(`\nTotal entries: ${all.length} (errors: ${errors})\n`);
const byKind = {};
const byPkg = {};
let syntheticCount = 0;
let isTestCount = 0;
for (const e of all) {
  byKind[e.kind] = (byKind[e.kind] || 0) + 1;
  byPkg[e.package] = (byPkg[e.package] || 0) + 1;
  if (e.synthetic) syntheticCount++;
  if (e.is_test) isTestCount++;
}
process.stderr.write('By kind:\n');
for (const [k, v] of Object.entries(byKind).sort((a, b) => b[1] - a[1])) {
  process.stderr.write(`  ${String(v).padStart(5)}  ${k}\n`);
}
process.stderr.write('By package:\n');
for (const [k, v] of Object.entries(byPkg)) {
  process.stderr.write(`  ${String(v).padStart(5)}  ${k}\n`);
}
if (syntheticCount > 0) {
  process.stderr.write(`Synthetic (inline-literal) entries: ${syntheticCount}\n`);
}
process.stderr.write(`is_test entries: ${isTestCount}\n`);

// --- symbol_id pass (v1.2) ---
// Emit symbol_id on every entry per the contract's "Identity and provenance"
// section. Synthetic entries (inline-literal types named "Outer.prop") still
// hash deterministically — the formula doesn't care about source syntactic
// validity, only that the tuple is stable.
//
// Same pass also stamps `language: "typescript"` on every entry — the v2
// core-projection requirement. Doing both in the same loop avoids a redundant
// walk over the entry array.
for (const e of all) {
  e.symbol_id = computeSymbolId(e.package, e.file, e.name, e.kind);
  e.language = LANGUAGE;
}

const EXTRACTOR_META = {
  language: 'typescript',
  name: 'type-catalog',
  version: EXTRACTOR_VERSION,
  source_sha: SOURCE_SHA,
};

const catalog = {
  schema_version: SCHEMA_VERSION,
  extractor: EXTRACTOR_META,
  fingerprint_v: FINGERPRINT_V,
  generated_at: GENERATED_AT,
  entries: all,
};
const json = JSON.stringify(catalog, null, 2);
if (values.output) {
  writeFileSync(values.output, json);
  process.stderr.write(`\nWrote ${values.output}\n`);
} else {
  process.stdout.write(json);
}

// --- Sibling references.json artifact ---
// Inverted edge list. Resolution: same-package first, then 'shared', else
// unresolved (resolved: false, to.package == from.package). The edge list is
// deduplicated and sorted for determinism.
if (values['emit-references-graph']) {
  const namesByPackage = new Map();
  for (const e of all) {
    let names = namesByPackage.get(e.package);
    if (!names) { names = new Set(); namesByPackage.set(e.package, names); }
    names.add(e.name);
  }
  const sharedNames = namesByPackage.get('shared');
  const edges = [];
  const seen = new Set();
  for (const e of all) {
    if (!e.references || e.references.length === 0) continue;
    const sameNames = namesByPackage.get(e.package);
    for (const ref of e.references) {
      let toPackage = e.package;
      let resolved = false;
      if (sameNames?.has(ref.name)) {
        resolved = true;
      } else if (sharedNames?.has(ref.name) && e.package !== 'shared') {
        toPackage = 'shared';
        resolved = true;
      }
      const key = `${e.package} ${e.name} ${toPackage} ${ref.name}`;
      if (seen.has(key)) continue;
      seen.add(key);
      edges.push({
        from: { package: e.package, name: e.name },
        to:   { package: toPackage, name: ref.name },
        kind: 'type-ref',
        resolved,
      });
    }
  }
  edges.sort(compareBy((e) => e.from.package, (e) => e.from.name, (e) => e.to.package, (e) => e.to.name));
  writeSiblingArtifact({
    path: values['emit-references-graph'],
    schema_version: SCHEMA_VERSION,
    extractorMeta: EXTRACTOR_META,
    fingerprint_v: FINGERPRINT_V,
    generated_at: GENERATED_AT,
    payloadKey: 'edges',
    payload: edges,
    summary: `Wrote references graph (${edges.length} edges) to ${values['emit-references-graph']}`,
  });
}

// --- Sibling files.json artifact ---
// Per-file import edges (static + re-export + dynamic). Resolved against
// ROOT / SHARED to tag every edge with package ∈ {main, shared, extern}.
// Documented in docs/pipeline-contract.md §files artifact. First consumer is
// pipeline/queries/cross-package-backward-imports.jq.
if (EMIT_FILES) {
  fileEntries.sort(compareBy((f) => f.package, (f) => f.path));
  const edgeCount = fileEntries.reduce((acc, f) => acc + f.imports.length, 0);
  writeSiblingArtifact({
    path: values['emit-files'],
    schema_version: SCHEMA_VERSION,
    extractorMeta: EXTRACTOR_META,
    fingerprint_v: FINGERPRINT_V,
    generated_at: GENERATED_AT,
    payloadKey: 'entries',
    payload: fileEntries,
    summary: `Wrote files (${fileEntries.length} files, ${edgeCount} edges) to ${values['emit-files']}`,
  });
}

process.exit(mainFiles.length > 0 ? 0 : 1);
