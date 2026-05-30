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
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import {
  BUILTIN_TYPE_DENYLIST,
  extractReferences,
  genericsList,
  getLeftmostIdentifierText,
  pushNamedRef,
  refsForDecl,
} from './_lib/references.mjs';
import { isTestPath } from './_lib/paths.mjs';

const EXTRACTOR_DIR = dirname(fileURLToPath(import.meta.url));
const EXTRACTOR_VERSION = JSON.parse(readFileSync(join(EXTRACTOR_DIR, 'package.json'), 'utf8')).version;
const SCHEMA_VERSION = '1.1';

const { values } = parseArgs({
  options: {
    root:                    { type: 'string' },
    shared:                  { type: 'string' },
    touched:                 { type: 'string' },
    output:                  { type: 'string' },
    'emit-references-graph': { type: 'string' },
    'emit-files':            { type: 'string' },
    help:                    { type: 'boolean', default: false },
  },
});

if (values.help || !values.root) {
  process.stderr.write(`usage: type-catalog.mjs --root <path> [--shared <path>] [--touched <json>] [--output <path>] [--emit-references-graph <path>] [--emit-files <path>]

  --root           Required. Root of the codebase to scan.
  --shared         Optional. A secondary package root (canonical types you compare
                   against). Tagged as package="shared" in output.
  --touched        Optional. Path to a JSON array of file paths (relative to --root)
                   to mark as touched_in_window=true.
  --output         Optional. Write JSON to this path. Default: stdout.
  --emit-references-graph <path>
                   Optional. Write a sibling references.json artifact
                   (per docs/pipeline-contract.md §sibling artifacts) to
                   <path>. The file contains an inverted edge list keyed by
                   (package, name); resolution prefers same-package targets,
                   falls back to the shared package, then marks unresolved.
  --emit-files <path>
                   Optional. Write a sibling files.json artifact
                   (per docs/pipeline-contract.md §files artifact) to <path>.
                   The file contains one row per source file with its resolved
                   import / re-export / dynamic-import edges, package-tagged
                   (main / shared / extern). Consumed by the
                   cross-package-backward-imports.jq query (and the future
                   cycle-detection, unused-imports, dependency-mass-per-file
                   queries).

Output: {"schema_version": "${SCHEMA_VERSION}", "extractor": {...}, "entries": [...]}.
Queries that consume the catalog must read from .entries (see _canonical.jq's
"entries" helper, which also accepts the legacy bare-array form for one release).

Test files are always extracted; every row carries an \`is_test\` flag derived
from the file path. To exclude tests post-hoc, pipe through:
  jq '.entries | map(select(.is_test | not))'
`);
  process.exit(values.help ? 0 : 1);
}

const ROOT = resolve(values.root);
const SHARED = values.shared ? resolve(values.shared) : null;
const TOUCHED = values.touched
  ? new Set(JSON.parse(readFileSync(values.touched, 'utf8')))
  : new Set();

const SKIP_DIRS = new Set(['node_modules', 'dist', 'build', 'coverage']);

// BUILTIN_TYPE_DENYLIST, extractReferences, pushNamedRef, refsForDecl,
// getLeftmostIdentifierText, genericsList are imported from _lib/references.mjs
// (shared with function-catalog.mjs).

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

// Test-path classification. Pattern set is normative — duplicated verbatim in
// docs/pipeline-contract.md so other-language extractors (#115) stay aligned.
// isTestPath imported from _lib/paths.mjs (shared with function-catalog).

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
  // opts: { ownerName, emitSynthetic, rowDefaults } — when present, nested
  // TypeLiteralNodes on properties emit synthetic catalog entries inheriting
  // their parent record's per-file defaults (package/file/touched/generated/is_test).
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
          ...opts.rowDefaults,
          line: line + 1,
          name: innerName,
          kind: 'inline-object',
          exported: false,
          generics: null,
          fields: innerFields,
          shape_sig: shapeSig(innerFields),
          extends: [],
          references: [],
          references_count: 0,
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
  // Modern Drizzle API: `typeof T.$inferSelect` / `typeof T.$inferInsert`. These
  // are TypeQueryNodes (TypeQueryNode → QualifiedName) rather than TypeReferenceNodes,
  // so the legacy InferSelectModel<typeof T> branch below won't see them.
  if (ts.isTypeQueryNode(typeNode) && ts.isQualifiedName(typeNode.exprName)) {
    const prop = typeNode.exprName.right.text;
    if (prop === '$inferSelect' || prop === '$inferInsert') {
      return { kind: prop, table: typeNode.exprName.left.getText(sf) };
    }
  }
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

// Heritage-clause supertype names for `interface X extends A, B {}`. Returns a
// sorted, deduplicated array of names. `implements` clauses are ignored (TS
// doesn't model implementation as a supertype edge on the declaring side).
//
// Qualified expressions (`extends Namespace.Foo`) round-trip the full dotted
// source text rather than splitting — rare in practice, and the downstream
// resolution pass handles the `(package, name)` lookup uniformly via the
// leftmost identifier.
function extractExtendsFromInterface(node, sf) {
  if (!node.heritageClauses) return [];
  const names = new Set();
  for (const clause of node.heritageClauses) {
    if (clause.token !== ts.SyntaxKind.ExtendsKeyword) continue;
    for (const ewta of clause.types) {
      const expr = ewta.expression;
      if (ts.isIdentifier(expr)) names.add(expr.text);
      else names.add(normalize(expr.getText(sf)));
    }
  }
  return [...names].sort();
}

// --- Per-file import edge resolver (for --emit-files / files.json) ---
//
// The walker itself lives inside extractFromFile so the type-extraction
// recursion can collect dynamic-import calls in the same pass (one tree
// walk per file, not two). What's down here is just the resolver and the
// existence cache it shares across the whole run.
//
// Resolution: relative paths only in v1 (no tsconfig.json `paths` aliases —
// docs/pipeline-contract.md §files artifact spells out the v1 scope).

const RESOLVE_EXTENSIONS = ['.ts', '.tsx', '.mts', '.cts'];

// Memoized across the whole extractor run: the same target gets probed
// repeatedly (every file that imports './shared/x' produces the same set
// of candidates). On a 300-file repo with ~10 imports/file, this collapses
// ~27k stat calls down to ~3k unique paths.
const _existsCache = new Map();
function isExistingFile(absPath) {
  const cached = _existsCache.get(absPath);
  if (cached !== undefined) return cached;
  const stat = statSync(absPath, { throwIfNoEntry: false });
  const result = stat ? stat.isFile() : false;
  _existsCache.set(absPath, result);
  return result;
}

// POSIX-only guard: `relative()` never returns a leading "/" on Linux/macOS,
// so the `!rel.startsWith('/')` clause is dead here. It's kept defensively
// because `path.relative` does return absolute-looking strings on Windows
// when the inputs share no drive root.
function isUnderDir(absPath, dirPath) {
  if (!dirPath) return false;
  const rel = relative(dirPath, absPath);
  return rel !== '' && !rel.startsWith('..') && !rel.startsWith('/');
}

function resolveImportSpec(spec, fromFilePath) {
  if (!spec.startsWith('.')) {
    return { package: 'extern', path: spec };
  }
  const baseAbs = resolve(dirname(fromFilePath), spec);
  // Matches Node's resolver order for TS: exact, then each extension,
  // then each /index.<ext>. First hit wins.
  const candidates = [baseAbs];
  for (const ext of RESOLVE_EXTENSIONS) candidates.push(baseAbs + ext);
  for (const ext of RESOLVE_EXTENSIONS) candidates.push(join(baseAbs, 'index' + ext));
  for (const c of candidates) {
    if (!isExistingFile(c)) continue;
    if (isUnderDir(c, ROOT)) return { package: 'main', path: relative(ROOT, c) };
    if (isUnderDir(c, SHARED)) return { package: 'shared', path: relative(SHARED, c) };
    return { package: 'extern', path: c };
  }
  return { package: 'extern', path: spec };
}

function extractFromFile(filePath, pkgName, pkgRoot, collectImports) {
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
  const rowDefaults = {
    package: pkgName,
    file: relPath,
    touched_in_window: pkgName === 'main' && TOUCHED.has(relPath),
    generated: /(^|\/)generated\//.test(relPath) || relPath.endsWith('.d.ts'),
    is_test: isTestPath(relPath),
  };
  const results = [];
  const emitSynthetic = (entry) => results.push(entry);
  // null when --emit-files is off — short-circuits the dynamic-import branch
  // inside visit() below.
  const rawImports = collectImports ? [] : null;
  if (collectImports) {
    for (const stmt of sf.statements) {
      if (ts.isImportDeclaration(stmt) && stmt.moduleSpecifier && ts.isStringLiteral(stmt.moduleSpecifier)) {
        const { line } = sf.getLineAndCharacterOfPosition(stmt.getStart(sf));
        rawImports.push({
          kind: 'import',
          spec: stmt.moduleSpecifier.text,
          type_only: stmt.importClause?.isTypeOnly === true,
          line: line + 1,
        });
      } else if (ts.isExportDeclaration(stmt) && stmt.moduleSpecifier && ts.isStringLiteral(stmt.moduleSpecifier)) {
        const { line } = sf.getLineAndCharacterOfPosition(stmt.getStart(sf));
        rawImports.push({
          kind: 're-export',
          spec: stmt.moduleSpecifier.text,
          type_only: stmt.isTypeOnly === true,
          line: line + 1,
        });
      }
    }
  }

  function pushBase(node, partial) {
    const { line } = sf.getLineAndCharacterOfPosition(node.getStart(sf));
    const refs = partial.references ?? [];
    results.push({
      ...rowDefaults,
      line: line + 1,
      ...partial,
      extends: partial.extends ?? [],
      references: refs,
      references_count: refs.length,
    });
  }

  function visit(node) {
    if (ts.isInterfaceDeclaration(node)) {
      const fields = membersToFields(node.members, sf, {
        ownerName: node.name.text,
        emitSynthetic,
        rowDefaults,
      });
      const generics = genericsList(node);
      const extendsList = extractExtendsFromInterface(node, sf);
      const referencesList = refsForDecl(node, sf, node.members);
      pushBase(node, {
        name: node.name.text,
        kind: 'interface',
        exported: exportedMod(node),
        generics,
        fields,
        shape_sig: shapeSig(fields),
        extends: extendsList,
        references: referencesList,
      });
    }

    if (ts.isTypeAliasDeclaration(node)) {
      const generics = genericsList(node);
      let kind = 'type-alias-other';
      let fields = null;
      let shape_sig = null;
      let type_text = null;
      let type_sig = null;
      let infer_ref = null;
      let operands = null;

      if (ts.isTypeLiteralNode(node.type)) {
        fields = membersToFields(node.type.members, sf, {
          ownerName: node.name.text,
          emitSynthetic,
          rowDefaults,
        });
        shape_sig = shapeSig(fields);
        kind = 'type-alias-object';
      } else {
        type_text = normalize(node.type.getText(sf)).slice(0, 300);
        type_sig = typeSig(type_text);
        infer_ref = isInferModelType(node.type, sf);
        if (infer_ref) kind = 'type-alias-infer-model';
        else if (ts.isUnionTypeNode(node.type)) kind = 'type-alias-union';
        else if (ts.isIntersectionTypeNode(node.type)) {
          kind = 'type-alias-intersection';
          // Capture operands for second-pass resolution. Inline literals are resolved here
          // (without emitting synthetic catalog entries — intersection operands are not
          // named inner objects). Type references stash their name for later lookup.
          operands = node.type.types.map((t) => {
            if (ts.isTypeLiteralNode(t)) {
              const inlineFields = membersToFields(t.members, sf, null);
              return { kind: 'literal', fields: inlineFields };
            } else if (ts.isTypeReferenceNode(t)) {
              return { kind: 'ref', name: t.typeName.getText(sf) };
            } else {
              return { kind: 'unresolvable', text: normalize(t.getText(sf)).slice(0, 120) };
            }
          });
        }
      }

      const referencesList = refsForDecl(node, sf, [node.type]);
      // Intersection-extends: named operands of `type X = A & B & {...}` go
      // into `extends`. Inline literals don't — they extend an anonymous
      // shape, not a name. Union variants land in `references`, not `extends`,
      // since they describe possible-types not is-a relationships.
      const extendsList = (kind === 'type-alias-intersection' && operands)
        ? [...new Set(operands.filter((op) => op.kind === 'ref').map((op) => op.name))].sort()
        : [];
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
        operands,
        extends: extendsList,
        references: referencesList,
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

    // Dynamic imports can appear anywhere; piggyback on the type-extraction
    // recursion so we don't pay for a second tree walk. Templated forms
    // (`import(\`./${x}\`)`) are skipped — the spec isn't statically known.
    if (collectImports
        && ts.isCallExpression(node)
        && node.expression.kind === ts.SyntaxKind.ImportKeyword
        && node.arguments.length > 0
        && ts.isStringLiteral(node.arguments[0])) {
      const { line } = sf.getLineAndCharacterOfPosition(node.getStart(sf));
      rawImports.push({
        kind: 'dynamic-import',
        spec: node.arguments[0].text,
        type_only: false,
        line: line + 1,
      });
    }

    ts.forEachChild(node, visit);
  }

  visit(sf);

  let fileRow = null;
  if (collectImports) {
    const imports = rawImports.map((r) => {
      const { package: pkg, path: rpath } = resolveImportSpec(r.spec, filePath);
      return { package: pkg, path: rpath, type_only: r.type_only, kind: r.kind, line: r.line };
    });
    imports.sort((a, b) => {
      if (a.package !== b.package) return a.package < b.package ? -1 : 1;
      if (a.path !== b.path) return a.path < b.path ? -1 : 1;
      if (a.kind !== b.kind) return a.kind < b.kind ? -1 : 1;
      return a.line - b.line;
    });
    fileRow = {
      path: relPath,
      package: pkgName,
      is_test: rowDefaults.is_test,
      imports,
    };
  }
  return { entries: results, fileRow };
}

// --- Run ---

const mainFiles = walkDir(ROOT);
const sharedFiles = SHARED ? walkDir(SHARED) : [];

process.stderr.write(`main: ${mainFiles.length} files\n`);
if (SHARED) process.stderr.write(`shared: ${sharedFiles.length} files\n`);

const EMIT_FILES = !!values['emit-files'];
const all = [];
const fileEntries = [];
let errors = 0;
function indexOne(f, pkg, pkgRoot) {
  const { entries, fileRow } = extractFromFile(f, pkg, pkgRoot, EMIT_FILES);
  all.push(...entries);
  if (fileRow) fileEntries.push(fileRow);
}
for (const f of mainFiles) {
  try { indexOne(f, 'main', ROOT); }
  catch (e) { errors++; process.stderr.write(`  ERR ${f}: ${e.message}\n`); }
}
for (const f of sharedFiles) {
  try { indexOne(f, 'shared', SHARED); }
  catch (e) { errors++; process.stderr.write(`  ERR ${f}: ${e.message}\n`); }
}

// --- intersection-type field resolution second pass ---
// Resolve `type X = A & B & { c: number }` intersections by unioning operand field sets.
// Multi-pass to handle transitive cases (`X = A & B; Y = X & C`); fixed point or max 5 iters.
//
// Resolution rules:
//   - 'literal' operand: use its inline fields directly.
//   - 'ref' operand: look up the named type's `fields` in `fieldsByName`. If it has none
//     (unresolved itself, or no shape), this operand is unresolvable this iteration.
//   - 'unresolvable' operand: stays unresolvable.
//
// Output:
//   - All operands resolved → fields = unique union, shape_sig set, resolved_from = "intersection",
//     operands rewritten from {kind, ...} objects to a flat names list for traceability.
//   - At least one operand unresolved after max iters → fields stays null, unresolved = true,
//     unresolved_operands lists the offenders (for debugging).
//
// NOTE: the `operands` field changes shape between the first pass (array of {kind, ...} objects)
// and the resolved post-pass (array of strings). This is intentional and all in-process —
// external consumers reading `catalog.json` only ever see the post-resolution shape.
{
  const MAX_ITERS = 5;
  // fieldsByName: built fresh each iteration so newly-resolved intersections feed transitive cases.
  for (let iter = 0; iter < MAX_ITERS; iter++) {
    const fieldsByName = new Map();
    for (const e of all) {
      if (e.fields && Array.isArray(e.fields)) fieldsByName.set(e.name, e.fields);
    }
    let changed = false;
    for (const e of all) {
      if (e.kind !== 'type-alias-intersection') continue;
      if (e.fields) continue; // already resolved in a prior iter
      if (!e.operands || e.operands.length === 0) continue;
      const collected = [];
      let unresolved = false;
      const unresolvedOps = [];
      for (const op of e.operands) {
        if (op.kind === 'literal') {
          collected.push(...(op.fields || []));
        } else if (op.kind === 'ref') {
          const f = fieldsByName.get(op.name);
          if (f) {
            collected.push(...f);
          } else {
            unresolved = true;
            unresolvedOps.push(op.name);
          }
        } else {
          unresolved = true;
          unresolvedOps.push(op.text || '<unresolvable>');
        }
      }
      if (!unresolved) {
        // Dedupe by field NAME (left of `:`) — same-named field from two operands collapses
        // to the FIRST occurrence in declaration order. TypeScript's true semantics would
        // intersect (`{a:string} & {a:number}` → `a: never`), but the substrate is for
        // clustering, not type-checking — we just need a deterministic `shape_sig`. Order-
        // dependence is documented in `docs/pipeline-contract.md`.
        const seenName = new Set();
        const merged = [];
        for (const f of collected) {
          const fname = f.split(':')[0].replace(/\?$/, '');
          if (seenName.has(fname)) continue;
          seenName.add(fname);
          merged.push(f);
        }
        merged.sort();
        e.fields = merged;
        e.shape_sig = shapeSig(merged);
        e.resolved_from = 'intersection';
        e.operands = e.operands.map((op) => op.kind === 'ref' ? op.name : op.kind === 'literal' ? '<literal>' : op.text);
        changed = true;
      } else if (iter === MAX_ITERS - 1) {
        // Final pass: mark anything still unresolved
        e.unresolved = true;
        e.unresolved_operands = unresolvedOps;
      }
    }
    if (!changed) break;
  }
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
let isTestCount = 0;
for (const e of all) {
  byKind[e.kind] = (byKind[e.kind] || 0) + 1;
  byPkg[e.package] = (byPkg[e.package] || 0) + 1;
  if (e.synthetic) syntheticCount++;
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
if (syntheticCount > 0) {
  process.stderr.write(`Synthetic (inline-literal) entries: ${syntheticCount}\n`);
}
process.stderr.write(`is_test entries: ${isTestCount}\n`);

const catalog = {
  schema_version: SCHEMA_VERSION,
  extractor: {
    language: 'typescript',
    name: 'type-catalog',
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

// --- Sibling references.json artifact ---
// Inverted edge list. Resolution: same-package first, then 'shared', else
// unresolved (resolved: false, to.package == from.package). The edge list is
// deduplicated and sorted for determinism.
if (values['emit-references-graph']) {
  const namesByPackage = new Map();
  for (const e of all) {
    let names = namesByPackage.get(e.package);
    if (!names) { names = new Set(); namesByPackage.set(e.package, names); }
    names.add(e.name);
  }
  const sharedNames = namesByPackage.get('shared');
  const edges = [];
  const seen = new Set();
  for (const e of all) {
    if (!e.references || e.references.length === 0) continue;
    const sameNames = namesByPackage.get(e.package);
    for (const ref of e.references) {
      let toPackage = e.package;
      let resolved = false;
      if (sameNames?.has(ref.name)) {
        resolved = true;
      } else if (sharedNames?.has(ref.name) && e.package !== 'shared') {
        toPackage = 'shared';
        resolved = true;
      }
      const key = `${e.package} ${e.name} ${toPackage} ${ref.name}`;
      if (seen.has(key)) continue;
      seen.add(key);
      edges.push({
        from: { package: e.package, name: e.name },
        to:   { package: toPackage, name: ref.name },
        kind: 'type-ref',
        resolved,
      });
    }
  }
  edges.sort((a, b) => {
    if (a.from.package !== b.from.package) return a.from.package < b.from.package ? -1 : 1;
    if (a.from.name    !== b.from.name)    return a.from.name    < b.from.name    ? -1 : 1;
    if (a.to.package   !== b.to.package)   return a.to.package   < b.to.package   ? -1 : 1;
    if (a.to.name      !== b.to.name)      return a.to.name      < b.to.name      ? -1 : 1;
    return 0;
  });
  const graph = { schema_version: SCHEMA_VERSION, edges };
  writeFileSync(values['emit-references-graph'], JSON.stringify(graph, null, 2));
  process.stderr.write(`Wrote references graph (${edges.length} edges) to ${values['emit-references-graph']}\n`);
}

// --- Sibling files.json artifact ---
// Per-file import edges (static + re-export + dynamic). Resolved against
// ROOT / SHARED to tag every edge with package ∈ {main, shared, extern}.
// Documented in docs/pipeline-contract.md §files artifact. First consumer is
// pipeline/queries/cross-package-backward-imports.jq.
if (EMIT_FILES) {
  fileEntries.sort((a, b) => {
    if (a.package !== b.package) return a.package < b.package ? -1 : 1;
    if (a.path !== b.path) return a.path < b.path ? -1 : 1;
    return 0;
  });
  const filesArtifact = {
    schema_version: SCHEMA_VERSION,
    extractor: {
      language: 'typescript',
      name: 'type-catalog',
      version: EXTRACTOR_VERSION,
    },
    entries: fileEntries,
  };
  const edgeCount = fileEntries.reduce((acc, f) => acc + f.imports.length, 0);
  writeFileSync(values['emit-files'], JSON.stringify(filesArtifact, null, 2));
  process.stderr.write(`Wrote files (${fileEntries.length} files, ${edgeCount} edges) to ${values['emit-files']}\n`);
}

process.exit(mainFiles.length > 0 ? 0 : 1);
