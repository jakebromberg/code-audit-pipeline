#!/usr/bin/env node
// type-catalog.mjs
//
// Walks every .ts source file under --root (and optionally --shared) and emits
// one JSON record per declared type / interface / Zod schema / Drizzle table.
// Each record carries a deterministic `shape_sig` so downstream cluster queries
// can group duplicates with `jq`.
//
// See ../../docs/pipeline-contract.md for the emitted schema.

import ts from 'typescript';
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: {
    root:           { type: 'string' },
    shared:         { type: 'string' },
    touched:        { type: 'string' },
    output:         { type: 'string' },
    'include-tests':{ type: 'boolean', default: false },
    help:           { type: 'boolean', default: false },
  },
});

if (values.help || !values.root) {
  process.stderr.write(`usage: type-catalog.mjs --root <path> [--shared <path>] [--touched <json>] [--output <path>] [--include-tests]

  --root           Required. Root of the codebase to scan.
  --shared         Optional. A secondary package root (canonical types you compare
                   against). Tagged as package="shared" in output.
  --touched        Optional. Path to a JSON array of file paths (relative to --root)
                   to mark as touched_in_window=true.
  --output         Optional. Write JSON to this path. Default: stdout.
  --include-tests  Optional. Don't skip tests/ and *.test.ts / *.spec.ts files.
`);
  process.exit(values.help ? 0 : 1);
}

const ROOT = resolve(values.root);
const SHARED = values.shared ? resolve(values.shared) : null;
const TOUCHED = values.touched
  ? new Set(JSON.parse(readFileSync(values.touched, 'utf8')))
  : new Set();
const INCLUDE_TESTS = values['include-tests'];

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
        // Skip dotdirs (.git, .claude, .cursor, .idea, .vscode, .next, …) — they
        // typically hold IDE/agent state, generated artifacts, or worktree clones
        // that would inflate the catalog with near-duplicate copies of the same repo.
        if (e.name.startsWith('.')) continue;
        if (SKIP_DIRS.has(e.name)) continue;
        walk(full);
      } else if (e.isFile()) {
        if (!/\.(ts|mts|cts)$/.test(e.name)) continue;
        if (!INCLUDE_TESTS && /\.(test|spec)\.ts$/.test(e.name)) continue;
        out.push(full);
      }
    }
  }
  walk(root);
  return out;
}

const normalize = (s) => (s ?? '').replace(/\s+/g, ' ').trim();
const shapeSig = (fields) => [...fields].sort().join('|').toLowerCase();
const typeSig = (text) => normalize(text).toLowerCase();

function membersToFields(members, sf) {
  return members
    .filter((m) => ts.isPropertySignature(m) && m.name)
    .map((m) => {
      const name = m.name.getText(sf);
      const type = m.type ? normalize(m.type.getText(sf)) : 'any';
      const optional = m.questionToken ? '?' : '';
      return `${name}${optional}:${type}`;
    });
}

function extractZodObjectFields(arg, sf) {
  if (!arg || !ts.isObjectLiteralExpression(arg)) return null;
  return arg.properties
    .filter((p) => ts.isPropertyAssignment(p) || ts.isShorthandPropertyAssignment(p))
    .map((p) => {
      const fname = p.name.getText(sf);
      const ftype = ts.isPropertyAssignment(p)
        ? normalize(p.initializer.getText(sf)).slice(0, 120)
        : 'shorthand';
      return `${fname}:${ftype}`;
    });
}

function extractDrizzleTableFields(arg, sf) {
  if (!arg || !ts.isObjectLiteralExpression(arg)) return null;
  return arg.properties
    .filter((p) => ts.isPropertyAssignment(p))
    .map((p) => {
      const fname = p.name.getText(sf);
      let cur = p.initializer;
      let baseType = 'unknown';
      // Walk a call chain like `integer('id').primaryKey().notNull()` down to `integer`
      while (cur && ts.isCallExpression(cur)) {
        const callee = cur.expression;
        if (ts.isPropertyAccessExpression(callee)) {
          cur = callee.expression;
        } else {
          baseType = callee.getText(sf);
          break;
        }
      }
      if (baseType === 'unknown' && cur && ts.isIdentifier(cur)) baseType = cur.text;
      return `${fname}:${baseType}`;
    });
}

function isZodObjectCall(call) {
  const callee = call.expression;
  if (!ts.isPropertyAccessExpression(callee)) return false;
  if (callee.name.text !== 'object') return false;
  const base = callee.expression;
  return ts.isIdentifier(base) && base.text === 'z';
}

function isDrizzleTableCall(call) {
  const callee = call.expression;
  if (ts.isIdentifier(callee) && callee.text === 'pgTable') return true;
  if (ts.isPropertyAccessExpression(callee)) {
    if (callee.name.text === 'table' || callee.name.text === 'pgTable') return true;
  }
  return false;
}

function isInferModelType(typeNode, sf) {
  if (!ts.isTypeReferenceNode(typeNode)) return null;
  const refName = typeNode.typeName.getText(sf);
  if (refName !== 'InferSelectModel' && refName !== 'InferInsertModel') return null;
  const args = typeNode.typeArguments;
  if (!args || args.length === 0) return null;
  const arg = args[0];
  if (ts.isTypeQueryNode(arg)) return { kind: refName, table: arg.exprName.getText(sf) };
  return { kind: refName, table: arg.getText(sf) };
}

function exportedMod(node) {
  return !!node.modifiers?.some((m) => m.kind === ts.SyntaxKind.ExportKeyword);
}

function extractFromFile(filePath, pkgName, pkgRoot) {
  const text = readFileSync(filePath, 'utf8');
  const sf = ts.createSourceFile(filePath, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const relPath = relative(pkgRoot, filePath);
  // touched_in_window meaningful only for main package
  const isTouched = pkgName === 'main' && TOUCHED.has(relPath);
  const isGenerated = relPath.includes('/generated/') || relPath.endsWith('.d.ts');
  const results = [];

  function pushBase(node, partial) {
    const { line } = sf.getLineAndCharacterOfPosition(node.getStart(sf));
    results.push({
      package: pkgName,
      file: relPath,
      line: line + 1,
      touched_in_window: isTouched,
      generated: isGenerated,
      ...partial,
    });
  }

  function visit(node) {
    if (ts.isInterfaceDeclaration(node)) {
      const fields = membersToFields(node.members, sf);
      const generics = node.typeParameters?.map((p) => p.name.text).join(',') ?? null;
      pushBase(node, {
        name: node.name.text,
        kind: 'interface',
        exported: exportedMod(node),
        generics,
        fields,
        shape_sig: shapeSig(fields),
      });
    }

    if (ts.isTypeAliasDeclaration(node)) {
      const generics = node.typeParameters?.map((p) => p.name.text).join(',') ?? null;
      let kind = 'type-alias-other';
      let fields = null;
      let shape_sig = null;
      let type_text = null;
      let type_sig = null;
      let infer_ref = null;

      if (ts.isTypeLiteralNode(node.type)) {
        fields = membersToFields(node.type.members, sf);
        shape_sig = shapeSig(fields);
        kind = 'type-alias-object';
      } else {
        type_text = normalize(node.type.getText(sf)).slice(0, 300);
        type_sig = typeSig(type_text);
        infer_ref = isInferModelType(node.type, sf);
        if (infer_ref) kind = 'type-alias-infer-model';
        else if (ts.isUnionTypeNode(node.type)) kind = 'type-alias-union';
        else if (ts.isIntersectionTypeNode(node.type)) kind = 'type-alias-intersection';
      }

      pushBase(node, {
        name: node.name.text,
        kind,
        exported: exportedMod(node),
        generics,
        fields,
        shape_sig,
        type_text,
        type_sig,
        infer_ref,
      });
    }

    if (ts.isVariableStatement(node)) {
      const exported = exportedMod(node);
      for (const decl of node.declarationList.declarations) {
        if (!decl.initializer) continue;
        let init = decl.initializer;
        while (ts.isAsExpression(init) || ts.isTypeAssertionExpression?.(init)) init = init.expression;
        if (!ts.isCallExpression(init)) continue;
        const name = decl.name.getText(sf);

        if (isZodObjectCall(init)) {
          const fields = extractZodObjectFields(init.arguments[0], sf);
          pushBase(decl, {
            name,
            kind: 'zod-object',
            exported,
            fields,
            shape_sig: fields ? shapeSig(fields) : null,
          });
        } else if (isDrizzleTableCall(init)) {
          const args = init.arguments;
          const nameArg = args[0];
          let colsArg = args[1];
          if (colsArg && !ts.isObjectLiteralExpression(colsArg)) {
            colsArg = args[2] && ts.isObjectLiteralExpression(args[2]) ? args[2] : colsArg;
          }
          const dbName = nameArg && ts.isStringLiteral(nameArg) ? nameArg.text : null;
          const fields = extractDrizzleTableFields(colsArg, sf);
          pushBase(decl, {
            name,
            kind: 'drizzle-table',
            exported,
            db_table_name: dbName,
            fields,
            shape_sig: fields ? shapeSig(fields) : null,
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

process.stderr.write(`\nTotal entries: ${all.length} (errors: ${errors})\n`);
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
