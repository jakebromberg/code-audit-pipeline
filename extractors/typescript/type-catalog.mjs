#!/usr/bin/env node
// type-catalog.mjs
//
// Walks every .ts / .tsx source file under --root (and optionally --shared) and emits
// one JSON record per declared type / interface / Zod schema / Drizzle table.
// Each record carries a deterministic `shape_sig` so downstream cluster queries
// can group duplicates with `jq`.
//
// See ../../docs/pipeline-contract.md for the emitted schema.

import ts from 'typescript';
import { readFileSync, writeFileSync, readdirSync, existsSync, statSync } from 'node:fs';
import { join, relative, resolve, dirname, basename } from 'node:path';
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

// --- Sibling-shared-package detection (warning only) ---

function findSharedCandidates(root) {
  // Look one level up from --root for sibling directories that look like a shared
  // types package: name matches *shared* (case-insensitive) OR package.json `name` matches,
  // and has a `src/` subdirectory.
  const parent = dirname(root);
  const selfName = basename(root);
  let entries;
  try { entries = readdirSync(parent, { withFileTypes: true }); } catch { return []; }
  const matches = [];
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    if (e.name === selfName) continue;
    if (e.name.startsWith('.')) continue;
    const dirPath = join(parent, e.name);
    const srcPath = join(dirPath, 'src');
    if (!existsSync(srcPath)) continue;
    const pkgPath = join(dirPath, 'package.json');
    let pkgName = null;
    if (existsSync(pkgPath)) {
      try { pkgName = JSON.parse(readFileSync(pkgPath, 'utf8')).name ?? null; }
      catch { /* ignore */ }
    }
    const nameSignal = /shared/i.test(e.name) || (pkgName && /shared/i.test(pkgName));
    if (nameSignal) matches.push({ srcPath, dirName: e.name, pkgName });
  }
  return matches;
}

if (!SHARED) {
  const candidates = findSharedCandidates(ROOT);
  if (candidates.length > 0) {
    process.stderr.write(
      `WARNING: --shared was not passed, but ${candidates.length} sibling shared-package candidate(s) ` +
      `were detected. Cross-package shadowing will be undetectable without --shared. Candidates:\n`
    );
    for (const c of candidates) {
      const pkgLabel = c.pkgName ? ` (package "${c.pkgName}")` : '';
      process.stderr.write(`  --shared ${c.srcPath}${pkgLabel}\n`);
    }
    process.stderr.write('\n');
  }
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
        // Skip dotdirs (.git, .claude, .cursor, .idea, .vscode, .next, …) — they
        // typically hold IDE/agent state, generated artifacts, or worktree clones
        // that would inflate the catalog with near-duplicate copies of the same repo.
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

const normalize = (s) => (s ?? '').replace(/\s+/g, ' ').trim();
const shapeSig = (fields) => [...fields].sort().join('|').toLowerCase();
const typeSig = (text) => normalize(text).toLowerCase();

// --- Identifier-occurrence counter (for reference_count, grep-approximation) ---
const idCounts = new Map();
function countIdentifiers(text) {
  // Capture identifiers (letter or underscore start). Strings and comments are not stripped —
  // we accept the noise; reference_count is a coarse signal, not a precise one.
  for (const m of text.matchAll(/\b[A-Za-z_][A-Za-z0-9_]*\b/g)) {
    const id = m[0];
    idCounts.set(id, (idCounts.get(id) || 0) + 1);
  }
}

function membersToFields(members, sf, opts) {
  // opts: { ownerName, emitSynthetic, pkgName, relPath, isTouched, generated } — when present,
  // nested TypeLiteralNodes on properties emit synthetic catalog entries.
  return members
    .filter((m) => ts.isPropertySignature(m) && m.name)
    .map((m) => {
      const name = m.name.getText(sf);
      const optional = m.questionToken ? '?' : '';
      const typeNode = m.type;
      const typeText = typeNode ? normalize(typeNode.getText(sf)) : 'any';
      if (opts && typeNode && ts.isTypeLiteralNode(typeNode)) {
        const propBase = name.replace(/\?$/, '');
        const innerName = `${opts.ownerName}.${propBase}`;
        const innerFields = membersToFields(typeNode.members, sf, { ...opts, ownerName: innerName });
        const { line } = sf.getLineAndCharacterOfPosition(typeNode.getStart(sf));
        opts.emitSynthetic({
          package: opts.pkgName,
          file: opts.relPath,
          line: line + 1,
          touched_in_window: opts.isTouched,
          generated: opts.generated,
          name: innerName,
          kind: 'inline-object',
          exported: false,
          generics: null,
          fields: innerFields,
          shape_sig: shapeSig(innerFields),
          synthetic: true,
          parent: opts.ownerName,
        });
      }
      return `${name}${optional}:${typeText}`;
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
  countIdentifiers(text);
  const isTsx = filePath.endsWith('.tsx');
  const sf = ts.createSourceFile(
    filePath,
    text,
    ts.ScriptTarget.Latest,
    true,
    isTsx ? ts.ScriptKind.TSX : ts.ScriptKind.TS,
  );
  const relPath = relative(pkgRoot, filePath);
  // touched_in_window meaningful only for main package
  const isTouched = pkgName === 'main' && TOUCHED.has(relPath);
  const isGenerated = /(^|\/)generated\//.test(relPath) || relPath.endsWith('.d.ts');
  const results = [];
  const emitSynthetic = (entry) => results.push(entry);

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
      const fields = membersToFields(node.members, sf, {
        ownerName: node.name.text,
        emitSynthetic,
        pkgName,
        relPath,
        isTouched,
        generated: isGenerated,
      });
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
        fields = membersToFields(node.type.members, sf, {
          ownerName: node.name.text,
          emitSynthetic,
          pkgName,
          relPath,
          isTouched,
          generated: isGenerated,
        });
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

// --- reference_count second pass ---
// reference_count = total identifier occurrences across all scanned files MINUS the number of
// catalog entries declaring that name. Synthetic ("Outer.prop") names contain `.` and won't match
// identifier regex, so they get 0 — correct (synthetics aren't named in source).
const declCountByName = new Map();
for (const e of all) {
  declCountByName.set(e.name, (declCountByName.get(e.name) || 0) + 1);
}
for (const e of all) {
  if (e.synthetic) {
    e.reference_count = 0;
  } else {
    const total = idCounts.get(e.name) || 0;
    const decls = declCountByName.get(e.name) || 1;
    e.reference_count = Math.max(0, total - decls);
  }
}

process.stderr.write(`\nTotal entries: ${all.length} (errors: ${errors})\n`);
const byKind = {};
const byPkg = {};
let syntheticCount = 0;
for (const e of all) {
  byKind[e.kind] = (byKind[e.kind] || 0) + 1;
  byPkg[e.package] = (byPkg[e.package] || 0) + 1;
  if (e.synthetic) syntheticCount++;
}
process.stderr.write('By kind:\n');
for (const [k, v] of Object.entries(byKind).sort((a, b) => b[1] - a[1])) {
  process.stderr.write(`  ${String(v).padStart(5)}  ${k}\n`);
}
process.stderr.write('By package:\n');
for (const [k, v] of Object.entries(byPkg)) {
  process.stderr.write(`  ${String(v).padStart(5)}  ${k}\n`);
}
if (syntheticCount > 0) {
  process.stderr.write(`Synthetic (inline-literal) entries: ${syntheticCount}\n`);
}

const json = JSON.stringify(all, null, 2);
if (values.output) {
  writeFileSync(values.output, json);
  process.stderr.write(`\nWrote ${values.output}\n`);
} else {
  process.stdout.write(json);
}

process.exit(mainFiles.length > 0 ? 0 : 1);
