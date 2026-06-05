// artifacts.mjs
//
// Helper for writing schema_version-wrapped sibling artifacts
// (references.json, files.json, ...). Centralizes the wrapper shape so the
// {schema_version, extractor, fingerprint_v, generated_at, <payloadKey>}
// envelope is identical across every sibling output an extractor emits.
//
// fingerprint_v and generated_at are optional for backward compat with
// callers that haven't been updated yet; new callers should pass them so
// downstream tooling sees consistent envelope metadata across the catalog
// and its siblings.

import { writeFileSync } from 'node:fs';

export function writeSiblingArtifact({
  path,
  schema_version,
  extractorMeta,
  fingerprint_v,
  generated_at,
  payloadKey,
  payload,
  summary,
  log = (msg) => process.stderr.write(msg),
}) {
  const wrapped = {
    schema_version,
    extractor: extractorMeta,
    ...(fingerprint_v !== undefined ? { fingerprint_v } : {}),
    ...(generated_at !== undefined ? { generated_at } : {}),
    [payloadKey]: payload,
  };
  writeFileSync(path, JSON.stringify(wrapped, null, 2));
  log(summary + '\n');
}
