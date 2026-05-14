#!/usr/bin/env node
// file-hashes.mjs
//
// Walks every source file under --root (and optionally --shared) and emits one record
// per file with two content hashes:
//   - sha256:            raw bytes hashed verbatim
//   - sha256_normalized: hashed after CRLF→LF, trailing-whitespace stripped, trailing blank
//                        lines dropped — catches "same file, different line endings or
//                        editor-added trailing whitespace" pairs.
//
// Two hashes lets `file-duplicates.jq` distinguish byte-equal duplicates from
// whitespace-only divergences without the agent having to read both files.
//
// See ../../docs/pipeline-contract.md for the emitted schema.

import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    root:           { type: 'string' },
    shared:         { type: 'string' },
    output:         { type: 'string' },
    extensions:     { type: 'string', default: 'ts,tsx,mts,cts' },
    'include-tests':{ type: 'boolean', default: false },
    help:           { type: 'boolean', default: false },
  },
});

if (values.help || !values.root) {
  process.stderr.write(`usage: file-hashes.mjs --root <path> [--shared <path>] [--output <path>] [--extensions ts,tsx,...] [--include-tests]

  --root          Required. Root of the codebase to scan.
  --shared        Optional. A secondary package root. Tagged as package="shared".
  --output        Optional. Write JSON to this path. Default: stdout.
  --extensions    Optional. Comma-separated list of extensions to hash (no dots).
                  Default: ts,tsx,mts,cts. Pass e.g. "ts,tsx,js,jsx,py" to broaden.
  --include-tests Optional. Don't skip tests/ and *.test.*/*.spec.* files.
`);
  process.exit(values.help ? 0 : 1);
}

const ROOT = resolve(values.root);
const SHARED = values.shared ? resolve(values.shared) : null;
const INCLUDE_TESTS = values['include-tests'];
const EXTS = new Set(values.extensions.split(',').map((s) => s.trim()).filter(Boolean));

// Swift mode: enabled when 'swift' is among --extensions. Mirrors the swift-catalog
// extractor's skip-list and package resolution so cross-catalog queries see the same
// `package` field for the same file.
const SWIFT_MODE = EXTS.has('swift');

const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', 'coverage']);
if (!INCLUDE_TESTS) SKIP_DIRS.add('tests');
if (SWIFT_MODE) {
  SKIP_DIRS.add('scripts');
  SKIP_DIRS.add('ci_scripts');
  SKIP_DIRS.add('.build');
  SKIP_DIRS.add('.swiftpm');
  SKIP_DIRS.add('DerivedData');
  SKIP_DIRS.add('Pods');
  if (!INCLUDE_TESTS) SKIP_DIRS.add('Tests');
}

function resolveSwiftPackage(relPath) {
  const parts = relPath.split('/');
  if (parts.length >= 2 && parts[0] === 'Shared') return parts[1];
  if (parts.length >= 2 && parts[0] === 'WXYC') return `app:${parts[1]}`;
  if (parts.length >= 2 && parts[0] === 'Sources') return parts[1];
  return parts[0] || 'root';
}

function walkDir(root) {
  const out = [];
  function walk(dir) {
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); }
    catch { return; }
    for (const e of entries) {
      const full = join(dir, e.name);
      if (e.isDirectory()) {
        if (e.name.startsWith('.')) continue;
        if (SKIP_DIRS.has(e.name)) continue;
        walk(full);
      } else if (e.isFile()) {
        const m = e.name.match(/\.([^.]+)$/);
        const ext = m ? m[1] : '';
        if (!EXTS.has(ext)) continue;
        if (!INCLUDE_TESTS && /\.(test|spec)\.(tsx|ts|mts|cts|js|jsx|mjs|cjs)$/.test(e.name)) continue;
        if (!INCLUDE_TESTS && SWIFT_MODE && /Tests\.swift$/.test(e.name)) continue;
        out.push(full);
      }
    }
  }
  walk(root);
  return out;
}

function sha256(buf) {
  return createHash('sha256').update(buf).digest('hex');
}

function normalize(buf) {
  // Decode as utf-8, normalize line endings, drop trailing whitespace per line, drop trailing
  // blank lines. Encode back to utf-8 for hashing.
  const text = buf.toString('utf8');
  const lines = text.replace(/\r\n/g, '\n').split('\n').map((l) => l.replace(/[ \t]+$/, ''));
  while (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
  return Buffer.from(lines.join('\n'), 'utf8');
}

// V7 §6.6 context-flag heuristics — mirrors `Walker.swift`'s detection so a
// cross-extractor join on `package` + `file` sees the same flag values for the
// same physical file. Each helper takes the relative path (POSIX-separated)
// and returns a boolean. Path-only signals; `is_mock`'s name-suffix half lives
// in TypeRecord / FunctionRecord on the catalog side — file-hashes records
// have no record name to suffix-check, so this is purely directory-shape.

function isTestPath(relPath) {
  const segments = relPath.split('/');
  for (const segment of segments) {
    if (segment === 'Tests') return true;
    if (segment === '__tests__') return true;
    if (segment.endsWith('Testing') && segment !== 'Testing') return true;   // Swift `*Testing/` lib-target convention
  }
  const fname = segments[segments.length - 1] || '';
  if (fname.endsWith('Tests.swift')) return true;
  if (fname.includes('.test.') || fname.includes('.spec.')) return true;
  return false;
}

function isCodegenPath(relPath, isGenerated) {
  if (isGenerated) return true;   // superset of the legacy `generated` flag
  const segments = relPath.split('/');
  for (const segment of segments) {
    if (segment === 'Generated') return true;
  }
  const fname = segments[segments.length - 1] || '';
  if (fname.endsWith('+Generated.swift')) return true;
  return false;
}

function isSampleAppPath(relPath) {
  for (const segment of relPath.split('/')) {
    const lower = segment.toLowerCase();
    if (lower === 'examples' || lower === 'example') return true;
    if (lower === 'sampleapp' || lower === 'sample-app' || lower === 'sample') return true;
    if (lower === 'demo' || lower === 'demos') return true;
  }
  return false;
}

function isMockPath(relPath) {
  for (const segment of relPath.split('/')) {
    if (segment === 'Mocks' || segment === 'Stubs' || segment === 'Fakes') return true;
  }
  return false;
}

function hashFile(filePath, pkgName, pkgRoot) {
  const buf = readFileSync(filePath);
  const norm = normalize(buf);
  const relPath = relative(pkgRoot, filePath);
  const isGenerated = /(^|\/)generated\//.test(relPath) || relPath.endsWith('.d.ts') || relPath.endsWith('.generated.swift');
  const pkg = SWIFT_MODE ? resolveSwiftPackage(relPath) : pkgName;
  return {
    package: pkg,
    file: relPath,
    generated: isGenerated,
    // V7 §6.6 context flags. file-hashes records have no record name to
    // suffix-check, so `is_mock` here is purely path-derived. The catalog
    // extractors carry the name-suffix half independently.
    is_test: isTestPath(relPath),
    is_codegen: isCodegenPath(relPath, isGenerated),
    is_sample_app: isSampleAppPath(relPath),
    is_mock: isMockPath(relPath),
    size_bytes: buf.length,
    size_normalized: norm.length,
    sha256: sha256(buf),
    sha256_normalized: sha256(norm),
  };
}

// --- Run ---

const mainFiles = walkDir(ROOT);
const sharedFiles = SHARED ? walkDir(SHARED) : [];

process.stderr.write(`main: ${mainFiles.length} files\n`);
if (SHARED) process.stderr.write(`shared: ${sharedFiles.length} files\n`);

const all = [];
let errors = 0;
for (const f of mainFiles) {
  try { all.push(hashFile(f, 'main', ROOT)); }
  catch (e) { errors++; process.stderr.write(`  ERR ${f}: ${e.message}\n`); }
}
for (const f of sharedFiles) {
  try { all.push(hashFile(f, 'shared', SHARED)); }
  catch (e) { errors++; process.stderr.write(`  ERR ${f}: ${e.message}\n`); }
}

process.stderr.write(`\nTotal files: ${all.length} (errors: ${errors})\n`);

const json = JSON.stringify(all, null, 2);
if (values.output) {
  writeFileSync(values.output, json);
  process.stderr.write(`Wrote ${values.output}\n`);
} else {
  process.stdout.write(json);
}

process.exit(mainFiles.length > 0 ? 0 : 1);
