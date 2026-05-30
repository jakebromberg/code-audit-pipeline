#!/usr/bin/env node
// function-catalog.mjs
//
// Walks every .ts / .tsx source file under --root (and optionally --shared)
// and emits one JSON record per declared function-like construct:
// FunctionDeclaration (including overload heads), MethodDeclaration,
// ArrowFunction / FunctionExpression assigned to a named binding.
//
// Each record carries:
//   - body_hash / body_lines: duplication clustering (NULL when normalized
//     body is shorter than --min-body-lines; the row is still emitted so
//     signature-level queries see one-liners)
//   - params[].type_ref + return_ref: cross-catalog type-resolution joins
//     (#133 public-api-leaks.jq, future graph-view consumers)
//   - signature_index: per (file, name) overload-head discriminator
//   - is_test / touched_in_window / synthetic: universal flags matching
//     type-catalog
//
// See ../../docs/pipeline-contract.md > Function catalog for the v1.1 schema.

import ts from 'typescript';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, relative, resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import {
  BUILTIN_TYPE_DENYLIST,
  extractReferences,
  genericsList,
} from './_lib/references.mjs';
import { isTestPath } from './_lib/paths.mjs';

const EXTRACTOR_DIR = dirname(fileURLToPath(import.meta.url));
const EXTRACTOR_VERSION = JSON.parse(readFileSync(join(EXTRACTOR_DIR, 'package.json'), 'utf8')).version;
const SCHEMA_VERSION = '1.1';

const { values } = parseArgs({
  options: {
    root:             { type: 'string' },
    shared:           { type: 'string' },
    touched:          { type: 'string' },
    output:           { type: 'string' },
    'min-body-lines': { type: 'string', default: '3' },
    help:             { type: 'boolean', default: false },
  },
});

if (values.help || !values.root) {
  process.stderr.write(`usage: function-catalog.mjs --root <path> [--shared <path>] [--touched <json>] [--output <path>] [--min-body-lines <n>]

  --root             Required. Root of the codebase to scan.
  --shared           Optional. A secondary package root. Tagged as package="shared".
  --touched          Optional. JSON array of file paths (relative to --root) to mark touched_in_window=true.
  --output           Optional. Write JSON to this path. Default: stdout.
  --min-body-lines   Optional. Threshold below which body fields (body_hash,
                     body_lines, body_line_count, body_length) are emitted as
                     null (default 3). The row itself is still emitted —
                     signature-level queries need exported one-liner functions
                     to be visible.

Output: {"schema_version": "${SCHEMA_VERSION}", "extractor": {...}, "entries": [...]}.
Test files are always extracted; every row carries an \`is_test\` flag derived
from the file path. To exclude tests post-hoc, pipe through:
  jq '.entries | map(select(.is_test | not))'
`);
  process.exit(values.help ? 0 : 1);
}

const ROOT = resolve(values.root);
const SHARED = values.shared ? resolve(values.shared) : null;
const MIN_BODY_LINES = Number(values['min-body-lines']) || 3;
const TOUCHED = values.touched
  ? new Set(JSON.parse(readFileSync(values.touched, 'utf8')))
  : new Set();

const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', 'coverage']);

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
        if (!/\.(tsx|ts|mts|cts)$/.test(e.name)) continue;
        out.push(full);
      }
    }
  }
  walk(root);
  return out;
}

// --- Body normalization (unchanged from v1.0) ---

function normalizeBody(text) {
  let stripped = text.replace(/\/\*[\s\S]*?\*\//g, '');
  stripped = stripped.replace(/\/\/[^\n]*/g, '');
  const lines = stripped
    .split('\n')
    .map((l) => l.replace(/\s+/g, ' ').trim())
    .filter((l) => l.length > 0);
  return lines;
}

function bodyHashOf(normLines) {
  return createHash('sha256').update(normLines.join('\n')).digest('hex');
}

function bodyTextOf(node, sf) {
  return node ? node.getText(sf) : '';
}

// --- Modifiers ---

function exportedMod(node) {
  return !!node.modifiers?.some((m) => m.kind === ts.SyntaxKind.ExportKeyword);
}

function asyncMod(node) {
  return !!node.modifiers?.some((m) => m.kind === ts.SyntaxKind.AsyncKeyword);
}

// --- Signature extraction ---
//
// `type_ref` is the simple-case sugar (bare TypeReferenceNode whose typeName
// is an unbound, non-built-in Identifier with no type arguments); derived
// from `type_refs` to avoid a second AST walk.

function singleRefSugar(typeNode, refs) {
  if (refs.length !== 1) return null;
  if (!typeNode || !ts.isTypeReferenceNode(typeNode)) return null;
  if (!ts.isIdentifier(typeNode.typeName)) return null;
  if (typeNode.typeArguments) return null;
  return refs[0].name;
}

function refsOfTypeNode(typeNode, sf, scope) {
  if (!typeNode) return [];
  const sink = new Set();
  extractReferences(typeNode, sf, scope, sink);
  return [...sink].sort().map((name) => ({ name, kind: 'type-ref' }));
}

function signaturesOf(node, sf) {
  const scope = new Set();
  const allRefs = new Set();
  if (node.typeParameters) {
    for (const tp of node.typeParameters) scope.add(tp.name.text);
    for (const tp of node.typeParameters) {
      if (tp.constraint) extractReferences(tp.constraint, sf, scope, allRefs);
    }
  }
  const params = (node.parameters ?? []).map((p) => {
    const type_refs = refsOfTypeNode(p.type, sf, scope);
    for (const ref of type_refs) allRefs.add(ref.name);
    return {
      name: p.name.getText(sf),
      type_ref: singleRefSugar(p.type, type_refs),
      type_refs,
    };
  });
  let return_ref = null;
  if (node.type) {
    const returnRefs = refsOfTypeNode(node.type, sf, scope);
    for (const ref of returnRefs) allRefs.add(ref.name);
    return_ref = singleRefSugar(node.type, returnRefs);
  }
  const references = [...allRefs].sort().map((name) => ({ name, kind: 'type-ref' }));
  return { params, return_ref, references };
}

// Emit body-derived fields together — all four gate on `longEnough` and must
// move in lockstep (silent asymmetry on body_lines would land here otherwise).
function bodyFields(normLines, longEnough) {
  if (!longEnough) {
    return { body_line_count: null, body_length: null, body_hash: null, body_lines: null };
  }
  return {
    body_line_count: normLines.length,
    body_length: normLines.join('\n').length,
    body_hash: bodyHashOf(normLines),
    body_lines: [...new Set(normLines)].sort(),
  };
}

// --- Per-file extraction ---

function extractFromFile(filePath, pkgName, pkgRoot) {
  const text = readFileSync(filePath, 'utf8');
  const isTsx = filePath.endsWith('.tsx');
  const sf = ts.createSourceFile(
    filePath,
    text,
    ts.ScriptTarget.Latest,
    true,
    isTsx ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  );
  const relPath = relative(pkgRoot, filePath);
  const isGenerated = /(^|\/)generated\//.test(relPath) || relPath.endsWith('.d.ts');
  const isTest = isTestPath(relPath);
  const touched = pkgName === 'main' && TOUCHED.has(relPath);

  // Per-file Map<name, next index>. Two FunctionDeclarations sharing a name
  // in the same file -- whether overload heads at the top level or nested
  // same-name functions -- get indices 0, 1, 2, ... in source order. The
  // scope is intentionally per-(file, name) rather than per-(scope, name) so
  // overload-aware queries can dedupe with a `(name, package, file)` key.
  const sigIndex = new Map();

  const results = [];

  function pushFunction({ node, name, kind, exported, isAsync, body }) {
    const normLines = body ? normalizeBody(bodyTextOf(body, sf)) : [];
    const longEnough = normLines.length >= MIN_BODY_LINES;
    const { line } = sf.getLineAndCharacterOfPosition(node.getStart(sf));
    const sig = signaturesOf(node, sf);
    const idx = sigIndex.get(name) ?? 0;
    sigIndex.set(name, idx + 1);
    results.push({
      package: pkgName,
      file: relPath,
      line: line + 1,
      generated: isGenerated,
      is_test: isTest,
      touched_in_window: touched,
      synthetic: false,
      name,
      kind,
      exported,
      async: isAsync,
      param_count: sig.params.length,
      param_names: sig.params.map((p) => p.name),
      ...bodyFields(normLines, longEnough),
      generics: genericsList(node) ?? '',
      params: sig.params,
      return_ref: sig.return_ref,
      references: sig.references,
      references_count: sig.references.length,
      signature_index: idx,
    });
  }

  function visit(node) {
    // Top-level FunctionDeclaration. body is null for overload heads -- still emit.
    if (ts.isFunctionDeclaration(node) && node.name) {
      pushFunction({
        node,
        name: node.name.text,
        kind: 'function',
        exported: exportedMod(node),
        isAsync: asyncMod(node),
        body: node.body ?? null,
      });
    }

    // class Foo { bar(...) { ... } }
    if (ts.isMethodDeclaration(node) && node.name && node.body) {
      const className = (() => {
        let p = node.parent;
        while (p && !ts.isClassLike(p)) p = p.parent;
        return p && p.name ? p.name.text : null;
      })();
      const methodName = node.name.getText(sf);
      const qualifiedName = className ? `${className}.${methodName}` : methodName;
      pushFunction({
        node,
        name: qualifiedName,
        kind: 'method',
        exported: !!className && exportedMod(node.parent),
        isAsync: asyncMod(node),
        body: node.body,
      });
    }

    // const foo = (args) => { ... }  OR  const foo = function(args) { ... }
    if (ts.isVariableStatement(node)) {
      const exported = exportedMod(node);
      for (const decl of node.declarationList.declarations) {
        if (!decl.initializer || !decl.name || !ts.isIdentifier(decl.name)) continue;
        let init = decl.initializer;
        while (ts.isAsExpression(init) || ts.isTypeAssertionExpression?.(init) || ts.isParenthesizedExpression(init)) {
          init = init.expression;
        }
        if (ts.isArrowFunction(init) && init.body) {
          pushFunction({
            node: init,
            name: decl.name.text,
            kind: 'arrow-function',
            exported,
            isAsync: asyncMod(init),
            body: init.body,
          });
        } else if (ts.isFunctionExpression(init) && init.body) {
          pushFunction({
            node: init,
            name: decl.name.text,
            kind: 'function-expression',
            exported,
            isAsync: asyncMod(init),
            body: init.body,
          });
        }
      }
    }

    ts.forEachChild(node, visit);
  }

  visit(sf);
  return results;
}

// --- Run ---

const mainFiles = walkDir(ROOT);
const sharedFiles = SHARED ? walkDir(SHARED) : [];

process.stderr.write(`main: ${mainFiles.length} files\n`);
if (SHARED) process.stderr.write(`shared: ${sharedFiles.length} files\n`);

const all = [];
let errors = 0;
for (const f of mainFiles) {
  try { all.push(...extractFromFile(f, 'main', ROOT)); }
  catch (e) { errors++; process.stderr.write(`  ERR ${f}: ${e.message}\n`); }
}
for (const f of sharedFiles) {
  try { all.push(...extractFromFile(f, 'shared', SHARED)); }
  catch (e) { errors++; process.stderr.write(`  ERR ${f}: ${e.message}\n`); }
}

process.stderr.write(`\nTotal functions: ${all.length} (errors: ${errors})\n`);
const byKind = {};
const byPkg = {};
let isTestCount = 0;
for (const e of all) {
  byKind[e.kind] = (byKind[e.kind] || 0) + 1;
  byPkg[e.package] = (byPkg[e.package] || 0) + 1;
  if (e.is_test) isTestCount++;
}
process.stderr.write('By kind:\n');
for (const [k, v] of Object.entries(byKind).sort((a, b) => b[1] - a[1])) {
  process.stderr.write(`  ${String(v).padStart(5)}  ${k}\n`);
}
process.stderr.write('By package:\n');
for (const [k, v] of Object.entries(byPkg)) {
  process.stderr.write(`  ${String(v).padStart(5)}  ${k}\n`);
}
process.stderr.write(`is_test entries: ${isTestCount}\n`);

const catalog = {
  schema_version: SCHEMA_VERSION,
  extractor: {
    language: 'typescript',
    name: 'function-catalog',
    version: EXTRACTOR_VERSION,
  },
  entries: all,
};

const json = JSON.stringify(catalog, null, 2);
if (values.output) {
  writeFileSync(values.output, json);
  process.stderr.write(`\nWrote ${values.output}\n`);
} else {
  process.stdout.write(json);
}

process.exit(mainFiles.length > 0 ? 0 : 1);
