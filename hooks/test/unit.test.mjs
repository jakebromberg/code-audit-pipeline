// Unit tests for the pre-commit hook's internal helpers (#124).
//
// The shared `--list-relevant` predicate is exhaustively tested in
// `extractors/typescript/test/walk-predicate.test.mjs` and
// `extractors/typescript/test/list-relevant.test.mjs`. These tests cover
// the bits that live in the hook itself: parsing argv vs. stdin, sieving
// linguist-generated paths via git check-attr, and the cluster-touched
// join.
//
// Run with:  node --test hooks/test/*.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseArgvOrStdin,
  isClusterTouched,
  computeMtimeMap,
} from '../pre-commit-audit.mjs';
import { mkdirSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test('parseArgvOrStdin: prefers argv when given', async () => {
  const argv = ['src/foo.ts', 'src/bar.tsx'];
  const paths = await parseArgvOrStdin(argv, { stdin: null });
  assert.deepEqual(paths, ['src/foo.ts', 'src/bar.tsx']);
});

test('parseArgvOrStdin: returns empty array when no argv and no stdin', async () => {
  const paths = await parseArgvOrStdin([], { stdin: null });
  assert.deepEqual(paths, []);
});

test('isClusterTouched: cluster-shape with members[]', () => {
  const cluster = {
    shape: 'cluster',
    members: [
      { file: 'src/a.ts', package: 'main' },
      { file: 'src/b.ts', package: 'main' },
    ],
  };
  assert.equal(isClusterTouched(cluster, new Set(['src/a.ts'])), true);
  assert.equal(isClusterTouched(cluster, new Set(['src/c.ts'])), false);
  assert.equal(isClusterTouched(cluster, new Set()), false);
});

test('isClusterTouched: pair-shape with left/right endpoints', () => {
  const pair = {
    shape: 'pair',
    left: { file: 'src/a.ts', package: 'main' },
    right: { file: 'src/b.ts', package: 'main' },
  };
  assert.equal(isClusterTouched(pair, new Set(['src/a.ts'])), true);
  assert.equal(isClusterTouched(pair, new Set(['src/b.ts'])), true);
  assert.equal(isClusterTouched(pair, new Set(['src/c.ts'])), false);
});

test('isClusterTouched: malformed row returns false (defensive)', () => {
  assert.equal(isClusterTouched({}, new Set(['x'])), false);
  assert.equal(isClusterTouched({ shape: 'unknown' }, new Set(['x'])), false);
  assert.equal(isClusterTouched(null, new Set(['x'])), false);
});

test('computeMtimeMap: collects mtimes for given paths', () => {
  const dir = mkdtempSync(join(tmpdir(), 'code-audit-hook-unit-'));
  try {
    mkdirSync(join(dir, 'src'), { recursive: true });
    writeFileSync(join(dir, 'src/a.ts'), 'export type A = 1;\n');
    writeFileSync(join(dir, 'src/b.ts'), 'export type B = 2;\n');

    const map = computeMtimeMap(dir, ['src/a.ts', 'src/b.ts', 'src/missing.ts']);
    assert.ok(typeof map['src/a.ts'] === 'number');
    assert.ok(typeof map['src/b.ts'] === 'number');
    // Missing file: skipped from map (no entry), not undefined or 0.
    assert.equal('src/missing.ts' in map, false);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
