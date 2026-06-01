// walk-predicate.mjs
//
// Source of truth for "would the extractor look at this file?" Used by
// type-catalog.mjs's directory walk and exposed via the CLI `--list-relevant`
// flag (#159) for downstream consumers — the PR-comment Action (#123) and the
// pre-commit hook (#124) — that need the predicate as a pure query without
// paying the parse cost of a full extraction.
//
// Keep this file the single definition of the predicate. If the walker's
// behavior changes, change it here, and both the walker and the flag stay
// in lock-step.

import { isTestPath } from './paths.mjs';

// Directories never walked. Dotdirs (.git, .next, .claude, …) are handled
// separately by the predicate (any segment starting with '.').
export const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', 'coverage']);

// Source of truth for the TypeScript-source extension set. Exported so the
// walker and any other consumer references the same literal.
export const EXT_RE = /\.(tsx|ts|mts|cts)$/;

/**
 * @param {string} relPath  Path relative to the extraction root, '/'-separated.
 * @param {{ includeTests?: boolean }} [opts]
 *   includeTests — if true, test/spec/fixture/mock paths are kept. Default false:
 *   the walker indexes them (each row carries is_test=true), but the predicate's
 *   query form drops them so consumers don't surface noise from test files. This
 *   asymmetry is deliberate; see docs/plans/159-implementation.md §"Design".
 * @returns {boolean}
 */
export function isRelevantPath(relPath, { includeTests = false } = {}) {
  if (!relPath) return false;
  if (relPath.startsWith('/')) return false;

  const segments = relPath.split('/');

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
  if (!includeTests && isTestPath(relPath)) return false;

  return true;
}

/**
 * Stream the `--list-relevant` CLI mode: read paths from `input`, apply the
 * predicate, write kept paths to `output`. Separator is `\n` by default,
 * `\0` with `nullSeparated: true`.
 *
 * Input is buffered in full before the first emit — typical inputs (PR file
 * lists, `git diff --name-only` output) are bounded to a few thousand paths.
 * Streaming line-by-line is not worth the extra surface area here.
 *
 * @param {NodeJS.ReadableStream} input
 * @param {NodeJS.WritableStream} output
 * @param {{ includeTests?: boolean, nullSeparated?: boolean }} [opts]
 * @returns {Promise<void>}
 */
export async function streamRelevantPaths(input, output, opts = {}) {
  const { includeTests = false, nullSeparated = false } = opts;
  const sep = nullSeparated ? '\0' : '\n';

  let buf = '';
  input.setEncoding('utf8');
  for await (const chunk of input) {
    buf += chunk;
  }

  // Drop a trailing separator so `cat list.txt | …` (no `printf` shenanigans)
  // doesn't see an empty-string path as the final entry.
  if (buf.endsWith(sep)) buf = buf.slice(0, -1);

  if (buf.length === 0) return;

  for (const path of buf.split(sep)) {
    if (isRelevantPath(path, { includeTests })) {
      output.write(path + sep);
    }
  }
}
