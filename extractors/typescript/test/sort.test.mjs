// Tests for _lib/sort.mjs (compareBy multi-key comparator factory).
//
// Run with:  node --test test/sort.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { compareBy } from '../_lib/sort.mjs';

test('compareBy with a single key sorts by that key ascending', () => {
  const rows = [{ k: 'c' }, { k: 'a' }, { k: 'b' }];
  rows.sort(compareBy((r) => r.k));
  assert.deepEqual(rows.map((r) => r.k), ['a', 'b', 'c']);
});

test('compareBy breaks ties using subsequent keys', () => {
  const rows = [
    { pkg: 'main', path: 'b.ts' },
    { pkg: 'main', path: 'a.ts' },
    { pkg: 'shared', path: 'a.ts' },
  ];
  rows.sort(compareBy((r) => r.pkg, (r) => r.path));
  assert.deepEqual(rows, [
    { pkg: 'main', path: 'a.ts' },
    { pkg: 'main', path: 'b.ts' },
    { pkg: 'shared', path: 'a.ts' },
  ]);
});

test('compareBy supports numeric keys via subtraction-equivalent ordering', () => {
  const rows = [{ line: 30 }, { line: 5 }, { line: 12 }];
  rows.sort(compareBy((r) => r.line));
  assert.deepEqual(rows.map((r) => r.line), [5, 12, 30]);
});

test('compareBy returns 0 when all keys equal (sort stays stable in V8)', () => {
  const rows = [
    { pkg: 'main', path: 'a.ts', tag: 'first' },
    { pkg: 'main', path: 'a.ts', tag: 'second' },
  ];
  rows.sort(compareBy((r) => r.pkg, (r) => r.path));
  assert.deepEqual(rows.map((r) => r.tag), ['first', 'second']);
});

test('compareBy supports nested-path key functions', () => {
  const rows = [
    { from: { package: 'main', name: 'B' } },
    { from: { package: 'main', name: 'A' } },
    { from: { package: 'shared', name: 'X' } },
  ];
  rows.sort(compareBy((r) => r.from.package, (r) => r.from.name));
  assert.deepEqual(rows.map((r) => r.from.name), ['A', 'B', 'X']);
});

test('compareBy with no key functions is a no-op comparator (everything ties)', () => {
  const rows = [{ x: 3 }, { x: 1 }, { x: 2 }];
  rows.sort(compareBy());
  assert.deepEqual(rows.map((r) => r.x), [3, 1, 2]);
});
