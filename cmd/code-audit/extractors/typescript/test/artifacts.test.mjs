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

test('writeSiblingArtifact propagates v1.2 fingerprint_v and generated_at when provided', () => {
  withTmpDir((dir) => {
    const path = join(dir, 'out.json');
    writeSiblingArtifact({
      path,
      schema_version: '1.2',
      extractorMeta: { language: 'typescript', name: 'type-catalog', version: '0.5.0', source_sha: 'abcdef0123456789abcdef0123456789abcdef01' },
      fingerprint_v: 'shape_sig:1',
      generated_at: '2026-06-04T19:00:00Z',
      payloadKey: 'edges',
      payload: [],
      summary: 'noop',
      log: () => {},
    });
    const got = JSON.parse(readFileSync(path, 'utf8'));
    assert.equal(got.schema_version, '1.2');
    assert.equal(got.fingerprint_v, 'shape_sig:1');
    assert.equal(got.generated_at, '2026-06-04T19:00:00Z');
    assert.equal(got.extractor.source_sha, 'abcdef0123456789abcdef0123456789abcdef01');
    // Key order: schema_version, extractor, fingerprint_v, generated_at, edges.
    assert.deepEqual(Object.keys(got), ['schema_version', 'extractor', 'fingerprint_v', 'generated_at', 'edges']);
  });
});

test('writeSiblingArtifact omits fingerprint_v / generated_at when caller does not pass them (back-compat)', () => {
  withTmpDir((dir) => {
    const path = join(dir, 'out.json');
    writeSiblingArtifact({
      path,
      schema_version: '1.1',
      extractorMeta: { language: 'typescript', name: 'type-catalog', version: '0.5.0' },
      payloadKey: 'entries',
      payload: [],
      summary: 'noop',
      log: () => {},
    });
    const got = JSON.parse(readFileSync(path, 'utf8'));
    assert.equal('fingerprint_v' in got, false);
    assert.equal('generated_at' in got, false);
  });
});
