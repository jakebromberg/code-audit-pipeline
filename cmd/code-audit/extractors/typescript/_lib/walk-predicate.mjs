// walk-predicate.mjs
//
// Source of truth for "would the extractor look at this file?" Used by
// type-catalog.mjs's directory walk (and function-catalog.mjs via shared
// SKIP_DIRS / EXT_RE) and exposed via the CLI `--list-relevant` flag (#159)
// for downstream consumers — the PR-comment Action (#123) and the pre-commit
// hook (#124) — that need the predicate as a pure query without paying the
// parse cost of a full extraction.
//
// Keep this file the single definition of the predicate. If the walker's
// behavior changes, change it here, and every consumer stays in lock-step.

import { isTestPath } from './paths.mjs';

// Directories never walked. Dotdirs (.git, .next, .claude, …) are handled
// separately by the predicate (any segment starting with '.').
export const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', 'coverage']);

// Source of truth for the TypeScript-source extension set. Exported so any
// other consumer references the same literal.
export const EXT_RE = /\.(tsx|ts|mts|cts)$/;

/**
 * Normalize an input path for predicate evaluation:
 *  - Reject non-string inputs (returns null; caller treats as "not relevant").
 *  - Convert Windows `\` separators to `/`.
 *  - Strip trailing `\r` (CRLF input from Windows tooling).
 *  - Trim surrounding ASCII whitespace.
 *  - Collapse any leading `./` segments.
 * Returns the normalized path, or null if the input is unusable.
 * @param {unknown} relPath
 * @returns {string | null}
 */
function normalizePath(relPath) {
  if (typeof relPath !== 'string') return null;
  let p = relPath;
  if (p.endsWith('\r')) p = p.slice(0, -1);
  p = p.trim();
  if (p.length === 0) return null;
  if (p.includes('\\')) p = p.replaceAll('\\', '/');
  while (p.startsWith('./')) p = p.slice(2);
  if (p.length === 0) return null;
  return p;
}

/**
 * @param {unknown} relPath  Path relative to the extraction root. The
 *   predicate normalizes leading `./`, trailing `\r` (CRLF), surrounding
 *   whitespace, and Windows `\` separators before evaluating; absolute
 *   paths (`/…`) are rejected. Non-string inputs return false defensively.
 * @param {{ includeTests?: boolean }} [opts]
 *   includeTests — if true, test/spec/fixture/mock paths are kept. Default false:
 *   the walker indexes them (each row carries is_test=true), but the predicate's
 *   query form drops them so consumers don't surface noise from test files. This
 *   asymmetry is deliberate; see docs/plans/159-implementation.md §"Design".
 * @returns {boolean}
 */
export function isRelevantPath(relPath, { includeTests = false } = {}) {
  const p = normalizePath(relPath);
  if (p === null) return false;
  if (p.startsWith('/')) return false;

  const segments = p.split('/');

  // Intermediate segments: drop dotdirs and skip-dirs.
  for (let i = 0; i < segments.length - 1; i++) {
    const seg = segments[i];
    if (seg.startsWith('.')) return false;
    if (SKIP_DIRS.has(seg)) return false;
  }

  // Basename: extension match.
  const basename = segments[segments.length - 1];
  if (!EXT_RE.test(basename)) return false;

  // Test/spec/fixture/mock: dropped by default, kept with --include-tests.
  if (!includeTests && isTestPath(p)) return false;

  return true;
}

/**
 * Stream the `--list-relevant` CLI mode: read paths from `input`, apply the
 * predicate, write the kept subset to `output`. Separator is `\n` by default,
 * `\0` with `nullSeparated: true`. Output is gathered into a single
 * synchronous write so callers can `process.exit()` immediately after the
 * returned promise resolves (the write callback waits for the pipe to drain).
 *
 * Input is buffered in full before any output is produced — typical inputs
 * (PR file lists, `git diff --name-only` output) are bounded to at most a
 * few thousand paths.
 *
 * @param {NodeJS.ReadableStream} input  Readable stream of utf8 bytes (or
 *   strings). For `process.stdin` on a TTY, a stderr hint is emitted so the
 *   user knows the tool is waiting on input.
 * @param {NodeJS.WritableStream} output
 * @param {{ includeTests?: boolean, nullSeparated?: boolean }} [opts]
 * @returns {Promise<void>}
 */
export async function streamRelevantPaths(input, output, opts = {}) {
  const { includeTests = false, nullSeparated = false } = opts;
  const sep = nullSeparated ? '\0' : '\n';

  if (input.isTTY) {
    process.stderr.write(
      `--list-relevant: reading paths from stdin (one per line, Ctrl-D to end).\n` +
      `For non-interactive use, pipe input in: e.g. \`git diff --name-only main...HEAD | ...\`.\n`,
    );
  }

  input.setEncoding('utf8');
  let buf = '';
  for await (const chunk of input) buf += chunk;

  const kept = [];
  for (const path of buf.split(sep)) {
    if (isRelevantPath(path, { includeTests })) {
      // Use the normalized form so downstream consumers see canonical paths
      // (no `./` prefix, no `\r`, no whitespace, forward slashes).
      kept.push(normalizePath(path));
    }
  }

  if (kept.length === 0) return;

  // Single buffered write + drain await so `process.exit()` after this
  // promise resolves cannot truncate the pipe. The callback is also where
  // EPIPE surfaces if the consumer closed stdout — we swallow EPIPE there
  // for the standard filter-CLI exit-clean semantics; other errors throw.
  await new Promise((resolve, reject) => {
    output.write(kept.join(sep) + sep, (err) => {
      if (!err || err.code === 'EPIPE') resolve();
      else reject(err);
    });
  });
}
