// Tests for _lib/origin-package.mjs (bare-specifier resolver).
//
// Run with:  node --test test/origin-package.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { resolveOriginPackage } from '../_lib/origin-package.mjs';

test('unscoped bare specifier resolves to itself', () => {
  assert.deepEqual(resolveOriginPackage('lodash'), {
    origin_package: 'lodash',
    origin_resolution: 'bare-specifier',
  });
});

test('unscoped subpath strips to bare package', () => {
  assert.deepEqual(resolveOriginPackage('lodash/fp'), {
    origin_package: 'lodash',
    origin_resolution: 'bare-specifier',
  });
});

test('unscoped deep subpath strips to bare package', () => {
  assert.deepEqual(resolveOriginPackage('lodash/fp/curry'), {
    origin_package: 'lodash',
    origin_resolution: 'bare-specifier',
  });
});

test('scoped bare specifier resolves to scope/name', () => {
  assert.deepEqual(resolveOriginPackage('@wxyc/shared'), {
    origin_package: '@wxyc/shared',
    origin_resolution: 'bare-specifier',
  });
});

test('scoped subpath strips to scope/name', () => {
  assert.deepEqual(resolveOriginPackage('@wxyc/shared/dtos/lookup'), {
    origin_package: '@wxyc/shared',
    origin_resolution: 'bare-specifier',
  });
});

test('current-dir relative specifier returns null package', () => {
  assert.deepEqual(resolveOriginPackage('./local'), {
    origin_package: null,
    origin_resolution: 'relative',
  });
});

test('parent-dir relative specifier returns null package', () => {
  assert.deepEqual(resolveOriginPackage('../sibling/foo'), {
    origin_package: null,
    origin_resolution: 'relative',
  });
});

test('absolute path returns null package', () => {
  assert.deepEqual(resolveOriginPackage('/abs/path'), {
    origin_package: null,
    origin_resolution: 'relative',
  });
});

test('scope-only (no second segment) falls back to the scope as the package', () => {
  // Pathological — not a legal npm name, but the resolver must not throw.
  assert.deepEqual(resolveOriginPackage('@scope'), {
    origin_package: '@scope',
    origin_resolution: 'bare-specifier',
  });
});

test('side-effect bare specifier resolves identically to a named import (the row-shape difference is in the emitter, not the resolver)', () => {
  // `import "pkg/polyfills"` — the resolver only cares about the specifier text.
  assert.deepEqual(resolveOriginPackage('pkg/polyfills'), {
    origin_package: 'pkg',
    origin_resolution: 'bare-specifier',
  });
});

test('side-effect relative specifier returns null package', () => {
  // `import "./register-globals"` — relative side-effect imports look identical
  // to relative named imports at the resolver level.
  assert.deepEqual(resolveOriginPackage('./register-globals'), {
    origin_package: null,
    origin_resolution: 'relative',
  });
});
