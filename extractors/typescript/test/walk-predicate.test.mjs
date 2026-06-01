// Tests for the walk predicate exposed by `_lib/walk-predicate.mjs`. The
// predicate is the source of truth for "would the extractor look at this
// file?" — see #159. Consumers (#123 PR-comment Action, #124 pre-commit hook)
// reach the predicate via the CLI `--list-relevant` flag; tests for the CLI
// surface live in `list-relevant.test.mjs`.
//
// Run with:  node --test test/walk-predicate.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { isRelevantPath, SKIP_DIRS } from '../_lib/walk-predicate.mjs';

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
