// Tests for the TypeScript function-catalog extractor (#133, v1.2).
//
// Validates the v1.1+ wrapper shape, v1.2 identity/provenance metadata
// (fingerprint_v, generated_at, extractor.source_sha, per-entry symbol_id),
// signature-level fields (params/return_ref/references/generics), universal
// flags (is_test/touched_in_window/synthetic), body-fields gating, and
// overload-head representation. Mirrors the cache pattern used by
// extract.test.mjs (type-catalog tests).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const EXTRACTOR = join(__dirname, '..', 'function-catalog.mjs');
const FIXTURES_ROOT = join(__dirname, '..', 'fixtures');

function runExtractor(args = []) {
  return spawnSync('node', [EXTRACTOR, '--root', FIXTURES_ROOT, ...args], {
    encoding: 'utf8',
  });
}

let _cachedCatalog = null;
function extractCatalog() {
  if (_cachedCatalog) return _cachedCatalog;
  const res = runExtractor();
  if (res.status !== 0) {
    throw new Error(`extractor failed (status ${res.status}): ${res.stderr}`);
  }
  _cachedCatalog = JSON.parse(res.stdout);
  return _cachedCatalog;
}

function findEntriesByName(catalog, name) {
  return catalog.entries.filter((e) => e.name === name);
}

function findOne(catalog, name) {
  const matches = findEntriesByName(catalog, name);
  assert.equal(matches.length, 1, `expected 1 entry for "${name}", got ${matches.length}`);
  return matches[0];
}

test('function-catalog: exits 0 against the fixture tree', () => {
  const res = runExtractor();
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
});

test('function-catalog: output is wrapped as schema_version 1.2 with identity/provenance metadata', () => {
  const cat = extractCatalog();
  assert.equal(cat.schema_version, '1.2');
  assert.equal(cat.extractor.language, 'typescript');
  assert.equal(cat.extractor.name, 'function-catalog');
  assert.ok(/^\d+\.\d+\.\d+/.test(cat.extractor.version), `version: ${cat.extractor.version}`);
  assert.ok(typeof cat.extractor.source_sha === 'string' && cat.extractor.source_sha.length > 0,
    `source_sha: ${cat.extractor.source_sha}`);
  assert.equal(cat.fingerprint_v, 'shape_sig:1');
  assert.ok(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$/.test(cat.generated_at),
    `generated_at: ${cat.generated_at}`);
  assert.ok(Array.isArray(cat.entries));
  for (const e of cat.entries) {
    assert.ok(/^[0-9a-f]{40}$/.test(e.symbol_id),
      `symbol_id for ${e.kind}/${e.name}: ${e.symbol_id}`);
  }
});

test('function-catalog: noLeakPrimitives — primitives surface no type_refs', () => {
  const cat = extractCatalog();
  const fn = findOne(cat, 'noLeakPrimitives');
  assert.equal(fn.exported, true);
  assert.equal(fn.kind, 'function');
  assert.equal(fn.params.length, 2);
  assert.deepEqual(fn.params[0], { name: 's', type_ref: null, type_refs: [] });
  assert.deepEqual(fn.params[1], { name: 'n', type_ref: null, type_refs: [] });
  assert.equal(fn.return_ref, null);
  assert.deepEqual(fn.references, []);
  assert.equal(fn.references_count, 0);
});

test('function-catalog: noLeakPrimitives — one-liner body fields are null after gating', () => {
  const cat = extractCatalog();
  const fn = findOne(cat, 'noLeakPrimitives');
  assert.equal(fn.body_hash, null);
  assert.equal(fn.body_lines, null);
  assert.equal(fn.body_line_count, null);
  assert.equal(fn.body_length, null);
});

test('function-catalog: leakyHandler — typed param + return surface refs', () => {
  const cat = extractCatalog();
  const fn = findOne(cat, 'leakyHandler');
  assert.equal(fn.exported, true);
  assert.deepEqual(fn.params, [{
    name: 'req',
    type_ref: 'InternalRequest',
    type_refs: [{ name: 'InternalRequest', kind: 'type-ref' }],
  }]);
  assert.equal(fn.return_ref, 'PublicResponse');
  // references[] = sorted-deduped union of params + return ref.
  assert.deepEqual(fn.references, [
    { name: 'InternalRequest',  kind: 'type-ref' },
    { name: 'PublicResponse',   kind: 'type-ref' },
  ]);
  assert.equal(fn.references_count, 2);
});

test('function-catalog: leakyHandler — multi-line body keeps body fields populated', () => {
  const cat = extractCatalog();
  const fn = findOne(cat, 'leakyHandler');
  assert.ok(fn.body_hash !== null, 'body_hash should be set');
  assert.ok(Array.isArray(fn.body_lines) && fn.body_lines.length > 0);
  assert.ok(fn.body_line_count >= 3);
  assert.ok(fn.body_length > 0);
});

test('function-catalog: boxArrow — arrow-function via export const', () => {
  const cat = extractCatalog();
  const fn = findOne(cat, 'boxArrow');
  assert.equal(fn.exported, true);
  assert.equal(fn.kind, 'arrow-function');
  assert.equal(fn.generics, 'T');
  // T is a binding, must be filtered.
  assert.deepEqual(fn.params[0].type_refs, []);
  // Return is `{ wrapped: T }` — anonymous, not a single ref.
  assert.equal(fn.return_ref, null);
  assert.deepEqual(fn.references, []);
});

test('function-catalog: privateHelper — non-exported reflected', () => {
  const cat = extractCatalog();
  const fn = findOne(cat, 'privateHelper');
  assert.equal(fn.exported, false);
});

test('function-catalog: identity<T>(T): T — every ref is generic-bound, filtered', () => {
  const cat = extractCatalog();
  const fn = findOne(cat, 'identity');
  assert.equal(fn.generics, 'T');
  assert.deepEqual(fn.params[0].type_refs, []);
  assert.equal(fn.return_ref, null);  // T is a binding — not a real ref
  assert.deepEqual(fn.references, []);
});

test('function-catalog: overloaded — three rows with signature_index 0/1/2', () => {
  const cat = extractCatalog();
  const overloadRows = findEntriesByName(cat, 'overloaded');
  assert.equal(overloadRows.length, 3, 'expected 3 rows for overloaded (2 heads + 1 impl)');
  const indices = overloadRows.map((r) => r.signature_index).sort();
  assert.deepEqual(indices, [0, 1, 2]);
  // Exactly one row carries the impl body.
  const withBody = overloadRows.filter((r) => r.body_hash !== null);
  assert.equal(withBody.length, 1, 'exactly one overload row should have non-null body_hash (the impl)');
  // The other two have no body.
  const noBody = overloadRows.filter((r) => r.body_hash === null);
  assert.equal(noBody.length, 2);
});

test('function-catalog: universal flags present on every entry', () => {
  const cat = extractCatalog();
  for (const entry of cat.entries) {
    assert.equal(typeof entry.is_test, 'boolean', `is_test on ${entry.name}`);
    assert.equal(typeof entry.touched_in_window, 'boolean', `touched_in_window on ${entry.name}`);
    assert.equal(typeof entry.synthetic, 'boolean', `synthetic on ${entry.name}`);
    assert.equal(entry.synthetic, false, `synthetic must be false today on ${entry.name}`);
  }
});

test('function-catalog: every entry has required signature fields', () => {
  const cat = extractCatalog();
  for (const entry of cat.entries) {
    assert.ok(Array.isArray(entry.params), `params is array on ${entry.name}`);
    for (const param of entry.params) {
      assert.equal(typeof param.name, 'string', `param.name on ${entry.name}`);
      assert.ok('type_ref' in param, `param.type_ref present on ${entry.name}`);
      assert.ok(Array.isArray(param.type_refs), `param.type_refs is array on ${entry.name}`);
    }
    assert.ok('return_ref' in entry, `return_ref present on ${entry.name}`);
    assert.ok(Array.isArray(entry.references), `references is array on ${entry.name}`);
    assert.equal(typeof entry.references_count, 'number');
    assert.equal(entry.references_count, entry.references.length);
    assert.equal(typeof entry.signature_index, 'number');
  }
});

test('function-catalog: references[] is sorted by name', () => {
  const cat = extractCatalog();
  for (const entry of cat.entries) {
    const names = entry.references.map((r) => r.name);
    const sorted = [...names].sort();
    assert.deepEqual(names, sorted, `references not sorted on ${entry.name}: ${JSON.stringify(names)}`);
  }
});
