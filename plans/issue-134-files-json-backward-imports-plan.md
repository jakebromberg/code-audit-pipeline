---
issue: 134
title: files.json artifact + cross-package-backward-imports.jq query
---

# Plan — Issue #134: `files.json` artifact + `cross-package-backward-imports.jq`

## Context

Phase 4 of tracker #116. The deliverable is twofold: a sibling artifact (`files.json`) that records per-file import edges, and the first consumer query (`cross-package-backward-imports.jq`) — a layering check that flags `shared/*` files importing from `main/*`.

Per the issue body, the artifact is what justifies the schema delta (≥2 downstream uses rule from #116). `files.json` unlocks at minimum five downstream consumers: backward-imports (this PR), cycle-detection (stretch), unused-imports (future, after re-export tracking), dependency-mass-per-file (future), and the graph-view import-edge layer (#147, sub-issue of #119). The cycle query has tooling overlap with `madge --circular` and is demoted to a stretch goal — the artifact ships regardless.

The audit's `--root` / `--shared` split is the project's only explicit "should not depend backwards" signal. No existing tool frames the layering check this way — `madge` is file-level and language-locked; ESLint's `import/no-cycle` doesn't model package membership; layered-arch linters all want their own config DSL. `cross-package-backward-imports.jq` is a one-liner against `files.json` once the artifact exists.

## Scope

### In scope (v1)

1. **`files.json` artifact.** New optional output emitted when `type-catalog.mjs` is invoked with `--emit-files <path>`. Wrapper-shape (`{schema_version: "1.1", extractor: {...}, entries: [...]}`) for byte-stable consistency with `references.json`.
2. **`extractImportsFromFile` walker** in `type-catalog.mjs`. Walks `ts.ImportDeclaration` (`import …`), `ts.ExportDeclaration` with `moduleSpecifier` (`export … from`), and dynamic-import call expressions (`import('./x')`). Captures `type_only`, `kind`, `line`.
3. **Module resolver.** Relative-only (`./` and `../`). Probes the file's directory for `<spec>`, `<spec>.ts`, `<spec>.tsx`, `<spec>.mts`, `<spec>.cts`, then the same set inside `<spec>/index.*`. Targets are tagged `package: "main"` if resolved under `ROOT`, `package: "shared"` if under `SHARED`, `package: "extern"` otherwise (or if non-relative — bare `'drizzle-orm'`, scoped `'@org/pkg'`, absolute paths).
4. **`pipeline/queries/cross-package-backward-imports.jq`** — primary query, joins on `files.json` only.
5. **Cluster-envelope convention adopted from the start** — `#! shape: cluster` header, per-row `shape: "cluster"`, `members: [{...}]` of length 1 wrapping the violating shared file. The backward edges from that file go on a top-level `backward_imports: [...]` array, mirroring `orphan-infer-model.jq`'s "top-level finding metadata + member is the entity that has the finding" pattern.
6. **Unit tests** for the extractor (`extractors/typescript/test/files-extractor.test.mjs` or extension of existing tests) covering: basic import, re-export, dynamic-import, type-only, extension probing, `/index.*` probing, externals tagging, line capture, opt-in behavior (`files.json` absent without `--emit-files`).
7. **Integration tests** added to `pipeline/queries/_tests/test_queries_integration.sh` for the new query — synthetic `files.json` fixture, baseline row-set assert, text-cid assert, e2e smoke that runs `--emit-files` against a real fixture tree.
8. **Contract doc.** New `## Files artifact (files.json)` section in `docs/pipeline-contract.md`, documenting the schema, opt-in flag, resolver scope, and the v1 limitations (no `tsconfig` paths, no `require()`).
9. **README** row for the new query.

### Out of scope (deferred per the issue body's Open Questions and Recommendation)

- **`cycle-detection.jq`** — explicit stretch goal in the issue body. `madge --circular` does TS cycles competently; the cycle query justifies itself only on polyglot uniformity once a second-language extractor (#115) lands. **Not built in this PR.** A separate follow-on can ship it if/when an audit surfaces a cycle `madge` missed.
- **`tsconfig.json` path-alias resolution.** Punted to v2 per the issue body. The v1 resolver handles relative paths only. An alias-based cycle (`@app/foo`) won't be detected by the backward-imports query until the resolver learns `paths`. Documented as a known false-negative source.
- **CommonJS `require('./x')` calls.** The TS extractor is ESM-flavored; CJS `require` is a recognized gap (matching `eslint-plugin-import/no-cycle`'s own limitation). Documented; not attempted in v1.
- **`unused-imports.jq`** — depends on re-export tracking in the references walker. Defer to a separate ticket so this PR stays scoped.
- **`dependency-mass-per-file.jq`** — trivially derivable from `files.json` but not in scope; ship as a follow-on if an audit asks for it.
- **`<to>:<line>` granularity on the import row's source line.** The extractor records `line` on each import (cheap; one `sf.getLineAndCharacterOfPosition` call), but the query's text mode only shows the from-file path, not the line. Surfacing the line is a one-line text-mode change in a follow-up if readers ask for it.
- **Per-specifier type-only annotations** (`import { type X, Y } from './y'` — mixed-kind specifier list). v1 only records the declaration-level `isTypeOnly` flag, so a mixed-kind import gets `type_only: false` even though some specifiers are type-only. Worth noting in the schema doc; not worth implementing for v1 (the layering check doesn't care).

## Schema additions

### `files.json` (sibling artifact, v1.1)

Wrapper shape identical to `references.json`:

```jsonc
{
  "schema_version": "1.1",
  "extractor": {
    "language": "typescript",
    "name": "type-catalog",
    "version": "0.4.0"
  },
  "entries": [
    {
      "path": "src/services/flowsheet.service.ts",
      "package": "main",
      "is_test": false,
      "imports": [
        { "package": "main",   "path": "src/models/flowsheet.ts", "type_only": false, "kind": "import",         "line": 3 },
        { "package": "shared", "path": "src/dtos/discogs.ts",     "type_only": true,  "kind": "import",         "line": 5 },
        { "package": "extern", "path": "drizzle-orm",             "type_only": false, "kind": "import",         "line": 1 },
        { "package": "main",   "path": "src/lib/lazy.ts",         "type_only": false, "kind": "dynamic-import", "line": 12 },
        { "package": "main",   "path": "src/models/index.ts",     "type_only": false, "kind": "re-export",      "line": 1 }
      ]
    }
  ]
}
```

Field semantics:

- `path` — file path relative to its package root. Mirrors `file` on catalog rows. Renamed to `path` because `file` reads strangely as a top-level key on a file-shaped row.
- `package` — `"main"`, `"shared"`, or `"extern"`. Externals are emitted on entries[] only at the import level — every entry in entries[] is itself a real file, so `package` will only ever be `main` or `shared` at the row level.
- `is_test` — same file-path-derived flag as the type-catalog uses (re-uses `isTestPath` from `_lib/paths.mjs`).
- `imports[]` — every import / re-export / dynamic-import edge from this file, sorted by `(package, path, kind, line)` for byte determinism.
  - `package` — resolved target package (`main`, `shared`, `extern`).
  - `path` — for `main`/`shared`, the resolved path relative to that package's root (matches `entries[].path` for any same-row target). For `extern`, the verbatim `moduleSpecifier` text (e.g., `"drizzle-orm"`, `"@org/pkg"`, `"./outside/root.ts"` if it resolved outside ROOT/SHARED).
  - `type_only` — `node.importClause?.isTypeOnly` for `ImportDeclaration`; `node.isTypeOnly` for `ExportDeclaration`; always `false` for `dynamic-import`.
  - `kind` — `"import"` | `"re-export"` | `"dynamic-import"`.
  - `line` — 1-indexed source line of the statement.

The resolver does **not** dedupe per-file: `import a` and `import type b` from the same module produce two rows. Two `import` statements (no good reason, but it happens) produce two rows. The query is responsible for deduplication if it needs to.

### CLI contract addition

`type-catalog.mjs` gains `--emit-files <path>`, mirroring the existing `--emit-references-graph <path>` flag:

```
type-catalog.mjs --root <path>
                 [--shared <path>]
                 [--touched <json-file>]
                 [--output <path>]
                 [--emit-references-graph <path>]
                 [--emit-files <path>]              # NEW
```

When omitted, `files.json` is not emitted — keeps the existing invocation byte-stable for users not running the new query yet. Same opt-in pattern as `--emit-references-graph`.

## Extractor changes

### `type-catalog.mjs`

Single-script change. The walker fits naturally inside the existing `extractFromFile` (the source file is already parsed; collecting imports is one extra walk over the top-level statements). Implementation sketch:

1. New CLI flag in `parseArgs` options: `'emit-files': { type: 'string' }`. **Also update the help-text block** (`type-catalog.mjs` lines 42–64) to add `--emit-files <path>` to the usage signature and a one-paragraph description matching the existing `--emit-references-graph` block.
2. Inside the per-file extraction, after the catalog walk, traverse top-level statements:
   - `ts.isImportDeclaration(stmt)` → record `{ kind: "import", moduleSpecifier, type_only: importClause?.isTypeOnly === true, line }`.
   - `ts.isExportDeclaration(stmt) && stmt.moduleSpecifier` → record `{ kind: "re-export", moduleSpecifier, type_only: stmt.isTypeOnly === true, line }`.
   - For dynamic imports: walk descendants (`ts.forEachChild` recursive) looking for `ts.isCallExpression(n) && n.expression.kind === ts.SyntaxKind.ImportKeyword`. Record `{ kind: "dynamic-import", moduleSpecifier: n.arguments[0]?.text, type_only: false, line }`. Skip if the argument isn't a string literal (templated `import(\`./${x}\`)` — unresolvable statically).
3. Resolve each `moduleSpecifier`:
   - If it starts with `.` or `..`: `path.resolve(dirname(filePath), spec)`, then probe extensions and `/index.*`. If the resolved absolute path is under `ROOT` → `package: "main"`, under `SHARED` → `package: "shared"`. If it resolves outside both → `package: "extern"` with the raw spec as `path`.
   - Otherwise (bare specifier, scoped `@org/pkg`, absolute `/abs/path`): `package: "extern"` with the raw spec.
4. After all files processed, emit `files.json` if `--emit-files` is set: collect per-file rows, sort `entries[]` by `(package, path)`, sort each `imports[]` by `(package, path, kind, line)`, JSON-stringify with `JSON.stringify(..., null, 2)`.
5. Stderr summary: `Wrote files (N files, M edges) to <path>` — mirrors `--emit-references-graph`'s summary line.

The walker function is NOT lifted to `_lib/` for v1. Only one extractor needs it; lifting now is premature abstraction per the project's "three similar lines is better than a premature abstraction" rule. Lift if/when a second extractor (Python/Rust/etc., #115) needs it.

### Resolver detail: extension probing order

```
spec
spec.ts
spec.tsx
spec.mts
spec.cts
spec/index.ts
spec/index.tsx
spec/index.mts
spec/index.cts
```

First hit wins. Matches Node's resolver order for TS files. The `existsSync` calls are cheap (file-system cache covers repeat hits during a single extractor run).

### What the walker does NOT do (deliberate)

- No symlink chasing — `realpath`-ing every resolved target would slow extraction without helping the layering check (a symlink from `shared/foo.ts` → `main/bar.ts` is still pointing at main and would still flag, regardless).
- No `package.json#exports` resolution for externals — externals are kept as raw spec strings, since the query doesn't need to inspect their interior.
- No de-duplication of same-target imports within a file (`import { A } from './x'; import { B } from './x'` produces two `imports[]` rows). Queries can collapse if needed; the artifact preserves the source-of-truth count.

## Query semantics

### `cross-package-backward-imports.jq`

Joins on `files.json` only. The query is one filter:

```jq
include "_canonical";

#! shape: cluster

[ entries[]
  | select(.package == "shared")
  | . as $f
  | [.imports[] | select(.package == "main")] as $back
  | select($back | length > 0)
  | {
      cluster_id: cluster_id_single_name(
        "cross-package-backward-imports";
        "\($f.package):\($f.path)"
      ),
      query: "cross-package-backward-imports",
      shape: "cluster",
      backward_imports: $back,
      members: [{
        path: $f.path,
        package: $f.package,
        is_test: $f.is_test
      }]
    }
]
| sort_by(.members[0].package, .members[0].path)
| .[]
| if output_format == "jsonl" then
    @json
  else
    .members[0] as $m
    | "  \($m.path)  ←  " + (
        .backward_imports
        | map("main:" + .path + (if .type_only then " (type-only)" else "" end))
        | join(", ")
      )
      + "  cid=\(.cluster_id)"
  end
```

Granularity decision: one cluster row per **shared file** with any backward imports, with all backward edges grouped into a top-level `backward_imports[]` array. Justification: the *finding* is on the shared file (the layering violator); the main targets are evidence, not co-equal participants. This matches `orphan-infer-model.jq`'s convention (top-level metadata, members[0] = the entity with the finding). Per-edge granularity would inflate the cluster count without adding insight — a shared file with 5 backward imports is one problem to fix, not five.

`cluster_id` format: `cross-package-backward-imports:shared:<path>`. Per-shared-file, never collides within a single run (each shared file appears at most once).

Filters intentionally NOT applied in v1:

- **`type_only` exclusion.** Type-only imports are erased at runtime, but they're still a layering signal — a shared type depending on a main type still means the abstraction is upside-down even if it doesn't ship in the bundle. The text mode annotates `(type-only)` so readers can triage. JSONL consumers can filter `.backward_imports | map(select(.type_only | not))` if they only want runtime edges.
- **`is_test` exclusion.** A shared/test file importing from main is still flagged in v1 (consistent with the broader "extract everything, filter in query" principle). The row carries `members[0].is_test` so queries can post-filter.
- **`dynamic-import` exclusion.** Same reasoning as type-only — a dynamic backward import is still a backward import, semantically. Visible via `.backward_imports[].kind`.

### Output format

**Text mode (default):**
```
  src/dtos/lifted-from-main.ts  ←  main:src/internal/state.ts, main:src/services/foo.ts (type-only)  cid=cross-package-backward-imports:shared:src/dtos/lifted-from-main.ts
```

**JSONL mode (`OUTPUT_FORMAT=jsonl`):**
```jsonc
{
  "cluster_id": "cross-package-backward-imports:shared:src/dtos/lifted-from-main.ts",
  "query": "cross-package-backward-imports",
  "shape": "cluster",
  "backward_imports": [
    { "package": "main", "path": "src/internal/state.ts", "type_only": false, "kind": "import", "line": 5 },
    { "package": "main", "path": "src/services/foo.ts",   "type_only": true,  "kind": "import", "line": 6 }
  ],
  "members": [
    { "path": "src/dtos/lifted-from-main.ts", "package": "shared", "is_test": false }
  ]
}
```

## Tests

### Extractor unit tests (TDD)

The imports walker lives **inside** `type-catalog.mjs`, so tests live next to the existing type-catalog tests. New file: `extractors/typescript/test/files.test.mjs`, matching the established `<tool-name>[.<aspect>].test.mjs` convention (`extract.test.mjs` for the type-catalog's main catalog output, `function-catalog.test.mjs` for the function-catalog; the new file scopes the imports/files-artifact axis of the same type-catalog tool). Cached output via a module-level `_cachedFiles` (mirrors the cache pattern in `function-catalog.test.mjs`).

A small `extractors/typescript/fixtures-files/` subtree provides cases the existing `fixtures/` tree doesn't cover (re-export, dynamic-import, extension probing, externals, a `shared/` sibling for cross-package resolution). Created during implementation; tests run against it via the extractor's `--root` and `--shared` flags.

Tests (failing first per TDD):

1. `--emit-files` writes a file when passed; absent otherwise.
2. Output is wrapped (`schema_version: "1.1"`, `extractor`, `entries[]`).
3. Resolver: relative `./foo` → `foo.ts` resolved.
4. Resolver: relative `./bar` → `bar/index.ts` resolved.
5. Resolver: relative `./missing` → `package: "extern"` with raw spec preserved (no extension found).
6. Resolver: bare `'drizzle-orm'` → `package: "extern"`, raw spec preserved.
7. Resolver: `--shared` target → `package: "shared"`, path relative to SHARED root.
8. `import type { X } from './y'` → `type_only: true`, `kind: "import"`.
9. `import { type X } from './y'` (per-specifier modifier) → `type_only: false` (declaration-level flag; documented limitation).
10. `export { X } from './y'` → `kind: "re-export"`, `type_only` from `node.isTypeOnly`.
11. `export type { X } from './y'` → `kind: "re-export"`, `type_only: true`.
12. `import('./y')` → `kind: "dynamic-import"`, `type_only: false`.
13. `import(\`./${dynamic}\`)` (template literal) → skipped (unresolvable static target).
14. `line` matches the 1-indexed source line of the statement.
15. `imports[]` sorted by `(package, path, kind, line)`.
16. `entries[]` sorted by `(package, path)`.
17. `is_test` reflects test-path heuristic on each row.

### Query integration tests

Added to `pipeline/queries/_tests/test_queries_integration.sh`:

- **Baseline row-set:** Synthetic `files.json` fixture (`fixtures/cross-package-backward-imports-files.input.json` — distinct from the existing `files.input.json`, which is the **file-hashes** fixture for `file-duplicates.jq`; the names don't collide because the new fixture is namespaced). The fixture has: one shared/* file that backward-imports two main/* files (one runtime, one type-only), one shared/* file with only forward imports (must NOT flag), one main/* file (forward imports — must NOT flag), one extern-only shared file (must NOT flag). Assert exactly one row, with `cluster_id` matching the expected `cross-package-backward-imports:shared:...` shape and `backward_imports` containing both expected edges.
- **Text-cid:** existing `assert_text_has_cid` helper, parametrized for the new query.
- **E2E smoke:** Run `node type-catalog.mjs --root <fixture-tree>/main --shared <fixture-tree>/shared --emit-files <tmp>` against an in-tree fixture tree, then run the query against the emitted `files.json`. Assert the planted edge appears in the output.

The fixture tree for the e2e smoke goes under `pipeline/queries/_tests/fixtures/cross-package-backward-imports-fixture-tree/` with the following explicit contents:

```
cross-package-backward-imports-fixture-tree/
├── main/
│   └── src/
│       ├── models/
│       │   └── flowsheet.ts        # export interface Flowsheet { ... }
│       └── index.ts                 # import { Flowsheet } from './models/flowsheet'
└── shared/
    └── src/
        ├── dtos/
        │   └── lifted.ts            # import type { Flowsheet } from '../../../main/src/models/flowsheet'  (planted backward edge)
        └── primitives.ts            # export type ID = string  (clean — no backward edge)
```

The planted backward edge in `shared/src/dtos/lifted.ts` resolves through the relative path `../../../main/src/models/flowsheet` → `main` package → flagged by the query.

## Contract doc update

New section in `docs/pipeline-contract.md` titled `## Files artifact (files.json)` placed after the `## Type catalog` section, before `## Function catalog`. Documents:

- Wrapper shape (v1.1) and field semantics.
- Opt-in via `--emit-files`.
- Resolver scope (relative paths only).
- Externals captured but un-resolved (raw spec preserved).
- Known v1 limitations: no `tsconfig.json` `paths` aliases, no CommonJS `require()`, no per-specifier type-only granularity.
- Pointer to `cross-package-backward-imports.jq` as the first consumer; the list of forecast consumers (cycle-detection, unused-imports, dependency-mass, graph-view edges).
- Sort key (`entries[]` by `(package, path)`, `imports[]` by `(package, path, kind, line)`).

Update the `## CLI contract` section to include `--emit-files <path>` in the canonical extractor signature.

## README update

Add a row to the query table for `cross-package-backward-imports.jq` describing the layering check and pointing at `files.json` as its input.

## Risks and migration concerns

- **`--emit-files` is opt-in, so no existing run breaks.** Existing audit scripts continue to work byte-identically until they add `--emit-files <path>` to their invocation. The `type-catalog.mjs` exit-on-error semantics are preserved (still exit 1 if no files found).
- **Resolver false negatives on path aliases.** Documented. Mitigation: a v2 resolver that reads `tsconfig.json` `compilerOptions.paths` can land later under a separate ticket without changing the artifact shape.
- **Resolver false negatives on CJS `require()`.** Documented. Modern TS codebases are predominantly ESM; this is unlikely to bite the project the audit targets.
- **Performance.** The extra walk over top-level statements + descendant walk for dynamic-imports is O(file size). On the wxyc case-study tree (319 files), the type-catalog runs in ~2s; the additional work should be <500ms. If profiling shows it's hotter, the dynamic-import descendant walk can be guarded by a regex pre-check (`/import\s*\(/`) on the raw source text.
- **JSON file size.** ~50–150 bytes per import; a 300-file codebase with avg 10 imports/file ≈ 50–150 KB `files.json`. Fits comfortably in git diffs and downstream slurp invocations.

## Sequencing within the PR

Single PR (no chaining needed — the artifact and its first consumer are tightly coupled). Commit grouping:

1. `extractor: emit files.json sibling artifact under --emit-files`
   - `type-catalog.mjs` changes (walker + CLI flag + emission).
   - New unit tests (failing first per TDD).
2. `query: cross-package-backward-imports.jq`
   - Query file with cluster-envelope convention.
   - Integration tests + fixture data.
3. `docs: contract section for files.json artifact + README query row`
   - Self-explanatory.

Total PR delta target: ~700–900 lines (extractor walker ~150, unit tests ~250, query ~50, integration tests + fixture ~250, contract doc ~80, README ~5). Comfortably under the 1000-line guideline in CLAUDE.md.

## Acceptance criteria

- [ ] `type-catalog.mjs --root X --emit-files <path>` writes a valid v1.1-wrapped JSON file.
- [ ] Without `--emit-files`, no `files.json` is written; existing extractor output (and `--emit-references-graph` output) is byte-identical to pre-PR.
- [ ] `cross-package-backward-imports.jq` runs against the emitted `files.json` and reports exactly the planted backward edges in the fixture tree.
- [ ] Self-import / forward-import / extern-only files do NOT appear in the output.
- [ ] All unit tests pass; all new integration tests pass; existing 26 canonical + 115 query integration tests remain green.
- [ ] Contract doc updated to reflect the new artifact and CLI flag.
- [ ] README updated.
- [ ] Cycle-detection is explicitly NOT shipped (per the issue body's recommendation); a one-line follow-up note in the PR body acknowledges this and points at the cycle query as a future ticket.
