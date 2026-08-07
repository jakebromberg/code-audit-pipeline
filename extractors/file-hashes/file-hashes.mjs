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
    'scan-header':  { type: 'boolean', default: false },
    'scan-marks':   { type: 'boolean', default: false },
    help:           { type: 'boolean', default: false },
  },
});

if (values.help || !values.root) {
  process.stderr.write(`usage: file-hashes.mjs --root <path> [--shared <path>] [--output <path>] [--extensions ts,tsx,...] [--include-tests] [--scan-header] [--scan-marks]

  --root          Required. Root of the codebase to scan.
  --shared        Optional. A secondary package root. Tagged as package="shared".
  --output        Optional. Write JSON to this path. Default: stdout.
  --extensions    Optional. Comma-separated list of extensions to hash (no dots).
                  Default: ts,tsx,mts,cts. Pass e.g. "ts,tsx,js,jsx,py" to broaden.
  --include-tests Optional. Don't skip tests/ and *.test.*/*.spec.* files.
  --scan-header   Optional. Read the first ~30 lines of each file and surface the
                  first "copied from"-style phrase that matches. Adds a
                  header_match: { line, phrase, text } | null field to every row.
                  Drives pipeline/queries/copied-from-header.jq.
  --scan-marks    Optional. Scan each file for "// MARK:" section markers (Swift
                  convention). Adds mark_count, line_count, and mark_labels[]
                  fields to every row. Drives pipeline/queries/mark-section-density.jq.
`);
  process.exit(values.help ? 0 : 1);
}

const ROOT = resolve(values.root);
const SHARED = values.shared ? resolve(values.shared) : null;
const INCLUDE_TESTS = values['include-tests'];
const SCAN_HEADER = values['scan-header'];
const SCAN_MARKS = values['scan-marks'];
const EXTS = new Set(values.extensions.split(',').map((s) => s.trim()).filter(Boolean));

// Header phrases captured by --scan-header. Substring match, case-insensitive.
// Order is precedence-within-a-line: an earlier phrase in this list takes priority
// when multiple phrases match the same line. Lowercase by construction so the
// per-line comparison can lowercase the line once and substring-test directly.
const HEADER_PHRASES = [
  'copied from',
  'fork of',
  'based on',
  'duplicate of',
  'ported from',
];

// Number of leading source lines scanned for header-match phrases. ~30 covers
// typical license / copyright blocks plus a short header comment under them
// without spilling into actual code in any reasonable file.
const HEADER_SCAN_LINES = 30;

// MARK detection regex. Swift convention is `// MARK: <title>` with an optional
// visual separator made of one or more dashes (`// MARK: - Foo`, `// MARK: --- Foo ---`).
// We accept any leading run of dashes and strip them along with surrounding
// whitespace from the captured label so consumers see a clean section name.
//
// Anchored at start-of-line with optional indent. Known limitation: Swift
// triple-quoted multi-line strings can contain `// MARK:`-shaped lines as
// plain text; the regex is line-anchored, not scope-aware, and will count
// those as MARKs. False-positive risk negligible in practice (typical Swift
// codebases do not embed MARK-shaped text inside docstrings) but flagged so
// downstream consumers can choose to skeptic-pass clusters originating from
// files with heavy string-literal content.
const MARK_RE = /^[ \t]*\/\/\s*MARK:\s*-*\s*(.*?)\s*$/;

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

// Mirrors extractors/swift/Sources/swift-catalog/Walker.swift's
// resolvePackage (215cefdf promised the two stay identical). The Tests/<X>
// arm is symmetric with the Sources arm — X is the raw target directory
// name, not normalized to the production package it doubles. It's currently
// unreachable in practice because SKIP_DIRS still prunes `Tests` by default
// (see the `file-hashes` / type-catalog divergence tracked separately as
// out of scope for jakebromberg/code-audit-pipeline#317), but the function
// itself must not silently diverge from the Swift extractor's.
function resolveSwiftPackage(relPath) {
  const parts = relPath.split('/');
  if (parts.length >= 2 && parts[0] === 'Shared') return parts[1];
  if (parts.length >= 2 && parts[0] === 'WXYC') return `app:${parts[1]}`;
  if (parts.length >= 2 && parts[0] === 'Sources') return parts[1];
  if (parts.length >= 2 && parts[0] === 'Tests') return parts[1];
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
  // Decode as utf-8, strip a leading UTF-8 BOM, normalize line endings
  // (CRLF and bare CR both map to LF), drop trailing whitespace per line,
  // drop trailing blank lines. Encode back to utf-8 for hashing.
  const text = buf.toString('utf8').replace(/^﻿/, '');
  const lines = text.replace(/\r\n?/g, '\n').split('\n').map((l) => l.replace(/[ \t]+$/, ''));
  while (lines.length > 0 && lines[lines.length - 1] === '') lines.pop();
  return Buffer.from(lines.join('\n'), 'utf8');
}

// scanHeader looks at the first HEADER_SCAN_LINES lines for any HEADER_PHRASES
// match. Returns `{ line: 1-indexed, phrase, text }` on hit, `null` on no hit.
// Earliest line wins; within a line, earliest entry in HEADER_PHRASES wins.
//
// Text is the raw source line stripped of trailing \r and trailing whitespace —
// single-line by construction (we split on \n after CRLF→LF normalization).
function scanHeader(buf) {
  const text = buf.toString('utf8').replace(/\r\n/g, '\n');
  const lines = text.split('\n');
  const limit = Math.min(lines.length, HEADER_SCAN_LINES);
  for (let i = 0; i < limit; i++) {
    const raw = lines[i].replace(/[ \t\r]+$/, '');
    const lower = raw.toLowerCase();
    for (const phrase of HEADER_PHRASES) {
      if (lower.includes(phrase)) {
        return { line: i + 1, phrase, text: raw };
      }
    }
  }
  return null;
}

// scanMarks walks every line of the file, counts // MARK: sections, and
// returns { mark_count, line_count, mark_labels: [{line, label}] }. Labels
// are captured per the MARK_RE regex; empty-label MARK lines (`// MARK:`) emit
// `label: ""` so the consumer sees the line without inventing a name.
//
// line_count is the count of source lines after dropping a trailing empty
// entry from `split('\n')`. This matches `wc -l` for files terminated by a
// newline; for files without a trailing newline the implementation counts
// the final partial line (so `"abc"` reports 1) while `wc -l` reports 0.
// Documented divergence; mark-section-density.jq's thresholds are calibrated
// against this counter, not POSIX `wc -l`. The trailing-blank-line trimming
// used by `normalize()` is intentionally NOT applied here.
// mark_labels[].line uses 1-indexed line numbers.
//
// Line-ending handling: CRLF and bare CR are both normalized to LF before
// splitting, so files with legacy CR-only endings (classic Mac, clipboard
// pastes from some sources) are correctly counted as multi-line.
// A leading UTF-8 BOM is stripped so the first line's `// MARK:` is matched.
function scanMarks(buf) {
  const text = buf.toString('utf8').replace(/^﻿/, '').replace(/\r\n?/g, '\n');
  const lines = text.split('\n');
  // A trailing `\n` produces a final empty entry from split; drop it so the
  // line_count is the count of content-bearing lines. If the file doesn't
  // end with `\n` the last entry holds real content and stays (counted).
  // Files with zero bytes split into a single empty string; drop that too.
  if (lines.length > 0 && lines[lines.length - 1] === '') {
    lines.pop();
  }
  const marks = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(MARK_RE);
    if (m) {
      marks.push({ line: i + 1, label: m[1] });
    }
  }
  return {
    mark_count: marks.length,
    line_count: lines.length,
    mark_labels: marks,
  };
}

function hashFile(filePath, pkgName, pkgRoot) {
  const buf = readFileSync(filePath);
  const norm = normalize(buf);
  const relPath = relative(pkgRoot, filePath);
  const isGenerated = /(^|\/)generated\//.test(relPath) || relPath.endsWith('.d.ts') || relPath.endsWith('.generated.swift');
  const pkg = SWIFT_MODE ? resolveSwiftPackage(relPath) : pkgName;
  const record = {
    package: pkg,
    file: relPath,
    generated: isGenerated,
    size_bytes: buf.length,
    size_normalized: norm.length,
    sha256: sha256(buf),
    sha256_normalized: sha256(norm),
  };
  // When --scan-header is set, every record carries header_match (null on miss).
  // When unset, the field is omitted entirely so legacy readers see byte-stable
  // output.
  if (SCAN_HEADER) {
    record.header_match = scanHeader(buf);
  }
  // When --scan-marks is set, every record carries mark_count, line_count,
  // and mark_labels[]. When unset, the fields are omitted entirely so legacy
  // readers see byte-stable output.
  if (SCAN_MARKS) {
    Object.assign(record, scanMarks(buf));
  }
  return record;
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
