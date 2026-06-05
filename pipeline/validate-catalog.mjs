#!/usr/bin/env node
// validate-catalog.mjs
//
// Validates a catalog JSON file against the contract documented in
// docs/pipeline-contract.md. Intentionally small — no JSON Schema dep,
// no third-party packages — so it runs anywhere Node 20+ is available.
//
// Usage:
//   pipeline/validate-catalog.mjs <catalog.json> [...more catalogs]
//
// Exit 0 on every file valid; exit 1 on the first invalid file with a
// stderr diagnostic naming the offending entry.
//
// Accepts:
//   - bare-array catalogs (pre-1.1; emits a stderr warning, validates entries)
//   - 1.1 wrapper objects (schema_version, extractor, entries)
//   - 1.2 wrapper objects (adds fingerprint_v, generated_at, extractor.source_sha,
//     and per-entry symbol_id; all optional from a consumer's perspective)
//
// Rules enforced:
//   - top level is array OR object with .entries
//   - if wrapped: schema_version matches /^\d+\.\d+$/ and major is in {1}
//     (refuse 0.x and unknown 2.x+ until ratified — keeps the validator
//     honest about what it actually checks)
//   - .entries is an array
//   - per entry: name (string), kind (string), package (string),
//     file (string), line (number ≥ 1) are required
//   - if entry.symbol_id is present, it equals
//     sha1(package + "/" + file + "/" + name + "/" + kind), lowercase hex.
//     This check applies to ALL entries regardless of envelope form —
//     a bare-array entry that carries symbol_id is still subject to it.

import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { argv, exit, stderr } from 'node:process';

const SCHEMA_VERSION_RE = /^(\d+)\.(\d+)$/;
const ALLOWED_MAJORS = new Set([1]);
const SHA1_HEX_RE = /^[0-9a-f]{40}$/;

function fail(file, msg, ctx = '') {
  stderr.write(`validate-catalog: ${file}: ${msg}${ctx ? '\n  ' + ctx : ''}\n`);
  exit(1);
}

function warn(file, msg) {
  stderr.write(`validate-catalog: ${file}: warning: ${msg}\n`);
}

// NUL-byte joined; see extractors/typescript/type-catalog.mjs::computeSymbolId
// for the rationale.
function computeSymbolId(pkg, file, name, kind) {
  return createHash('sha1').update(`${pkg}\x00${file}\x00${name}\x00${kind}`).digest('hex');
}

function isString(v) { return typeof v === 'string'; }
function isFiniteNumber(v) { return typeof v === 'number' && Number.isFinite(v); }

function validateEntry(file, entry, idx) {
  const here = `entry[${idx}] ${entry.kind ?? '<no-kind>'}/${entry.name ?? '<no-name>'}`;
  for (const field of ['name', 'kind', 'package', 'file']) {
    if (!isString(entry[field])) fail(file, `${here}: required field "${field}" missing or not a string`);
  }
  if (!isFiniteNumber(entry.line) || entry.line < 1) {
    fail(file, `${here}: required field "line" must be a number >= 1, got ${JSON.stringify(entry.line)}`);
  }
  if (entry.symbol_id !== undefined) {
    if (!isString(entry.symbol_id) || !SHA1_HEX_RE.test(entry.symbol_id)) {
      fail(file, `${here}: symbol_id is not a 40-char lowercase hex sha1`, `got ${JSON.stringify(entry.symbol_id)}`);
    }
    const derived = computeSymbolId(entry.package, entry.file, entry.name, entry.kind);
    if (derived !== entry.symbol_id) {
      fail(file, `${here}: symbol_id mismatch`,
        `declared=${entry.symbol_id}\n  derived=${derived}\n  formula=sha1("${entry.package}/${entry.file}/${entry.name}/${entry.kind}")`);
    }
  }
}

function validateEnvelope(file, root) {
  // schema_version is required on the wrapper form
  if (!isString(root.schema_version)) {
    fail(file, 'wrapper missing schema_version (or not a string)');
  }
  const m = SCHEMA_VERSION_RE.exec(root.schema_version);
  if (!m) {
    fail(file, `schema_version "${root.schema_version}" must match MAJOR.MINOR (e.g., "1.2")`);
  }
  const major = Number(m[1]);
  const minor = Number(m[2]);
  if (!ALLOWED_MAJORS.has(major)) {
    fail(file, `schema_version major ${major} not recognized by this validator (allowed: ${[...ALLOWED_MAJORS].join(', ')})`);
  }
  // v1.0 was bare-array only — a wrapper labeled "1.0" is malformed. The
  // wrapper form was introduced in v1.1. Reject the impossible combination.
  if (major === 1 && minor < 1) {
    fail(file, `schema_version "${root.schema_version}" cannot label a wrapper envelope; v1.0 was bare-array-only. Use "1.1" or later for wrapped catalogs.`);
  }
  if (!Array.isArray(root.entries)) {
    fail(file, '.entries is missing or not an array');
  }
  // extractor block is REQUIRED on the wrapper form (v1.1+); its name,
  // language, version, and source_sha are all required strings. The diff
  // machinery (#117) consumes source_sha to compare extractor identity
  // across catalogs; an empty or malformed block silently breaks that.
  if (root.extractor === undefined) {
    fail(file, 'extractor block is required on wrapper-form catalogs (v1.1+)');
  }
  const e = root.extractor;
  if (typeof e !== 'object' || e === null || Array.isArray(e)) {
    fail(file, 'extractor must be an object');
  }
  for (const field of ['name', 'language', 'version']) {
    if (!isString(e[field]) || e[field].length === 0) {
      fail(file, `extractor.${field} is required and must be a non-empty string`);
    }
  }
  // source_sha must be a 40-char lowercase hex string OR the literal
  // "unknown" — these are the exact two shapes the contract specifies, and
  // the diff machinery branches on the second form. Any other string is a
  // contract violation.
  if (e.source_sha !== undefined) {
    if (!isString(e.source_sha)) {
      fail(file, 'extractor.source_sha must be a string when present');
    }
    if (e.source_sha !== 'unknown' && !/^[0-9a-f]{40}$/.test(e.source_sha)) {
      fail(file, `extractor.source_sha "${e.source_sha}" must be a 40-char lowercase hex git SHA or the literal "unknown"`);
    }
  }
  if (root.fingerprint_v !== undefined && !isString(root.fingerprint_v)) {
    fail(file, 'fingerprint_v must be a string when present');
  }
  if (root.generated_at !== undefined && !isString(root.generated_at)) {
    fail(file, 'generated_at must be a string when present');
  }
}

function validateFile(file) {
  let text;
  try {
    text = readFileSync(file, 'utf8');
  } catch (e) {
    fail(file, `cannot read: ${e.message}`);
  }
  let root;
  try {
    root = JSON.parse(text);
  } catch (e) {
    fail(file, `JSON parse error: ${e.message}`);
  }

  let entries;
  if (Array.isArray(root)) {
    warn(file, 'pre-1.1 bare-array catalog; consumers should upgrade to wrapper');
    entries = root;
  } else if (typeof root === 'object' && root !== null && 'entries' in root) {
    validateEnvelope(file, root);
    entries = root.entries;
  } else {
    fail(file, 'top level must be a JSON array (pre-1.1) or an object with .entries');
  }

  for (let i = 0; i < entries.length; i++) {
    const e = entries[i];
    if (typeof e !== 'object' || e === null || Array.isArray(e)) {
      fail(file, `entry[${i}] is not an object`);
    }
    validateEntry(file, e, i);
  }
}

function main() {
  const args = argv.slice(2);
  if (args.length === 0) {
    stderr.write('usage: validate-catalog.mjs <catalog.json> [...more catalogs]\n');
    exit(2);
  }
  for (const file of args) {
    validateFile(file);
  }
  // All files passed.
}

main();
