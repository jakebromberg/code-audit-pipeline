// Cache-staleness tests for the pre-commit hook (#124).
//
// Verifies the invalidation rules in the issue spec §functional 3:
//   - Any relevant file with a newer mtime than the cached map entry
//     triggers a rebuild.
//   - 24h TTL is a hard ceiling regardless of mtimes.
//   - No change → no rebuild.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { join } from 'node:path';
import { writeFileSync, statSync } from 'node:fs';
import {
  makeFixtureRepo,
  runHook,
  readMeta,
  touchForward,
  ageCacheMeta,
} from './helpers.mjs';

const SIMPLE_TYPE = `export interface Simple { only: number; }\n`;
const ANOTHER_TYPE = `export interface Another { value: string; }\n`;

test('cache invalidates when a relevant file mtime moves forward', () => {
  const fx = makeFixtureRepo({ 'src/a.ts': SIMPLE_TYPE });
  try {
    const r1 = runHook(['src/a.ts'], { cwd: fx.root });
    assert.equal(r1.status, 0, `stderr: ${r1.stderr}`);
    const meta1 = readMeta(fx.root);
    assert.ok(meta1);

    // Wait one tick, then touch the staged file forward.
    touchForward(join(fx.root, 'src/a.ts'), 60);

    const r2 = runHook(['src/a.ts'], { cwd: fx.root });
    assert.equal(r2.status, 0, `stderr: ${r2.stderr}`);
    const meta2 = readMeta(fx.root);
    assert.notEqual(meta1.built_at, meta2.built_at, 'mtime change should trigger rebuild');
  } finally {
    fx.cleanup();
  }
});

test('cache stays valid when nothing changes', () => {
  const fx = makeFixtureRepo({ 'src/a.ts': SIMPLE_TYPE });
  try {
    const r1 = runHook(['src/a.ts'], { cwd: fx.root });
    assert.equal(r1.status, 0);
    const meta1 = readMeta(fx.root);

    const r2 = runHook(['src/a.ts'], { cwd: fx.root });
    assert.equal(r2.status, 0);
    const meta2 = readMeta(fx.root);
    assert.equal(meta1.built_at, meta2.built_at, 'no change → no rebuild');
  } finally {
    fx.cleanup();
  }
});

test('cache invalidates after 24h TTL even with no mtime changes', () => {
  const fx = makeFixtureRepo({ 'src/a.ts': SIMPLE_TYPE });
  try {
    const r1 = runHook(['src/a.ts'], { cwd: fx.root });
    assert.equal(r1.status, 0);
    const meta1 = readMeta(fx.root);

    // Age built_at to be > 24h in the past.
    ageCacheMeta(fx.root, 25 * 60 * 60 * 1000);

    const r2 = runHook(['src/a.ts'], { cwd: fx.root });
    assert.equal(r2.status, 0);
    const meta2 = readMeta(fx.root);
    assert.notEqual(meta1.built_at, meta2.built_at, 'TTL should trigger rebuild');
    // Confirm new built_at is recent (< 1 min old)
    assert.ok(Date.now() - meta2.built_at < 60_000, 'rebuilt built_at is fresh');
  } finally {
    fx.cleanup();
  }
});

test('cache invalidates when a new relevant file appears', () => {
  const fx = makeFixtureRepo({ 'src/a.ts': SIMPLE_TYPE });
  try {
    const r1 = runHook(['src/a.ts'], { cwd: fx.root });
    assert.equal(r1.status, 0);
    const meta1 = readMeta(fx.root);

    // Add a NEW file that wasn't in the cached mtime map.
    writeFileSync(join(fx.root, 'src/b.ts'), ANOTHER_TYPE);
    fx.git('add', 'src/b.ts');

    const r2 = runHook(['src/b.ts'], { cwd: fx.root });
    assert.equal(r2.status, 0);
    const meta2 = readMeta(fx.root);
    assert.notEqual(meta1.built_at, meta2.built_at, 'new file should trigger rebuild');
    assert.ok('src/b.ts' in meta2.mtimes, 'new file recorded in mtimes map');
  } finally {
    fx.cleanup();
  }
});

test('cache meta records schema_version + extractor_version', () => {
  const fx = makeFixtureRepo({ 'src/a.ts': SIMPLE_TYPE });
  try {
    const r1 = runHook(['src/a.ts'], { cwd: fx.root });
    assert.equal(r1.status, 0);
    const meta = readMeta(fx.root);
    assert.ok(meta.schema_version, 'meta.schema_version set');
    assert.ok(meta.extractor_version, 'meta.extractor_version set');
    assert.equal(typeof meta.built_at, 'number');
    assert.equal(typeof meta.mtimes, 'object');
  } finally {
    fx.cleanup();
  }
});
