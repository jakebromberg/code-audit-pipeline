// Tests for _lib/artifacts.mjs (writeSiblingArtifact wrapper writer).
//
// Run with:  node --test test/artifacts.test.mjs

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { writeSiblingArtifact } from '../_lib/artifacts.mjs';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

function withTmpDir(fn) {
  const dir = mkdtempSync(join(tmpdir(), 'artifacts-test-'));
  try { fn(dir); } finally { rmSync(dir, { recursive: true, force: true }); }
}

test('writeSiblingArtifact emits {schema_version, extractor, <payloadKey>} JSON', () => {
  withTmpDir((dir) => {
    const path = join(dir, 'out.json');
    const summaries = [];
    writeSiblingArtifact({
      path,
      schema_version: '1.1',
      extractorMeta: { language: 'typescript', name: 'type-catalog', version: '0.5.0' },
      payloadKey: 'entries',
      payload: [{ a: 1 }, { a: 2 }],
      summary: 'Wrote 2 rows',
      log: (msg) => summaries.push(msg),
    });
    const got = JSON.parse(readFileSync(path, 'utf8'));
    assert.deepEqual(got, {
      schema_version: '1.1',
      extractor: { language: 'typescript', name: 'type-catalog', version: '0.5.0' },
      entries: [{ a: 1 }, { a: 2 }],
    });
    assert.deepEqual(summaries, ['Wrote 2 rows\n']);
  });
});

test('writeSiblingArtifact pretty-prints with 2-space indent', () => {
  withTmpDir((dir) => {
    const path = join(dir, 'out.json');
    writeSiblingArtifact({
      path,
      schema_version: '1.0',
      extractorMeta: { language: 'python', name: 'type-catalog', version: '0.1.0' },
      payloadKey: 'edges',
      payload: [],
      summary: 'empty',
      log: () => {},
    });
    const raw = readFileSync(path, 'utf8');
    assert.match(raw, /^{\n  "schema_version": "1\.0",/);
  });
});

test('writeSiblingArtifact preserves payloadKey ordering after extractor block', () => {
  withTmpDir((dir) => {
    const path = join(dir, 'out.json');
    writeSiblingArtifact({
      path,
      schema_version: '1.1',
      extractorMeta: { language: 'typescript', name: 'type-catalog', version: '0.5.0' },
      payloadKey: 'edges',
      payload: [],
      summary: 'noop',
      log: () => {},
    });
    const keys = Object.keys(JSON.parse(readFileSync(path, 'utf8')));
    assert.deepEqual(keys, ['schema_version', 'extractor', 'edges']);
  });
});

test('writeSiblingArtifact defaults log to process.stderr.write when omitted', () => {
  withTmpDir((dir) => {
    const path = join(dir, 'out.json');
    writeSiblingArtifact({
      path,
      schema_version: '1.1',
      extractorMeta: { language: 'typescript', name: 'type-catalog', version: '0.5.0' },
      payloadKey: 'entries',
      payload: [],
      summary: 'silent ok',
    });
    assert.ok(readFileSync(path, 'utf8').length > 0);
  });
});
