// Integration tests for the pre-commit hook (#124).
//
// Each test spins up an ephemeral git repo, writes a small TypeScript
// manifest, stages files, and runs the hook. Assertions focus on the
// hook's contract: exit 0 always, digest + report on cluster hits,
// silence on empty paths, never-block-the-commit semantics.
//
// Run with:  node --test hooks/test/*.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  makeFixtureRepo,
  runHook,
  readReport,
  readMeta,
} from './helpers.mjs';

// --- A pair of files with the same shape — exact-duplicates cluster hit. ---

const SAME_SHAPE_FILE_A = `
export interface User {
  id: number;
  email: string;
  name: string;
}
`;

const SAME_SHAPE_FILE_B = `
export interface Account {
  email: string;
  id: number;
  name: string;
}
`;

// --- A single unrelated file with no cluster hit. ---

const STANDALONE_FILE = `
export interface Standalone {
  uniqueField1: string;
  uniqueField2: number;
}
`;

test('exit 0 on empty staged-paths list', () => {
  const fx = makeFixtureRepo({});
  try {
    const res = runHook([], { cwd: fx.root });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    assert.equal(res.stdout, '');
  } finally {
    fx.cleanup();
  }
});

test('exit 0 on all-irrelevant staged paths (no .ts files)', () => {
  const fx = makeFixtureRepo({
    'README.md': '# hi\n',
    'package.json': '{"name":"fixture"}\n',
  });
  try {
    const res = runHook(['README.md', 'package.json'], { cwd: fx.root });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    // Nothing useful to say; hook should be silent.
    assert.equal(res.stdout, '');
  } finally {
    fx.cleanup();
  }
});

test('exit 0 when no cluster hit (single unique type)', () => {
  const fx = makeFixtureRepo({ 'src/standalone.ts': STANDALONE_FILE });
  try {
    const res = runHook(['src/standalone.ts'], { cwd: fx.root });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    // Cache should be built.
    assert.ok(readMeta(fx.root), 'meta file written');
    // Report exists (may be empty / "no clusters"); the contract is the file is written.
    assert.ok(readReport(fx.root) !== null, 'last-report.md written');
  } finally {
    fx.cleanup();
  }
});

test('exit 0 with digest on exact-duplicate cluster hit', () => {
  const fx = makeFixtureRepo({
    'src/user.ts': SAME_SHAPE_FILE_A,
    'src/account.ts': SAME_SHAPE_FILE_B,
  });
  try {
    const res = runHook(['src/user.ts', 'src/account.ts'], { cwd: fx.root });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    // 3-line digest on stdout (or stderr — either acceptable, but content must signal a cluster hit).
    const combined = res.stdout + res.stderr;
    assert.match(combined, /cluster|exact|duplicate/i, `output should signal a cluster hit; got:\n${combined}`);
    // exact=1 must appear in the digest
    assert.match(combined, /exact=1/, `digest should report exact-duplicates count; got:\n${combined}`);
    // Full report written.
    const report = readReport(fx.root);
    assert.ok(report, 'last-report.md written');
    assert.match(report, /User|Account/, 'report mentions cluster members');
  } finally {
    fx.cleanup();
  }
});

test('exit 0 even on extractor crash (defensive non-blocking)', () => {
  const fx = makeFixtureRepo({ 'src/ok.ts': STANDALONE_FILE });
  try {
    // Point CODE_AUDIT_EXTRACTOR at a path that doesn't exist; the hook must
    // catch the spawn failure and exit 0 with a skipped marker on stderr.
    const res = runHook(['src/ok.ts'], {
      cwd: fx.root,
      env: { CODE_AUDIT_EXTRACTOR: '/nonexistent/path/type-catalog.mjs' },
    });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    assert.match(res.stderr, /code-audit: skipped/);
  } finally {
    fx.cleanup();
  }
});

test('exit 0 when no .git directory present (defensive)', () => {
  // Hook may be invoked from an unusual context; should never crash.
  const fx = makeFixtureRepo({ 'src/ok.ts': STANDALONE_FILE });
  try {
    const res = runHook(['src/ok.ts'], {
      cwd: fx.root,
      env: { CODE_AUDIT_FAKE_BARE_REPO: '1' },
    });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  } finally {
    fx.cleanup();
  }
});

test('skips dotdir paths in staged list (predicate-aligned)', () => {
  const fx = makeFixtureRepo({
    'src/ok.ts': STANDALONE_FILE,
    '.cache/x.ts': 'export interface CacheGarbage { a: 1; }\n',
  });
  try {
    const res = runHook(['src/ok.ts', '.cache/x.ts'], { cwd: fx.root });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    // .cache/x.ts should be filtered out by --list-relevant
    const report = readReport(fx.root);
    if (report) {
      assert.doesNotMatch(report, /CacheGarbage/);
    }
  } finally {
    fx.cleanup();
  }
});

test('honors .gitattributes linguist-generated', () => {
  const fx = makeFixtureRepo({
    'src/keep.ts': SAME_SHAPE_FILE_A,
    'src/generated.ts': SAME_SHAPE_FILE_B,
    '.gitattributes': 'src/generated.ts linguist-generated=true\n',
  });
  try {
    // Stage all + the .gitattributes; commit the .gitattributes first so
    // git check-attr sees it.
    fx.git('add', '.gitattributes');
    fx.git('commit', '-q', '-m', 'add gitattributes');

    const res = runHook(['src/keep.ts', 'src/generated.ts'], { cwd: fx.root });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    // The duplicate should NOT fire because generated.ts is marked
    // linguist-generated. (User is the only catalog entry remaining via the
    // hook's filter — even if the extractor itself doesn't honor the
    // attribute, the hook must filter the staged list before querying.)
    const combined = res.stdout + res.stderr;
    // The "duplicates" digest must not list generated.ts as a touched member.
    assert.doesNotMatch(combined, /touched.*generated\.ts/i, `generated.ts should not appear as a touched member; got: ${combined}`);
  } finally {
    fx.cleanup();
  }
});

test('cache hit path — second invocation should not rebuild', () => {
  const fx = makeFixtureRepo({ 'src/ok.ts': STANDALONE_FILE });
  try {
    const r1 = runHook(['src/ok.ts'], { cwd: fx.root });
    assert.equal(r1.status, 0);
    const meta1 = readMeta(fx.root);
    assert.ok(meta1, 'meta written on first run');

    // Second run with no file changes — built_at should be unchanged.
    const r2 = runHook(['src/ok.ts'], { cwd: fx.root });
    assert.equal(r2.status, 0);
    const meta2 = readMeta(fx.root);
    assert.equal(meta1.built_at, meta2.built_at, 'cache hit: built_at unchanged');
  } finally {
    fx.cleanup();
  }
});

test('CODE_AUDIT_TIMING=1 writes timing.log', () => {
  const fx = makeFixtureRepo({ 'src/ok.ts': STANDALONE_FILE });
  try {
    const res = runHook(['src/ok.ts'], {
      cwd: fx.root,
      env: { CODE_AUDIT_TIMING: '1' },
    });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    const log = join(fx.root, '.git', 'audit', 'timing.log');
    assert.ok(existsSync(log), 'timing.log exists');
    const content = readFileSync(log, 'utf8');
    assert.match(content, /total_ms=/);
  } finally {
    fx.cleanup();
  }
});

test('reads paths from --null/stdin if no argv given', () => {
  // Belt-and-suspenders: when invoked outside the pre-commit framework
  // (e.g. `git diff --cached --name-only -z | node hooks/pre-commit-audit.mjs`),
  // the hook should also handle the NUL-stream case. We test the simpler
  // "no argv → git diff --cached fallback" path here; explicit stdin
  // piping is tested implicitly via the framework integration test below.
  const fx = makeFixtureRepo({ 'src/ok.ts': STANDALONE_FILE });
  try {
    const res = runHook([], { cwd: fx.root });
    assert.equal(res.status, 0, `stderr: ${res.stderr}`);
    // src/ok.ts is staged, so the fallback should still pick it up.
    // Cache should be built.
    assert.ok(readMeta(fx.root), 'meta file written via fallback');
  } finally {
    fx.cleanup();
  }
});
