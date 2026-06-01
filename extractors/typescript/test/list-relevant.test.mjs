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
