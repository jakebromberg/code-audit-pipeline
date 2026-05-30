// Tests for the TypeScript type-catalog extractor.
//
// Runs the extractor (as a subprocess) against the fixtures/ tree and asserts
// each emitted catalog entry matches the spec in docs/pipeline-contract.md.
//
// Run with:  node --test test/*.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync, mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';

const __dirname = dirname(fileURLToPath(import.meta.url));
const EXTRACTOR = join(__dirname, '..', 'type-catalog.mjs');
const FIXTURES_ROOT = join(__dirname, '..', 'fixtures');

function runExtractor(args = []) {
  return spawnSync('node', [EXTRACTOR, '--root', FIXTURES_ROOT, ...args], {
    encoding: 'utf8',
  });
}

// Cached across the suite: the fixture tree doesn't change between tests, so
// spawning the extractor 20+ times instead of once is pure overhead. Tests
// that need a fresh subprocess (exit-code checks, determinism cross-run,
// --emit-references-graph artifact) call `runExtractor()` directly instead.
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

function findEntry(catalog, name) {
  return catalog.entries.find((e) => e.name === name);
}

test('extractor exits 0 against the fixture tree', () => {
  const res = runExtractor();
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
});

test('output is wrapped as schema_version 1.1', () => {
  const cat = extractCatalog();
  assert.equal(cat.schema_version, '1.1');
  assert.equal(cat.extractor.language, 'typescript');
  assert.equal(cat.extractor.name, 'type-catalog');
  assert.ok(/^\d+\.\d+\.\d+/.test(cat.extractor.version), `version: ${cat.extractor.version}`);
  assert.ok(Array.isArray(cat.entries));
});

test('fixture 01: User interface, no heritage, primitive fields', () => {
  const cat = extractCatalog();
  const user = findEntry(cat, 'User');
  assert.ok(user, 'User entry should exist');
  assert.equal(user.kind, 'interface');
  assert.equal(user.exported, true);
  assert.deepEqual(user.extends, []);
  assert.deepEqual(user.references, []);
  assert.equal(user.references_count, 0);
});

test('fixture 02: Child extends Parent, Sibling (sorted alpha)', () => {
  const cat = extractCatalog();
  const child = findEntry(cat, 'Child');
  assert.ok(child, 'Child entry should exist');
  assert.deepEqual(child.extends, ['Parent', 'Sibling']);
});

test('fixture 03: type-alias-object references the named field type', () => {
  const cat = extractCatalog();
  const holder = findEntry(cat, 'Holder');
  assert.ok(holder, 'Holder entry should exist');
  assert.deepEqual(holder.references, [{ name: 'Inner', kind: 'type-ref' }]);
  assert.equal(holder.references_count, 1);
});

test('fixture 06: generic bound surfaces but type param T does not', () => {
  const cat = extractCatalog();
  const box = findEntry(cat, 'Box');
  assert.ok(box, 'Box entry should exist');
  assert.deepEqual(box.references, [{ name: 'Item', kind: 'type-ref' }]);
});

test('fixture 07: shadowed generic parameter T is scoped out', () => {
  const cat = extractCatalog();
  const outer = findEntry(cat, 'Outer');
  assert.ok(outer, 'Outer entry should exist');
  assert.deepEqual(outer.references, []);
});

test('fixture 08: deny-list excludes Pick, Omit, Partial, Promise, Array', () => {
  const cat = extractCatalog();
  const slice = findEntry(cat, 'UserSlice');
  const maybe = findEntry(cat, 'UserMaybe');
  const prom = findEntry(cat, 'UserPromise');
  assert.deepEqual(slice.references, [{ name: 'UserInput', kind: 'type-ref' }]);
  assert.deepEqual(maybe.references, [{ name: 'UserInput', kind: 'type-ref' }]);
  assert.deepEqual(prom.references, [{ name: 'UserInput', kind: 'type-ref' }]);
});

test('fixture 09: typeof query emits the queried identifier', () => {
  const cat = extractCatalog();
  const t = findEntry(cat, 'TableShape');
  assert.ok(t);
  assert.deepEqual(t.references, [{ name: 'userTable', kind: 'type-ref' }]);
});

test('fixture 10: import("...").Y emits Y', () => {
  const cat = extractCatalog();
  const h = findEntry(cat, 'RemoteHolder');
  assert.ok(h);
  assert.deepEqual(h.references, [{ name: 'Remote', kind: 'type-ref' }]);
});

test('fixture 11: mapped type with scoped K and T emits no references', () => {
  const cat = extractCatalog();
  const s = findEntry(cat, 'Stringified');
  assert.ok(s);
  assert.deepEqual(s.references, []);
});

test('fixture 14: tuple, array, readonly array all surface element refs', () => {
  const cat = extractCatalog();
  const triple = findEntry(cat, 'Triple');
  assert.ok(triple);
  assert.deepEqual(triple.references, [
    { name: 'A', kind: 'type-ref' },
    { name: 'B', kind: 'type-ref' },
    { name: 'C', kind: 'type-ref' },
  ]);
});

test('fixture 15: function type parameter and return refs surface', () => {
  const cat = extractCatalog();
  const t = findEntry(cat, 'Transform');
  assert.ok(t);
  assert.deepEqual(t.references, [
    { name: 'Input', kind: 'type-ref' },
    { name: 'Output', kind: 'type-ref' },
  ]);
});

test('fixture 12: conditional type surfaces identifiers in all three positions', () => {
  const cat = extractCatalog();
  const c = findEntry(cat, 'Cond');
  assert.ok(c);
  assert.deepEqual(c.references, [
    { name: 'Bound', kind: 'type-ref' },
    { name: 'FalseBranch', kind: 'type-ref' },
    { name: 'TrueBranch', kind: 'type-ref' },
  ]);
});

test('fixture 13: self-recursive interface emits itself as a reference', () => {
  const cat = extractCatalog();
  const t = findEntry(cat, 'TreeNode');
  assert.ok(t);
  assert.deepEqual(t.references, [{ name: 'TreeNode', kind: 'type-ref' }]);
});

test('fixture 16: template literal type surfaces embedded refs', () => {
  const cat = extractCatalog();
  const g = findEntry(cat, 'Greeting');
  assert.ok(g);
  assert.deepEqual(g.references, [{ name: 'Name', kind: 'type-ref' }]);
});

test('fixture 05: intersection named operands go into extends, all in references', () => {
  const cat = extractCatalog();
  const c = findEntry(cat, 'Combined');
  assert.ok(c);
  assert.deepEqual(c.extends, ['BaseA', 'BaseB']);
  assert.deepEqual(c.references, [
    { name: 'BaseA', kind: 'type-ref' },
    { name: 'BaseB', kind: 'type-ref' },
  ]);
});

test('fixture 17: zod-object emits empty references in v1', () => {
  const cat = extractCatalog();
  const s = findEntry(cat, 'UserSchema');
  assert.ok(s);
  assert.equal(s.kind, 'zod-object');
  assert.deepEqual(s.references, []);
});

test('fixture 18: drizzle-table emits empty references in v1', () => {
  const cat = extractCatalog();
  const p = findEntry(cat, 'posts');
  assert.ok(p);
  assert.equal(p.kind, 'drizzle-table');
  assert.deepEqual(p.references, []);
});

test('fixture 19: legacy InferSelectModel and modern $inferSelect both reference the table', () => {
  const cat = extractCatalog();
  const legacy = findEntry(cat, 'LegacyUser');
  const modern = findEntry(cat, 'ModernUser');
  assert.ok(legacy);
  assert.ok(modern);
  assert.deepEqual(legacy.references, [{ name: 'usersTable', kind: 'type-ref' }]);
  assert.deepEqual(modern.references, [{ name: 'usersTable', kind: 'type-ref' }]);
});

test('fixture 04: union variants surface as references, not extends', () => {
  const cat = extractCatalog();
  const r = findEntry(cat, 'Result');
  assert.ok(r);
  assert.equal(r.kind, 'type-alias-union');
  assert.deepEqual(r.extends, []);
  assert.deepEqual(r.references, [
    { name: 'Err', kind: 'type-ref' },
    { name: 'Ok', kind: 'type-ref' },
  ]);
});

test('fixture 20: declarations referencing only built-ins surface no references', () => {
  const cat = extractCatalog();
  const b = findEntry(cat, 'OnlyBuiltins');
  assert.ok(b);
  assert.deepEqual(b.references, []);
});

test('--emit-references-graph writes a sibling references.json with sorted, deduped edges', () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tc-refs-'));
  const refsPath = join(tmp, 'references.json');
  try {
    const res = runExtractor(['--emit-references-graph', refsPath]);
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    assert.ok(existsSync(refsPath), 'references.json should be created');
    const refs = JSON.parse(readFileSync(refsPath, 'utf8'));
    assert.equal(refs.schema_version, '1.1');
    assert.deepEqual(refs.extractor, { language: 'typescript', name: 'type-catalog', version: refs.extractor.version });
    assert.match(refs.extractor.version, /^\d+\.\d+\.\d+$/, 'extractor.version must be semver-shaped');
    assert.ok(Array.isArray(refs.edges));
    assert.ok(refs.edges.length > 0, 'expected at least one edge');
    for (const edge of refs.edges) {
      assert.ok(edge.from?.package && edge.from?.name, `bad from: ${JSON.stringify(edge)}`);
      assert.ok(edge.to?.package && edge.to?.name, `bad to: ${JSON.stringify(edge)}`);
      assert.equal(edge.kind, 'type-ref');
      assert.equal(typeof edge.resolved, 'boolean');
    }

    // Resolved-same-package: Holder → Inner (both declared in fixture 03).
    const holderInner = refs.edges.find(
      (e) => e.from.name === 'Holder' && e.to.name === 'Inner',
    );
    assert.ok(holderInner, 'Holder → Inner edge should exist');
    assert.equal(holderInner.resolved, true);
    assert.equal(holderInner.to.package, holderInner.from.package);

    // Unresolved-external: RemoteHolder → Remote (Remote is in an imported
    // module not present in the fixture tree).
    const remote = refs.edges.find(
      (e) => e.from.name === 'RemoteHolder' && e.to.name === 'Remote',
    );
    assert.ok(remote, 'RemoteHolder → Remote edge should exist');
    assert.equal(remote.resolved, false);
    assert.equal(remote.to.package, remote.from.package); // fallback

    // Deduplication: every (from.package, from.name, to.package, to.name) pair unique.
    const seen = new Set();
    for (const e of refs.edges) {
      const key = `${e.from.package}|${e.from.name}|${e.to.package}|${e.to.name}`;
      assert.ok(!seen.has(key), `duplicate edge: ${key}`);
      seen.add(key);
    }

    // Determinism: a second invocation produces byte-identical output.
    const refsPath2 = join(tmp, 'references-2.json');
    runExtractor(['--emit-references-graph', refsPath2]);
    assert.equal(
      readFileSync(refsPath, 'utf8'),
      readFileSync(refsPath2, 'utf8'),
      'two runs must produce identical references.json',
    );
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('without --emit-references-graph, no sibling file is created', () => {
  const tmp = mkdtempSync(join(tmpdir(), 'tc-refs-'));
  const refsPath = join(tmp, 'references.json');
  try {
    runExtractor();
    assert.equal(existsSync(refsPath), false, 'sibling file should not exist without the flag');
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
});

test('output is deterministic across runs', () => {
  const a = runExtractor();
  const b = runExtractor();
  assert.equal(a.stdout, b.stdout, 'two invocations must produce byte-identical stdout');
});

test('extends and references arrays are sorted on every entry', () => {
  const cat = extractCatalog();
  for (const e of cat.entries) {
    if (e.extends) {
      const sorted = [...e.extends].sort();
      assert.deepEqual(e.extends, sorted, `extends not sorted on ${e.name}`);
    }
    if (e.references) {
      const sorted = [...e.references].sort((a, b) => a.name.localeCompare(b.name));
      assert.deepEqual(e.references, sorted, `references not sorted on ${e.name}`);
    }
  }
});

test('every entry carries default extends/references/references_count', () => {
  const cat = extractCatalog();
  for (const e of cat.entries) {
    assert.ok(Array.isArray(e.extends), `${e.name} missing extends`);
    assert.ok(Array.isArray(e.references), `${e.name} missing references`);
    assert.equal(typeof e.references_count, 'number', `${e.name} missing references_count`);
    assert.equal(e.references_count, e.references.length, `${e.name}: references_count mismatch`);
  }
});
