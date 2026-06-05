// Tests for the TypeScript type-catalog extractor's --emit-files sibling artifact (#134).
//
// Validates the v1.1 wrapper shape, file-level import edges, resolver
// behavior (relative paths, extension probing, /index probing, externals,
// --shared cross-package targets), kind tagging (import / re-export /
// dynamic-import), type-only flag, line capture, and opt-in behavior.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const EXTRACTOR = join(__dirname, '..', 'type-catalog.mjs');
const FIXTURES_ROOT = join(__dirname, '..', 'fixtures-files', 'main');
const FIXTURES_SHARED = join(__dirname, '..', 'fixtures-files', 'shared');

function runExtractor(args = []) {
  return spawnSync('node', [EXTRACTOR, '--root', FIXTURES_ROOT, ...args], {
    encoding: 'utf8',
  });
}

// Cached files.json across the suite — spawn once, parse once.
let _cachedFiles = null;
let _tmpDir = null;

function extractFiles() {
  if (_cachedFiles) return _cachedFiles;
  _tmpDir = mkdtempSync(join(tmpdir(), 'files-test-'));
  const out = join(_tmpDir, 'files.json');
  const res = runExtractor(['--shared', FIXTURES_SHARED, '--emit-files', out]);
  if (res.status !== 0) {
    throw new Error(`extractor failed (status ${res.status}): ${res.stderr}`);
  }
  _cachedFiles = JSON.parse(readFileSync(out, 'utf8'));
  rmSync(_tmpDir, { recursive: true, force: true });
  return _cachedFiles;
}

function fileRow(files, path) {
  const matches = files.entries.filter((e) => e.path === path);
  assert.equal(matches.length, 1, `expected 1 row for path "${path}", got ${matches.length}`);
  return matches[0];
}

// The "extractor exits 0 + writes files.json" assertion is covered implicitly
// by extractFiles() — it throws if status != 0 and parses the file from disk.
// A dedicated exit-0 test would just duplicate that spawn.

test('files.json: without --emit-files, no files.json is written', () => {
  const tmp = mkdtempSync(join(tmpdir(), 'files-test-'));
  try {
    const out = join(tmp, 'files.json');
    const res = runExtractor(['--shared', FIXTURES_SHARED, '--output', join(tmp, 'catalog.json')]);
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    assert.ok(!existsSync(out), 'files.json should NOT exist without --emit-files');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('files.json: wrapped as schema_version 1.2 with identity/provenance metadata', () => {
  const f = extractFiles();
  assert.equal(f.schema_version, '1.2');
  assert.equal(f.extractor.language, 'typescript');
  assert.equal(f.extractor.name, 'type-catalog');
  assert.ok(/^\d+\.\d+\.\d+/.test(f.extractor.version), `version: ${f.extractor.version}`);
  assert.ok(typeof f.extractor.source_sha === 'string' && f.extractor.source_sha.length > 0,
    `source_sha: ${f.extractor.source_sha}`);
  assert.equal(f.fingerprint_v, 'shape_sig:1');
  assert.ok(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/.test(f.generated_at),
    `generated_at: ${f.generated_at}`);
  assert.ok(Array.isArray(f.entries));
});

test('files.json: every entry has required top-level shape', () => {
  const f = extractFiles();
  for (const entry of f.entries) {
    assert.equal(typeof entry.path, 'string', `path on ${entry.path}`);
    assert.ok(entry.package === 'main' || entry.package === 'shared', `package on ${entry.path}: ${entry.package}`);
    assert.equal(typeof entry.is_test, 'boolean', `is_test on ${entry.path}`);
    assert.ok(Array.isArray(entry.imports), `imports[] on ${entry.path}`);
  }
});

test('files.json: every import row has required shape', () => {
  const f = extractFiles();
  for (const entry of f.entries) {
    for (const imp of entry.imports) {
      assert.ok(['main', 'shared', 'extern'].includes(imp.package), `import.package on ${entry.path}: ${imp.package}`);
      assert.equal(typeof imp.path, 'string', `import.path on ${entry.path}`);
      assert.equal(typeof imp.type_only, 'boolean', `import.type_only on ${entry.path}`);
      assert.ok(['import', 're-export', 'dynamic-import'].includes(imp.kind), `import.kind on ${entry.path}: ${imp.kind}`);
      assert.equal(typeof imp.line, 'number', `import.line on ${entry.path}`);
      assert.ok(imp.line >= 1, `import.line is 1-indexed on ${entry.path}`);
    }
  }
});

test('files.json: basic relative import resolves with .ts extension probing', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/basic-import.ts');
  assert.equal(row.imports.length, 1);
  assert.deepEqual(row.imports[0], {
    package: 'main',
    path: 'src/target.ts',
    type_only: false,
    kind: 'import',
    line: 1,
  });
});

test('files.json: import type marks type_only true at the declaration level', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/type-only.ts');
  assert.equal(row.imports.length, 1);
  assert.equal(row.imports[0].type_only, true);
  assert.equal(row.imports[0].kind, 'import');
  assert.equal(row.imports[0].package, 'main');
  assert.equal(row.imports[0].path, 'src/target.ts');
});

test('files.json: per-specifier "import { type X }" is NOT marked type_only (v1 declaration-level only)', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/mixed-specifier.ts');
  assert.equal(row.imports.length, 1);
  assert.equal(row.imports[0].type_only, false,
    'v1 only inspects declaration-level importClause.isTypeOnly; per-specifier modifier is a documented gap');
});

test('files.json: export { X } from is captured as kind: re-export', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/re-export.ts');
  assert.equal(row.imports.length, 1);
  assert.deepEqual(row.imports[0], {
    package: 'main',
    path: 'src/target.ts',
    type_only: false,
    kind: 're-export',
    line: 1,
  });
});

test('files.json: export type { X } from marks type_only true on a re-export', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/re-export-type.ts');
  assert.equal(row.imports.length, 1);
  assert.equal(row.imports[0].kind, 're-export');
  assert.equal(row.imports[0].type_only, true);
});

test('files.json: import(\'./x\') is captured as kind: dynamic-import; template-literal form is skipped', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/dynamic-import.ts');
  // dynamic-import.ts has one resolvable call + one template-literal call
  // (unresolvable static target). Only the resolvable one is recorded.
  const dyn = row.imports.filter((i) => i.kind === 'dynamic-import');
  assert.equal(dyn.length, 1, `expected exactly 1 dynamic-import (template form should be skipped); got ${JSON.stringify(dyn)}`);
  assert.equal(dyn[0].package, 'main');
  assert.equal(dyn[0].path, 'src/target.ts');
  assert.equal(dyn[0].type_only, false);
});

test('files.json: unresolvable relative path is tagged extern with raw spec preserved', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/missing-import.ts');
  assert.equal(row.imports.length, 1);
  assert.equal(row.imports[0].package, 'extern');
  assert.equal(row.imports[0].path, './does-not-exist');
});

test('files.json: bare specifier is tagged extern with raw spec preserved', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/bare-import.ts');
  assert.equal(row.imports.length, 1);
  assert.equal(row.imports[0].package, 'extern');
  assert.equal(row.imports[0].path, 'drizzle-orm');
});

test('files.json: folder import resolves to <folder>/index.ts', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/index-folder-import.ts');
  assert.equal(row.imports.length, 1);
  assert.equal(row.imports[0].package, 'main');
  assert.equal(row.imports[0].path, 'src/sub-dir/index.ts');
});

test('files.json: cross-package import via --shared resolves to package: shared', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/cross-package.ts');
  assert.equal(row.imports.length, 1);
  assert.equal(row.imports[0].package, 'shared');
  assert.equal(row.imports[0].path, 'src/canonical.ts',
    'shared-package target path is relative to the SHARED root, not the file or the main root');
  assert.equal(row.imports[0].type_only, true);
});

test('files.json: is_test flag is true for .test.ts files', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/sample.test.ts');
  assert.equal(row.is_test, true);
});

test('files.json: is_test flag is false for non-test files', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/basic-import.ts');
  assert.equal(row.is_test, false);
});

test('files.json: entries[] sorted deterministically by (package, path)', () => {
  const f = extractFiles();
  const keys = f.entries.map((e) => `${e.package}:${e.path}`);
  const sorted = [...keys].sort();
  assert.deepEqual(keys, sorted, 'entries[] should be sorted by (package, path)');
});

test('files.json: imports[] sorted deterministically by (package, path, kind, line)', () => {
  const f = extractFiles();
  for (const entry of f.entries) {
    const keys = entry.imports.map((i) => `${i.package}|${i.path}|${i.kind}|${String(i.line).padStart(6, '0')}`);
    const sorted = [...keys].sort();
    assert.deepEqual(keys, sorted, `imports[] not sorted on ${entry.path}: ${JSON.stringify(keys)}`);
  }
});

test('files.json: shared package files also appear in entries[]', () => {
  const f = extractFiles();
  const row = fileRow(f, 'src/canonical.ts');
  assert.equal(row.package, 'shared');
});

test('files.json: existing catalog output remains unchanged when --emit-files is also passed', () => {
  // Determinism check: --emit-files should be a pure side effect. The primary
  // stdout (catalog) must NOT differ in extracted structure.
  //
  // Note: v1.2 introduces a wall-clock `generated_at` field, so byte-for-byte
  // equality between two runs is no longer expected; the comparison strips the
  // timestamp before asserting equality so the rest of the envelope remains a
  // determinism guard.
  const tmp = mkdtempSync(join(tmpdir(), 'files-test-'));
  try {
    const catalog1 = join(tmp, 'catalog-1.json');
    const catalog2 = join(tmp, 'catalog-2.json');
    const files1 = join(tmp, 'files.json');
    const res1 = runExtractor(['--shared', FIXTURES_SHARED, '--output', catalog1]);
    const res2 = runExtractor(['--shared', FIXTURES_SHARED, '--output', catalog2, '--emit-files', files1]);
    assert.equal(res1.status, 0);
    assert.equal(res2.status, 0);
    const a = JSON.parse(readFileSync(catalog1, 'utf8'));
    const b = JSON.parse(readFileSync(catalog2, 'utf8'));
    // Strip the wall-clock field; everything else must match exactly.
    delete a.generated_at;
    delete b.generated_at;
    assert.deepEqual(a, b, 'catalog envelope (excluding generated_at) and entries should be identical with/without --emit-files');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});
