// artifacts.mjs
//
// Helper for writing schema_version-wrapped sibling artifacts
// (references.json, files.json, ...). Centralizes the wrapper shape so the
// {schema_version, extractor, <payloadKey>} envelope is identical across
// every sibling output an extractor emits.

import { writeFileSync } from 'node:fs';

export function writeSiblingArtifact({
  path,
  schema_version,
  extractorMeta,
  payloadKey,
  payload,
  summary,
  log = (msg) => process.stderr.write(msg),
}) {
  const wrapped = {
    schema_version,
    extractor: extractorMeta,
    [payloadKey]: payload,
  };
  writeFileSync(path, JSON.stringify(wrapped, null, 2));
  log(summary + '\n');
}
