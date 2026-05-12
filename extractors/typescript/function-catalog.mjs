#!/usr/bin/env node
// function-catalog.mjs
//
// Walks every .ts / .tsx source file under --root (and optionally --shared) and emits
// one JSON record per declared function-like construct: function declarations, method
// declarations, and arrow/function expressions assigned to named bindings.
//
// Each record carries:
//   - body_hash: SHA-256 of the normalized body text (comments + whitespace stripped)
//   - body_lines: sorted-unique normalized non-empty non-comment lines (Jaccard input)
//   - param_count: arity
//
// See ../../docs/pipeline-contract.md for the emitted schema.

import ts from 'typescript';
import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    root:           { type: 'string' },
    shared:         { type: 'string' },
    output:         { type: 'string' },
    'min-body-lines': { type: 'string', default: '3' },
    'include-tests':{ type: 'boolean', default: false },
    help:           { type: 'boolean', default: false },
  },
});

if (values.help || !values.root) {
  process.stderr.write(`usage: function-catalog.mjs --root <path> [--shared <path>] [--output <path>] [--min-body-lines <n>] [--include-tests]

  --root             Required. Root of the codebase to scan.
  --shared           Optional. A secondary package root. Tagged as package="shared".
  --output           Optional. Write JSON to this path. Default: stdout.
  --min-body-lines   Optional. Skip functions whose normalized body has fewer than n lines
                     (default 3). Filters out one-liners and stubs that aren't duplication signal.
  --include-tests    Optional. Don't skip tests/ and *.test.ts / *.spec.ts files.
`);
  process.exit(values.help ? 0 : 1);
}

const ROOT = resolve(values.root);
const SHARED = values.shared ? resolve(values.shared) : null;
const INCLUDE_TESTS = values['include-tests'];
const MIN_BODY_LINES = Number(values['min-body-lines']) || 3;

const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', 'coverage']);
if (!INCLUDE_TESTS) SKIP_DIRS.add('tests');

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
        if (!INCLUDE_TESTS && /\.(test|spec)\.(tsx|ts)$/.test(e.name)) continue;
        out.push(full);
      }
    }
  }
  walk(root);
  return out;
}

// Normalize body text: strip comments, collapse whitespace runs to single spaces,
// trim each line, drop blank lines. The result is a multi-line string where each
// line is a meaningful unit. Deterministic across whitespace-only edits.
function normalizeBody(text) {
  // Strip /* ... */ block comments (non-greedy)
  let stripped = text.replace(/\/\*[\s\S]*?\*\//g, '');
  // Strip line comments — match // ... to end of line, but not when // appears inside a string.
  // A perfect regex is impractical here; we accept rare false strips for strings containing "//".
  stripped = stripped.replace(/\/\/[^\n]*/g, '');
  const lines = stripped
    .split('\n')
    .map((l) => l.replace(/\s+/g, ' ').trim())
    .filter((l) => l.length > 0);
  return lines;
}

function bodyHashOf(normLines) {
  const joined = normLines.join('\n');
  return createHash('sha256').update(joined).digest('hex');
}

function bodyTextOf(node, sf) {
  // Function/method declarations have a Block body; arrow functions have either a
  // Block or an Expression. getText() handles all of these uniformly.
  return node ? node.getText(sf) : '';
}

function paramsOf(parameters, sf) {
  if (!parameters) return { count: 0, names: [] };
  return {
    count: parameters.length,
    names: parameters.map((p) => p.name.getText(sf)),
  };
}

function exportedMod(node) {
  return !!node.modifiers?.some((m) => m.kind === ts.SyntaxKind.ExportKeyword);
}

function asyncMod(node) {
  return !!node.modifiers?.some((m) => m.kind === ts.SyntaxKind.AsyncKeyword);
}

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
  const results = [];

  function pushFunction({ node, name, kind, exported, isAsync, params, body }) {
    const bodyText = bodyTextOf(body, sf);
    const normLines = normalizeBody(bodyText);
    if (normLines.length < MIN_BODY_LINES) return;
    const { line } = sf.getLineAndCharacterOfPosition(node.getStart(sf));
    const bodyHash = bodyHashOf(normLines);
    const sortedUniqueLines = [...new Set(normLines)].sort();
    results.push({
      package: pkgName,
      file: relPath,
      line: line + 1,
      generated: isGenerated,
      name,
      kind,
      exported,
      async: isAsync,
      param_count: params.count,
      param_names: params.names,
      body_line_count: normLines.length,
      body_length: normLines.join('\n').length,
      body_hash: bodyHash,
      body_lines: sortedUniqueLines,
    });
  }

  function visit(node) {
    // function foo(...) { ... }
    if (ts.isFunctionDeclaration(node) && node.name && node.body) {
      pushFunction({
        node,
        name: node.name.text,
        kind: 'function',
        exported: exportedMod(node),
        isAsync: asyncMod(node),
        params: paramsOf(node.parameters, sf),
        body: node.body,
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
        params: paramsOf(node.parameters, sf),
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
            node: decl,
            name: decl.name.text,
            kind: 'arrow-function',
            exported,
            isAsync: asyncMod(init),
            params: paramsOf(init.parameters, sf),
            body: init.body,
          });
        } else if (ts.isFunctionExpression(init) && init.body) {
          pushFunction({
            node: decl,
            name: decl.name.text,
            kind: 'function-expression',
            exported,
            isAsync: asyncMod(init),
            params: paramsOf(init.parameters, sf),
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
for (const e of all) {
  byKind[e.kind] = (byKind[e.kind] || 0) + 1;
  byPkg[e.package] = (byPkg[e.package] || 0) + 1;
}
process.stderr.write('By kind:\n');
for (const [k, v] of Object.entries(byKind).sort((a, b) => b[1] - a[1])) {
  process.stderr.write(`  ${String(v).padStart(5)}  ${k}\n`);
}
process.stderr.write('By package:\n');
for (const [k, v] of Object.entries(byPkg)) {
  process.stderr.write(`  ${String(v).padStart(5)}  ${k}\n`);
}

const json = JSON.stringify(all, null, 2);
if (values.output) {
  writeFileSync(values.output, json);
  process.stderr.write(`\nWrote ${values.output}\n`);
} else {
  process.stdout.write(json);
}

process.exit(mainFiles.length > 0 ? 0 : 1);
