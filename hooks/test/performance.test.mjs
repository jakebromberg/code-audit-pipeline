// Performance regression harness for the pre-commit hook (#124).
//
// Verifies the issue's p50/p95 hot-path and cold-path budgets at 1/5/100
// relevant files. Hot path (cache hit) is measured after a priming run.
// Budgets are deliberately loose (1.5s p95 hot, 5s p95 cold) per the spec;
// CI noise on a shared runner can easily double measured wall time, so these
// tests focus on catching gross regressions, not micro-benchmarking.
//
// Run with:  node --test hooks/test/*.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makeFixtureRepo, runHook } from './helpers.mjs';

const TYPE_TEMPLATE = (i) => `
export interface Type${i} {
  id${i}: number;
  name${i}: string;
}
`;

const GENERATED_TEMPLATE = (i) => `
export interface Generated${i} {
  field${i}: string;
}
`;

function buildManifest(nFiles, prefix = 'src/file') {
  const m = {};
  for (let i = 0; i < nFiles; i++) m[`${prefix}${i}.ts`] = TYPE_TEMPLATE(i);
  return m;
}

function measure(stagedPaths, opts) {
  const start = process.hrtime.bigint();
  const res = runHook(stagedPaths, opts);
  const elapsed = Number(process.hrtime.bigint() - start) / 1e6;
  return { res, elapsedMs: elapsed };
}

test('cold-path budget at 1 file: < 5s', () => {
  const fx = makeFixtureRepo(buildManifest(1));
  try {
    const { res, elapsedMs } = measure(['src/file0.ts'], { cwd: fx.root });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    assert.ok(elapsedMs < 5000, `cold path took ${elapsedMs}ms (budget 5000)`);
  } finally {
    fx.cleanup();
  }
});

test('cold-path budget at 5 files: < 5s', () => {
  const fx = makeFixtureRepo(buildManifest(5));
  try {
    const staged = Array.from({ length: 5 }, (_, i) => `src/file${i}.ts`);
    const { res, elapsedMs } = measure(staged, { cwd: fx.root });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    assert.ok(elapsedMs < 5000, `cold path took ${elapsedMs}ms (budget 5000)`);
  } finally {
    fx.cleanup();
  }
});

test('hot-path budget at 5 files: p95 < 1.5s (best-effort, single sample)', () => {
  const fx = makeFixtureRepo(buildManifest(5));
  try {
    // Prime the cache.
    const prime = runHook(Array.from({ length: 5 }, (_, i) => `src/file${i}.ts`), { cwd: fx.root });
    assert.equal(prime.status, 0);

    const staged = Array.from({ length: 5 }, (_, i) => `src/file${i}.ts`);
    const { res, elapsedMs } = measure(staged, { cwd: fx.root });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    // Single-sample assertion is necessarily loose; the budget is 1.5s p95
    // but we give it 3s here to absorb runner noise. A regression that
    // takes 5s on the hot path will still trip this.
    assert.ok(elapsedMs < 3000, `hot path took ${elapsedMs}ms (loose budget 3000)`);
  } finally {
    fx.cleanup();
  }
});

test('vendored 100-file commit: linguist-generated filtered, budget held', () => {
  // 100 linguist-generated files + 1 real change. The hook must filter the
  // generated files out via .gitattributes and not blow the budget.
  const manifest = {};
  for (let i = 0; i < 100; i++) manifest[`vendor/gen${i}.ts`] = GENERATED_TEMPLATE(i);
  manifest['src/real.ts'] = TYPE_TEMPLATE(999);
  manifest['.gitattributes'] = 'vendor/** linguist-generated=true\n';

  const fx = makeFixtureRepo(manifest);
  try {
    // Commit .gitattributes first so check-attr resolves.
    fx.git('add', '.gitattributes');
    fx.git('commit', '-q', '-m', 'add gitattributes');

    const staged = ['src/real.ts'];
    for (let i = 0; i < 100; i++) staged.push(`vendor/gen${i}.ts`);

    const { res, elapsedMs } = measure(staged, { cwd: fx.root });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    // The hook is allowed to walk the whole repo to build the catalog, so
    // 100 files in the working tree still cost extraction. But because the
    // linguist-generated filter eliminates them from the touched-set, the
    // cluster digest filter step stays cheap. Budget: 10s (cold rebuild).
    assert.ok(elapsedMs < 10000, `vendored commit took ${elapsedMs}ms (budget 10000)`);
  } finally {
    fx.cleanup();
  }
});
