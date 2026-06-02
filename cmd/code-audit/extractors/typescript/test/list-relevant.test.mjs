// Tests for the `--list-relevant` CLI mode on type-catalog.mjs.
//
// Run with:  node --test test/list-relevant.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const EXTRACTOR = join(__dirname, '..', 'type-catalog.mjs');

function runListRelevant({ stdin = '', args = [] } = {}) {
  const res = spawnSync('node', [EXTRACTOR, '--list-relevant', ...args], {
    input: stdin,
    encoding: 'utf8',
  });
  return { status: res.status, stdout: res.stdout, stderr: res.stderr };
}

test('keeps relevant paths, drops irrelevant — newline-separated default', () => {
  const input = [
    'src/foo.ts',
    'src/bar.tsx',
    'src/baz.js',
    'node_modules/pkg/index.ts',
    'dist/foo.ts',
    '.next/x.ts',
    'README.md',
    'src/foo.test.ts',
  ].join('\n') + '\n';

  const res = runListRelevant({ stdin: input });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);

  const kept = res.stdout.split('\n').filter(Boolean);
  assert.deepEqual(kept, ['src/foo.ts', 'src/bar.tsx']);
});

test('--include-tests keeps test paths', () => {
  const input = 'src/foo.ts\nsrc/foo.test.ts\ntests/x.ts\n';
  const res = runListRelevant({ stdin: input, args: ['--include-tests'] });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  const kept = res.stdout.split('\n').filter(Boolean);
  assert.deepEqual(kept, ['src/foo.ts', 'src/foo.test.ts', 'tests/x.ts']);
});

test('--null uses NUL separator on input and output', () => {
  const input = ['src/foo.ts', 'src/bar.js', 'src/baz.tsx'].join('\0') + '\0';
  const res = runListRelevant({ stdin: input, args: ['--null'] });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  const kept = res.stdout.split('\0').filter(Boolean);
  assert.deepEqual(kept, ['src/foo.ts', 'src/baz.tsx']);
});

test('-0 is an alias for --null', () => {
  const input = ['src/foo.ts', 'src/bar.js'].join('\0') + '\0';
  const res = runListRelevant({ stdin: input, args: ['-0'] });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  const kept = res.stdout.split('\0').filter(Boolean);
  assert.deepEqual(kept, ['src/foo.ts']);
});

test('empty stdin → empty stdout, exit 0', () => {
  const res = runListRelevant({ stdin: '' });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  assert.equal(res.stdout, '');
});

test('all-excluded input → empty stdout, exit 0', () => {
  const input = 'README.md\nnode_modules/x/y.ts\n.next/z.ts\n';
  const res = runListRelevant({ stdin: input });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  assert.equal(res.stdout, '');
});

test('--list-relevant works without --root (no help/error gate trip)', () => {
  // The regular extraction mode requires --root; the predicate query does not.
  const res = runListRelevant({ stdin: 'src/foo.ts\n' });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  assert.equal(res.stdout, 'src/foo.ts\n');
});

test('preserves input order in output', () => {
  const input = 'src/z.ts\nsrc/a.ts\nsrc/m.ts\n';
  const res = runListRelevant({ stdin: input });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  const kept = res.stdout.split('\n').filter(Boolean);
  assert.deepEqual(kept, ['src/z.ts', 'src/a.ts', 'src/m.ts']);
});

test('tolerates missing trailing separator', () => {
  // No trailing newline (e.g., output of `printf %s …`).
  const res = runListRelevant({ stdin: 'src/foo.ts' });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  assert.equal(res.stdout, 'src/foo.ts\n');
});

// ---- PR 244 review: input normalization end-to-end ----

test('CRLF input (Windows / git autocrlf) yields the expected subset, not empty', () => {
  const input = 'src/foo.ts\r\nsrc/bar.js\r\nsrc/baz.tsx\r\n';
  const res = runListRelevant({ stdin: input });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  assert.equal(res.stdout, 'src/foo.ts\nsrc/baz.tsx\n');
});

test('./ prefix from `find -print0` composes correctly', () => {
  const input = './src/foo.ts\0./node_modules/x/y.ts\0./src/bar.tsx\0';
  const res = runListRelevant({ stdin: input, args: ['--null'] });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  assert.equal(res.stdout, 'src/foo.ts\0src/bar.tsx\0');
});

test('Windows-style backslash paths are normalized and skip-dirs still apply', () => {
  const input = 'src\\foo.ts\nnode_modules\\pkg\\index.ts\nsrc\\sub\\bar.tsx\n';
  const res = runListRelevant({ stdin: input });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  assert.equal(res.stdout, 'src/foo.ts\nsrc/sub/bar.tsx\n');
});

test('whitespace-padded inputs are trimmed before emission', () => {
  const input = '   src/foo.ts   \n  src/bar.tsx  \n';
  const res = runListRelevant({ stdin: input });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  assert.equal(res.stdout, 'src/foo.ts\nsrc/bar.tsx\n');
});

// ---- Mode / flag validation ----

test('--list-relevant --help prints the help banner and exits 0', () => {
  const res = runListRelevant({ stdin: '', args: ['--help'] });
  assert.equal(res.status, 0, `stderr: ${res.stderr}`);
  assert.match(res.stderr, /usage: type-catalog\.mjs/);
  assert.match(res.stderr, /--list-relevant/);
});

test('--list-relevant rejects extraction flags (--root)', () => {
  const res = runListRelevant({ stdin: '', args: ['--root', '/tmp'] });
  assert.equal(res.status, 2);
  assert.match(res.stderr, /--list-relevant is a pure-query mode/);
  assert.match(res.stderr, /--root/);
});

test('--null without --list-relevant errors out', () => {
  // Run extractor WITHOUT --list-relevant.
  const res = spawnSync('node', [EXTRACTOR, '--null'], { encoding: 'utf8' });
  assert.equal(res.status, 2);
  assert.match(res.stderr, /--null.*only apply in --list-relevant mode/);
});

test('--include-tests without --list-relevant errors out', () => {
  const res = spawnSync('node', [EXTRACTOR, '--include-tests'], { encoding: 'utf8' });
  assert.equal(res.status, 2);
  assert.match(res.stderr, /--include-tests.*only apply in --list-relevant mode/);
});

test('extraction mode without --root still prints usage (exit 1)', () => {
  // Regression: the new query-vs-extraction branching must not break the
  // existing "--root is required" gate.
  const res = spawnSync('node', [EXTRACTOR], { encoding: 'utf8' });
  assert.equal(res.status, 1);
  assert.match(res.stderr, /usage: type-catalog\.mjs/);
});
