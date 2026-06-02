// Tests for the TypeScript type-catalog --include-imports flag.
//
// Each per-form fixture under fixtures-imports/ is matched against the
// expected row set. Also asserts:
//   - With the flag OFF, zero `kind: "import"` rows are emitted.
//   - With the flag ON, the entry count grows by exactly the expected import
//     count (catches silent drops).

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const EXTRACTOR = join(__dirname, '..', 'type-catalog.mjs');
const FIXTURES_ROOT = join(__dirname, '..', 'fixtures-imports');

function runExtractor(args = []) {
  const res = spawnSync('node', [EXTRACTOR, '--root', FIXTURES_ROOT, ...args], {
    encoding: 'utf8',
  });
  if (res.status !== 0) {
    throw new Error(`extractor failed (status ${res.status}): ${res.stderr}`);
  }
  return JSON.parse(res.stdout);
}

function importsFor(catalog, file) {
  return catalog.entries
    .filter((e) => e.kind === 'import' && e.file === file)
    .map((e) => ({
      name: e.name,
      imported_as: e.imported_as,
      import_form: e.import_form,
      origin_specifier: e.origin_specifier,
      origin_package: e.origin_package,
      origin_resolution: e.origin_resolution,
      type_only: e.type_only,
    }));
}

let _cachedWith = null;
let _cachedWithout = null;
function catalogWithImports() {
  if (_cachedWith) return _cachedWith;
  _cachedWith = runExtractor(['--include-imports']);
  return _cachedWith;
}
function catalogWithoutImports() {
  if (_cachedWithout) return _cachedWithout;
  _cachedWithout = runExtractor();
  return _cachedWithout;
}

test('without --include-imports, no kind:"import" rows are emitted', () => {
  const cat = catalogWithoutImports();
  const importRows = cat.entries.filter((e) => e.kind === 'import');
  assert.equal(importRows.length, 0);
});

test('with --include-imports, entry count grows by exactly the expected import count', () => {
  const cat = catalogWithImports();
  const baseline = catalogWithoutImports();
  const importRows = cat.entries.filter((e) => e.kind === 'import');
  assert.equal(importRows.length, 28, `unexpected import row count: ${importRows.length}`);
  assert.equal(cat.entries.length, baseline.entries.length + 28);
});

test('filtering out kind:"import" matches the no-flag catalog byte-for-byte', () => {
  const a = catalogWithImports().entries.filter((e) => e.kind !== 'import');
  const b = catalogWithoutImports().entries;
  assert.deepEqual(a, b);
});

test('every import row carries the shape-uniformity defaults', () => {
  const cat = catalogWithImports();
  for (const e of cat.entries.filter((r) => r.kind === 'import')) {
    assert.equal(e.exported, false, `${e.file}:${e.line} ${e.name}`);
    assert.deepEqual(e.extends, []);
    assert.deepEqual(e.references, []);
    assert.equal(e.references_count, 0);
  }
});

test('named: emits one row per imported binding with alias preserved', () => {
  const rows = importsFor(catalogWithImports(), '01-named.ts');
  assert.deepEqual(rows, [
    {
      name: 'DiscogsTrack', imported_as: 'DiscogsTrack', import_form: 'named',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: 'DiscogsAlbum', imported_as: 'Album', import_form: 'named',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: 'z', imported_as: 'z', import_form: 'named',
      origin_specifier: 'zod', origin_package: 'zod',
      origin_resolution: 'bare-specifier', type_only: false,
    },
  ]);
});

test('default: name="default", imported_as is the local binding', () => {
  const rows = importsFor(catalogWithImports(), '02-default.ts');
  assert.deepEqual(rows, [
    {
      name: 'default', imported_as: 'shared', import_form: 'default',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
  ]);
});

test('namespace: name="*", imported_as is the namespace identifier', () => {
  const rows = importsFor(catalogWithImports(), '03-namespace.ts');
  assert.deepEqual(rows, [
    {
      name: '*', imported_as: 'shared', import_form: 'namespace',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
  ]);
});

test('type-only: declaration- and per-binding type_only both surface as true', () => {
  const rows = importsFor(catalogWithImports(), '04-type-only.ts');
  assert.deepEqual(rows, [
    {
      name: 'DiscogsTrack', imported_as: 'DiscogsTrack', import_form: 'named',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: true,
    },
    {
      name: 'DiscogsAlbum', imported_as: 'DiscogsAlbum', import_form: 'named',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: true,
    },
    {
      name: 'formatTitle', imported_as: 'formatTitle', import_form: 'named',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
  ]);
});

test('side-effect: name and imported_as are null; bare vs relative resolution still records', () => {
  const rows = importsFor(catalogWithImports(), '05-side-effect.ts');
  assert.deepEqual(rows, [
    {
      name: null, imported_as: null, import_form: 'side-effect',
      origin_specifier: '@wxyc/shared/polyfills', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: null, imported_as: null, import_form: 'side-effect',
      origin_specifier: './local-register', origin_package: null,
      origin_resolution: 'relative', type_only: false,
    },
  ]);
});

test('re-export: named + star + namespace-export + type-only all flow through', () => {
  const rows = importsFor(catalogWithImports(), '06-reexport.ts');
  assert.deepEqual(rows, [
    {
      name: 'DiscogsTrack', imported_as: 'DiscogsTrack', import_form: 're-export',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: '*', imported_as: '*', import_form: 're-export',
      origin_specifier: '@wxyc/shared/dtos', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: '*', imported_as: 'bundle', import_form: 're-export',
      origin_specifier: '@wxyc/shared/bundle', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: 'DiscogsAlbum', imported_as: 'DiscogsAlbum', import_form: 're-export',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: true,
    },
  ]);
});

test('dynamic: string-literal spec resolves; templated spec records <computed>', () => {
  const rows = importsFor(catalogWithImports(), '07-dynamic.ts');
  assert.deepEqual(rows, [
    {
      name: '*', imported_as: null, import_form: 'dynamic',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: '*', imported_as: null, import_form: 'dynamic',
      origin_specifier: '<computed>', origin_package: null,
      origin_resolution: 'computed', type_only: false,
    },
  ]);
});

test('require: namespace, destructured (with alias), and call-statement all emit', () => {
  const rows = importsFor(catalogWithImports(), '08-require.ts');
  assert.deepEqual(rows, [
    {
      name: '*', imported_as: 'shared', import_form: 'require',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: 'DiscogsTrack', imported_as: 'DiscogsTrack', import_form: 'require',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: 'DiscogsAlbum', imported_as: 'Album', import_form: 'require',
      origin_specifier: '@wxyc/shared', origin_package: '@wxyc/shared',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: '*', imported_as: null, import_form: 'require',
      origin_specifier: './register-side-effects', origin_package: null,
      origin_resolution: 'relative', type_only: false,
    },
  ]);
});

test('relative and absolute specifiers record origin_package=null, resolution="relative"', () => {
  const rows = importsFor(catalogWithImports(), '09-relative.ts');
  assert.deepEqual(rows, [
    {
      name: 'Helper', imported_as: 'Helper', import_form: 'named',
      origin_specifier: './local', origin_package: null,
      origin_resolution: 'relative', type_only: false,
    },
    {
      name: 'Sibling', imported_as: 'Sibling', import_form: 'named',
      origin_specifier: '../sibling/foo', origin_package: null,
      origin_resolution: 'relative', type_only: false,
    },
    {
      name: 'default', imported_as: 'abs', import_form: 'default',
      origin_specifier: '/abs/path', origin_package: null,
      origin_resolution: 'relative', type_only: false,
    },
  ]);
});

test('empty-named: `import {} from "pkg"` emits a single side-effect row', () => {
  // Empty named-imports clause is semantically equivalent to a side-effect
  // import — the consumer-edge to the package must still be recorded.
  const rows = importsFor(catalogWithImports(), '11-empty-named.ts');
  assert.deepEqual(rows, [
    {
      name: null, imported_as: null, import_form: 'side-effect',
      origin_specifier: '@wxyc/empty-named', origin_package: '@wxyc/empty-named',
      origin_resolution: 'bare-specifier', type_only: false,
    },
  ]);
});

test('nested-require: all-nested destructure falls through to namespace require so the package edge survives', () => {
  // `const { a: { b } } = require('pkg')` — every element is a nested
  // binding pattern. Previously dropped silently; now records the package
  // edge with name="*" and no local alias.
  const rows = importsFor(catalogWithImports(), '12-nested-require.ts');
  assert.deepEqual(rows, [
    {
      name: '*', imported_as: null, import_form: 'require',
      origin_specifier: '@wxyc/nested-require', origin_package: '@wxyc/nested-require',
      origin_resolution: 'bare-specifier', type_only: false,
    },
  ]);
});

test('mixed: default + named bindings from one statement emit in source order', () => {
  const rows = importsFor(catalogWithImports(), '10-mixed.ts');
  assert.deepEqual(rows, [
    {
      name: 'default', imported_as: 'defaultExport', import_form: 'default',
      origin_specifier: '@wxyc/mixed', origin_package: '@wxyc/mixed',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: 'Named', imported_as: 'Named', import_form: 'named',
      origin_specifier: '@wxyc/mixed', origin_package: '@wxyc/mixed',
      origin_resolution: 'bare-specifier', type_only: false,
    },
    {
      name: 'Other', imported_as: 'Alias', import_form: 'named',
      origin_specifier: '@wxyc/mixed', origin_package: '@wxyc/mixed',
      origin_resolution: 'bare-specifier', type_only: false,
    },
  ]);
});
