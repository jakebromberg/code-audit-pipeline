// Tests for the walk predicate exposed by `_lib/walk-predicate.mjs`. The
// predicate is the source of truth for "would the extractor look at this
// file?" — see #159. Consumers (#123 PR-comment Action, #124 pre-commit hook)
// reach the predicate via the CLI `--list-relevant` flag; tests for the CLI
// surface live in `list-relevant.test.mjs`.
//
// Run with:  node --test test/walk-predicate.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { Readable, PassThrough } from 'node:stream';
import { isRelevantPath, streamRelevantPaths, SKIP_DIRS, EXT_RE } from '../_lib/walk-predicate.mjs';
import { TEST_DIRS, TEST_FILE_RE } from '../_lib/paths.mjs';

test('keeps .ts/.tsx/.mts/.cts in regular dirs', () => {
  assert.equal(isRelevantPath('src/foo.ts'), true);
  assert.equal(isRelevantPath('src/foo.tsx'), true);
  assert.equal(isRelevantPath('src/foo.mts'), true);
  assert.equal(isRelevantPath('src/foo.cts'), true);
  assert.equal(isRelevantPath('foo.ts'), true);
  assert.equal(isRelevantPath('a/b/c/d.ts'), true);
});

test('drops non-TypeScript extensions', () => {
  assert.equal(isRelevantPath('src/foo.js'), false);
  assert.equal(isRelevantPath('src/foo.jsx'), false);
  assert.equal(isRelevantPath('src/foo.md'), false);
  assert.equal(isRelevantPath('README.md'), false);
  assert.equal(isRelevantPath('src/foo'), false);   // no extension
  assert.equal(isRelevantPath('src/foo.d.ts'), true); // .ts suffix wins — matches walker
});

test('drops case-mismatched extensions (matches walker regex)', () => {
  assert.equal(isRelevantPath('src/foo.TS'), false);
  assert.equal(isRelevantPath('src/foo.Tsx'), false);
});

test('drops everything under SKIP_DIRS', () => {
  for (const skip of SKIP_DIRS) {
    assert.equal(isRelevantPath(`${skip}/foo.ts`), false, `expected drop under ${skip}/`);
    assert.equal(isRelevantPath(`pkg/${skip}/foo.ts`), false, `expected drop under pkg/${skip}/`);
    assert.equal(isRelevantPath(`a/b/${skip}/c/foo.ts`), false, `expected drop under a/b/${skip}/c/`);
  }
});

test('drops everything under any dotdir', () => {
  assert.equal(isRelevantPath('.git/HEAD'), false);
  assert.equal(isRelevantPath('.next/foo.ts'), false);
  assert.equal(isRelevantPath('.claude/x.ts'), false);
  assert.equal(isRelevantPath('.idea/x.ts'), false);
  assert.equal(isRelevantPath('.cursor/x.ts'), false);
  assert.equal(isRelevantPath('.vscode/x.ts'), false);
  assert.equal(isRelevantPath('a/.hidden/x.ts'), false);
  // But a dotfile in the leaf position is fine if extension matches:
  // (no such .ts dotfile convention exists, but the predicate only inspects
  // segment-startsWith-'.' for *intermediate* segments, not the basename.)
});

test('does NOT treat a dotfile basename as a dotdir', () => {
  // A file named `.foo.ts` at the top level is unusual but not in a dotdir.
  // The walker would visit it (readdirSync surfaces dotfiles); the predicate
  // matches the walker.
  assert.equal(isRelevantPath('.foo.ts'), true);
});

test('drops test paths by default; keeps with includeTests=true', () => {
  // Directory-based tests
  for (const rel of [
    'tests/foo.ts',
    'test/foo.ts',
    'src/__tests__/foo.ts',
    'src/__test__/foo.ts',
    'src/spec/foo.ts',
    'src/__mocks__/foo.ts',
    'src/__fixtures__/foo.ts',
    'src/fixtures/foo.ts',
    'src/e2e/foo.ts',
  ]) {
    assert.equal(isRelevantPath(rel), false, `expected drop (default): ${rel}`);
    assert.equal(isRelevantPath(rel, { includeTests: true }), true, `expected keep (--include-tests): ${rel}`);
  }
  // Filename-based tests
  for (const rel of [
    'src/foo.test.ts',
    'src/foo.spec.tsx',
    'src/foo.fixture.ts',
    'src/foo.mock.ts',
  ]) {
    assert.equal(isRelevantPath(rel), false, `expected drop (default): ${rel}`);
    assert.equal(isRelevantPath(rel, { includeTests: true }), true, `expected keep (--include-tests): ${rel}`);
  }
});

test('drops absolute paths', () => {
  assert.equal(isRelevantPath('/abs/path.ts'), false);
  assert.equal(isRelevantPath('/foo.ts'), false);
});

test('drops empty string and whitespace-only inputs', () => {
  assert.equal(isRelevantPath(''), false);
  assert.equal(isRelevantPath('   '), false);
});

test('SKIP_DIRS is exactly the documented set', () => {
  // Snapshot the predicate's skip-dir invariant so a silent edit to the set
  // breaks this test. Add a follow-up to update consumers (#123, #124) if
  // this set grows.
  assert.deepEqual([...SKIP_DIRS].sort(), ['build', 'coverage', 'dist', 'node_modules']);
});

test('TEST_DIRS matches docs/pipeline-contract.md §"Test path patterns"', () => {
  // Pinning the test-path set at the predicate level so a silent edit to
  // paths.mjs (e.g. adding `__benches__`) breaks this test before it shifts
  // every #123/#124 consumer's behavior.
  assert.deepEqual([...TEST_DIRS].sort(), [
    '__fixtures__', '__mocks__', '__test__', '__tests__',
    'e2e', 'fixtures', 'spec', 'test', 'tests',
  ]);
});

test('TEST_FILE_RE matches docs/pipeline-contract.md §"Test path patterns"', () => {
  assert.equal(TEST_FILE_RE.source, '\\.(test|spec|fixture|fixtures|mock|mocks)\\.(tsx|ts|mts|cts)$');
  assert.equal(TEST_FILE_RE.flags, '');
});

test('EXT_RE matches the documented TypeScript extension set', () => {
  assert.equal(EXT_RE.source, '\\.(tsx|ts|mts|cts)$');
  assert.equal(EXT_RE.flags, '');
});

// ---- Input normalization (regression coverage for PR 244 review) ----

test('strips trailing CR from CRLF input (Windows / git autocrlf)', () => {
  assert.equal(isRelevantPath('src/foo.ts\r'), true);
  assert.equal(isRelevantPath('src/foo.tsx\r'), true);
  // Path that was a test stays a test after CRLF strip.
  assert.equal(isRelevantPath('src/foo.test.ts\r'), false);
  assert.equal(isRelevantPath('src/foo.test.ts\r', { includeTests: true }), true);
});

test('normalizes leading ./ (find -print0 composition)', () => {
  assert.equal(isRelevantPath('./src/foo.ts'), true);
  assert.equal(isRelevantPath('./node_modules/x/y.ts'), false);
  // Multiple leading ./ also collapse.
  assert.equal(isRelevantPath('././src/foo.ts'), true);
  // ./ in the middle still triggers dotdir guard (which is correct — `a/./b`
  // is a non-canonical path; we don't recursively canonicalize).
  assert.equal(isRelevantPath('a/./foo.ts'), false);
});

test('normalizes Windows backslash paths', () => {
  // Should be kept after normalization.
  assert.equal(isRelevantPath('src\\foo.ts'), true);
  assert.equal(isRelevantPath('src\\sub\\foo.tsx'), true);
  // SKIP_DIRS must still apply after backslash normalization.
  assert.equal(isRelevantPath('node_modules\\pkg\\foo.ts'), false);
  assert.equal(isRelevantPath('dist\\foo.ts'), false);
  // Dotdir check must still apply.
  assert.equal(isRelevantPath('.next\\foo.ts'), false);
  // Mixed separators too.
  assert.equal(isRelevantPath('src/sub\\foo.ts'), true);
  assert.equal(isRelevantPath('node_modules/pkg\\foo.ts'), false);
});

test('trims surrounding whitespace from path inputs', () => {
  assert.equal(isRelevantPath(' src/foo.ts'), true);
  assert.equal(isRelevantPath('src/foo.ts '), true);
  assert.equal(isRelevantPath('  src/foo.ts  '), true);
  // Whitespace-only stays rejected.
  assert.equal(isRelevantPath('   '), false);
});

test('defensive: non-string inputs return false (no throw)', () => {
  assert.equal(isRelevantPath(null), false);
  assert.equal(isRelevantPath(undefined), false);
  assert.equal(isRelevantPath(42), false);
  assert.equal(isRelevantPath(true), false);
  assert.equal(isRelevantPath({}), false);
  assert.equal(isRelevantPath([]), false);
});

// ---- streamRelevantPaths direct in-memory tests (Angle E1) ----

async function collect(input, opts = {}) {
  const out = new PassThrough();
  const chunks = [];
  out.on('data', (c) => chunks.push(c.toString('utf8')));
  await streamRelevantPaths(input, out, opts);
  return chunks.join('');
}

test('streamRelevantPaths handles a chunk boundary splitting a path', async () => {
  // The basename is split across two chunks; the buffered read must reassemble.
  const input = Readable.from(['src/foo', '.ts\nsrc/bar.js\nsrc/baz.tsx\n']);
  const out = await collect(input);
  assert.equal(out, 'src/foo.ts\nsrc/baz.tsx\n');
});

test('streamRelevantPaths handles multi-chunk input across many separators', async () => {
  const input = Readable.from(['a/b.ts\n', 'c/d.js\n', 'e/f.tsx\n']);
  const out = await collect(input);
  assert.equal(out, 'a/b.ts\ne/f.tsx\n');
});

test('streamRelevantPaths emits NUL separators in --null mode', async () => {
  const input = Readable.from(['x.ts\0y.js\0z.tsx\0']);
  const out = await collect(input, { nullSeparated: true });
  assert.equal(out, 'x.ts\0z.tsx\0');
});

test('streamRelevantPaths emits empty output (no separator) for all-rejected input', async () => {
  const input = Readable.from(['README.md\nnode_modules/x/y.ts\n']);
  const out = await collect(input);
  assert.equal(out, '');
});

test('streamRelevantPaths normalizes CRLF and ./ across the pipeline', async () => {
  const input = Readable.from(['./src/foo.ts\r\n./node_modules/x/y.ts\r\nsrc\\bar.tsx\r\n']);
  const out = await collect(input);
  assert.equal(out, 'src/foo.ts\nsrc/bar.tsx\n');
});

test('streamRelevantPaths tolerates duplicate trailing separators', async () => {
  const input = Readable.from(['src/foo.ts\n\n\n']);
  const out = await collect(input);
  assert.equal(out, 'src/foo.ts\n');
});
