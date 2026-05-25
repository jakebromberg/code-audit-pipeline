# B — Imports kind: emit consumer-edge rows in the TypeScript catalog

**Parent:** [#118 — Cross-repo queries — merging N catalogs across the org](https://github.com/jakebromberg/code-audit-pipeline/issues/118).
**Blocked by:** [A — Schema v2](118-A-schema-v2.md) (needs `repo`, `commit_sha`, `origin_package` fields).
**Blocks:** F1, F3.

## 1. Context summary

**What an import row is.** A row in the catalog representing one *consumer-side reference* to a symbol — the dual of a declaration row. Where a declaration row says "this is where `DiscogsTrack` is defined," an import row says "this file consumes the name `DiscogsTrack` from `@wxyc/shared` here." Today's catalog stores only the former.

**Why declarations-only is insufficient for cross-repo queries.** Parent issue #118 is explicit: Q1 ("which repos consume `@wxyc/shared`?") and Q3 ("repo A renamed X — which repos still depend on the old name?") cannot be answered from declarations alone. Both queries require an edge from a consumer site to a published-package symbol name. The case study's "Pure missed imports" finding (`docs/case-study.md`, "DiscogsTrackItem" section) and the dj-site experiment's HIGH-severity findings ("FlowsheetEntry duplicates shared dtos," "JSONDates is a no-op adapter") are the within-repo precursors of exactly this pattern. The cross-package-shadows query catches *redeclarations* that the author should have imported; an imports kind also catches *consumers of the canonical declaration*, which is the inverse signal — "this published export has 14 consumers across 7 repos, here's where each one lives."

**(a) one-stream vs (b) sidecar — firm recommendation: (a) one stream.** Rationale:

1. **Homogeneous queries.** A single catalog stream means `jq -s 'map(.entries) | add'` produces one query surface. Sidecar `imports.json` files would force every cluster query to take two inputs or do a pre-merge step.
2. **`kind` already discriminates.** Existing queries filter on `.kind` (see `cross-package-shadows.jq:16`: `select(.kind | startswith("type-alias") or . == "interface" or . == "zod-object")`); they will silently ignore `kind: "import"` rows without modification. Adding a sidecar gains nothing for separability that `kind` doesn't already give us.
3. **Forward-compatibility with #118's schema-additions block.** Parent #118 proposes `repo`, `commit_sha`, `extractor`, `origin_package`, `imports` as schema deltas. All of them are per-row fields. Putting imports in the same stream means they inherit `repo` / `commit_sha` / `extractor` for free; a sidecar would need its own copies of all four.
4. **Symmetry with Python and Swift design notes.** `docs/python-extractor-design-notes.md` (File 6) already sketches `kind: "external-import"` in the main stream; Swift `import X.Y` is the same shape. Doing one-stream in TS keeps the contract consistent across languages.

**Relation to the `--shared`/`package` two-root convention.** Today `package: "main" | "shared"` distinguishes which root produced a row. This is intra-repo (one repo with two workspaces). The new `origin_package` field on import rows is *cross-repo* — it names the published npm package (`@wxyc/shared`) that the import refers to. The two fields are orthogonal: `package` is "which workspace did the *file* live in"; `origin_package` is "which published package does the *symbol* come from." A consumer in `wxyc/dj-site` would have `package: "main"` and `origin_package: "@wxyc/shared"` on the import row. The cross-package-shadows query stays intra-repo; consumers-of (F1) is cross-repo.

## 2. Functional requirements — import row schema

### Base shape

```jsonc
{
  "name": "DiscogsTrack",                    // the symbol being imported (consumer-side spelling)
  "kind": "import",                          // new top-level kind
  "package": "main",                         // existing field — which root the FILE belongs to
  "file": "src/services/lookup.ts",          // consumer's file
  "line": 3,                                 // 1-indexed line of the import statement
  "exported": false,                         // imports are not "exported"; always false
  "generated": false,                        // inherits the file's generated status

  // New fields for imports:
  "origin_package": "@wxyc/shared",          // resolved published-package name, or null if local
  "origin_specifier": "@wxyc/shared",        // raw import specifier as written
  "origin_resolution": "bare-specifier",     // see resolution algorithm below
  "import_form": "named",                    // see below
  "imported_as": "DiscogsTrack",             // local alias (== name if no `as` clause)
  "type_only": false,                        // true for `import type { ... }` or `import { type ... }`

  "touched_in_window": false                 // inherits the file's touched flag
}
```

### Required fields for `kind: "import"`

- `name` (the symbol the consumer references — already required by contract; `null` for side-effect imports)
- `kind: "import"`
- `package`, `file`, `line` (already required by contract)
- `origin_specifier` (raw text from the source)
- `origin_package` (resolved; may be `null` if resolution can't lift the specifier to a published name)
- `import_form` (one of: `named`, `default`, `namespace`, `side-effect`, `re-export`, `dynamic`, `require`)
- `imported_as` (always populated; equals `name` when no alias)
- `type_only` (boolean)

### Not applicable to imports

- `fields`, `shape_sig`, `type_text`, `type_sig`, `generics`, `infer_ref`, `db_table_name`, `exported` (always false, but emit for shape uniformity)

### Worked examples by import form

**Named import:** `import { DiscogsTrack, type DiscogsAlbum } from "@wxyc/shared";` → **two rows**, one per symbol:

```jsonc
{ "name": "DiscogsTrack", "kind": "import", "import_form": "named", "imported_as": "DiscogsTrack",
  "origin_specifier": "@wxyc/shared", "origin_package": "@wxyc/shared", "type_only": false, ... }
{ "name": "DiscogsAlbum", "kind": "import", "import_form": "named", "imported_as": "DiscogsAlbum",
  "origin_specifier": "@wxyc/shared", "origin_package": "@wxyc/shared", "type_only": true, ... }
```

**Named with alias:** `import { DiscogsTrack as Track } from "@wxyc/shared";`

```jsonc
{ "name": "DiscogsTrack", "kind": "import", "import_form": "named", "imported_as": "Track", ... }
```

The `name` is the *origin-package side* spelling (queryable against declarations); `imported_as` is the local-side spelling.

**Default import:** `import shared from "@wxyc/shared";`

```jsonc
{ "name": "default", "kind": "import", "import_form": "default", "imported_as": "shared",
  "origin_specifier": "@wxyc/shared", "origin_package": "@wxyc/shared", ... }
```

**Namespace import:** `import * as shared from "@wxyc/shared";`

```jsonc
{ "name": "*", "kind": "import", "import_form": "namespace", "imported_as": "shared", ... }
```

**Type-only import:** `import type { DiscogsTrack } from "@wxyc/shared";`

```jsonc
{ "name": "DiscogsTrack", "kind": "import", "import_form": "named", "type_only": true, ... }
```

**Side-effect import:** `import "@wxyc/shared/polyfills";`

```jsonc
{ "name": null, "kind": "import", "import_form": "side-effect",
  "origin_specifier": "@wxyc/shared/polyfills", "origin_package": "@wxyc/shared", ... }
```

(`name: null` is the one exception to the otherwise-always-populated `name` field; queries that group by `.name` need to filter `select(.name != null)`.)

**Re-export:** `export { DiscogsTrack } from "@wxyc/shared";` — treated as an `import` row with `import_form: "re-export"`. The re-exporting file's symbol becomes a consumer-side reference to the origin.

```jsonc
{ "name": "DiscogsTrack", "kind": "import", "import_form": "re-export",
  "imported_as": "DiscogsTrack", "origin_specifier": "@wxyc/shared", "origin_package": "@wxyc/shared", ... }
```

**Dynamic import:** `const m = await import("@wxyc/shared");`

```jsonc
{ "name": "*", "kind": "import", "import_form": "dynamic",
  "origin_specifier": "@wxyc/shared", "origin_package": "@wxyc/shared", ... }
```

V1 captures dynamic imports only when the specifier is a string literal; template-literal specifiers (`` import(`./locales/${lang}`) ``) record `origin_specifier: "<computed>"`, `origin_package: null`, and an `omitted_features: ["computed_specifier"]` marker.

**`require()`:** `const x = require("@wxyc/shared");`

V1 records as `import_form: "require"` when the call is a top-level or module-level `require` with a string-literal argument. Destructuring is recovered (`const { foo } = require(...)` → one row per destructured name with `import_form: "require"`). Non-trivial `require` patterns (computed args, conditional requires) are skipped in v1.

### `origin_package` resolution algorithm

**Two-tier — try the easy heuristic first, fall back to tsconfig+package.json walking only if needed.**

**Tier 1 — bare-specifier heuristic (v1):**

- If `origin_specifier` does **not** start with `.` or `/`, treat it as a bare package specifier. Strip subpath: `@wxyc/shared/dtos/lookup` → `@wxyc/shared`; `lodash/fp` → `lodash`; `foo` → `foo`. Handle the `@scope/name` prefix.
- Set `origin_package = <bare-package>`, `origin_resolution = "bare-specifier"`.
- If `origin_specifier` starts with `.` or `/`, set `origin_package = null`, `origin_resolution = "relative"`. These are intra-repo imports — not the Q1 target.

This catches ≥95% of cross-repo consumer-edges in well-behaved npm codebases. It's deterministic, fast, and requires zero filesystem reads beyond the source file itself.

**Tier 2 — tsconfig path mapping (v2 or behind a flag):**

- Parse the nearest `tsconfig.json` (walking up from the source file's directory) and its `compilerOptions.paths`. A `paths` entry like `"@wxyc/shared/*": ["../shared/src/*"]` means `@wxyc/shared/foo` actually resolves to a sibling-path file, not a published package.
- For relative specifiers, walk up to the nearest `package.json` of the *target* and read its `name` field.

**v1 ships Tier 1 only.** The two-root `--shared` convention already covers the in-repo case. The cross-repo case is exactly where Tier 1 wins: 30 sibling repos importing from `"@wxyc/shared"` will all have bare specifiers. Tier 2 is only needed for monorepos that use relative paths into sibling workspaces — and those are already covered by the existing `--shared` convention. Defer Tier 2 until a real query demands it.

## 3. Non-functional requirements

**Catalog growth.** Imports are common — typical TS files have 5-15 import statements with 1-4 symbols each. Sampling the case-study repo (595 declarations across 319 files ≈ 1.9 decls/file) suggests imports will outnumber declarations 4-8×. Expect `kind: "import"` to dominate catalog rows. For dj-site (140 declarations, 123 files), import rows likely land in the 800-1500 range. For 30-repo cross-org merge: ~10k declarations + ~50-80k import rows = ~60-90k total rows. Still well within jq's comfort zone per #118's "30k rows is fine in jq" estimate, but it does push self-join near-duplicate queries closer to the SQLite threshold #118 calls out.

**Extractor pass cost.** Adding import visitors is O(1) per file relative to the existing declaration walk — both run inside the same `ts.forEachChild` traversal. The AST already exposes `ImportDeclaration` nodes; no second pass is needed. Expect <10% wall-clock increase on the existing 2-second case-study runtime.

**Filter-out for legacy queries.** Critical guarantee: **existing queries must produce identical output before and after import rows land.** This is enforced by `kind`-based filtering:

- `exact-duplicates.jq:8` filters on `select(.shape_sig != null and .shape_sig != "")` — import rows have no `shape_sig` and are naturally excluded.
- `name-collisions.jq:9` groups by `.name`. Import rows would inflate clusters if not filtered. **Action item:** add `select(.kind != "import")` at the top of `name-collisions.jq` as part of this PR. Alternative: queries opt in by listing accepted kinds (the cross-package-shadows pattern at line 16). The latter is more robust.
- `cross-package-shadows.jq:16` already explicitly lists accepted kinds (`type-alias-*`, `interface`, `zod-object`). Import rows are naturally excluded.
- `near-duplicates.jq:12` filters on `.fields and (.fields | length) >= 3`. Import rows have no `fields`. Naturally excluded.

**Audit before merge:** confirm by running existing queries on a catalog with and without import rows and `diff`ing output.

## 4. KPIs

1. **Recall ≥ 95% of static imports.** Measured as: count of import statements found by `git grep -E '^(import|export.*from)' --include="*.ts" --include="*.mts"` in `wxyc/dj-site` × symbol count per statement, vs. count of `kind: "import"` rows emitted by the extractor (excluding dynamic, computed-specifier, and non-top-level forms). Target: ≥95% of static, single-line imports captured.
2. **`origin_package` resolution accuracy ≥ 99% for bare specifiers** in a curated fixture set.
3. **F1 (consumers-of) returns a plausible list for `@wxyc/shared` exports.** Acceptance: top three consumers for `DiscogsTrack`, `FlowsheetEntry`, and `WXYCRole` appear with correct file:line citations.
4. **Zero regression in existing query output.** `diff` between pre-imports and post-imports catalog query output is empty across all four existing queries.
5. **Wall-clock budget.** Extractor runtime on the case-study repo (319 files) does not exceed 110% of pre-imports baseline. Target: <2.5s total.
6. **No parse errors introduced.** The case-study run had zero parse errors. Post-imports run must also have zero parse errors.

## 5. Testing strategy

### Synthetic fixtures

Add `extractors/typescript/test-fixtures/imports/` with one `.ts` file per import form:

- `named.ts` — `import { A, B as C } from "pkg";`
- `default.ts` — `import D from "pkg";`
- `namespace.ts` — `import * as ns from "pkg";`
- `type-only.ts` — `import type { T } from "pkg";` and `import { type T2 } from "pkg";`
- `side-effect.ts` — `import "pkg/polyfills";`
- `reexport.ts` — `export { A } from "pkg"; export * from "other";`
- `dynamic.ts` — `await import("pkg");` and template-literal variants.
- `require.ts` — `const x = require("pkg"); const { y } = require("pkg2");`
- `relative.ts` — `import { A } from "./local"; import { B } from "../sibling/foo";` (verifies `origin_package: null`)
- `mixed.ts` — multiple forms in one file.

### Golden catalogs

For each fixture, commit an `expected.json` snapshot. The test harness runs the extractor on each fixture and diffs against the golden. Snapshots make schema regressions visible in PR diffs.

### Resolution algorithm tested separately

Unit-test the bare-specifier stripper as a pure function: input `("@wxyc/shared/dtos/lookup")` → output `"@wxyc/shared"`, etc. Twenty test cases covering scoped packages, deep subpaths, hyphens, dots, leading-dot specifiers (returns `null`).

### Real-codebase validation

Run on `wxyc/dj-site` and `wxyc/wxyc-shared`. Verify:

- The cold-agent findings from the dj-site experiment now have import-row evidence: dj-site's `kind: "import"` rows where `origin_package == "@wxyc/shared"` and `name in {"FlowsheetEntry", "JSONDates", "AlbumSearchResult"}`.
- Cross-check via `git grep '^import.*from "@wxyc/shared"'` count vs. extractor row count.

## 6. Implementation recommendations

### Extractor changes — specific to `type-catalog.mjs`

The existing `visit(node)` function (lines 181-269) handles `ts.isInterfaceDeclaration`, `ts.isTypeAliasDeclaration`, and `ts.isVariableStatement`. Add three new sibling branches inside `visit`:

**1. `ts.isImportDeclaration(node)` — covers static `import` statements.**

- `node.moduleSpecifier.text` is the raw specifier string.
- `node.importClause` walks the clause:
  - `importClause.name` → default import.
  - `importClause.namedBindings` → either `ts.NamespaceImport` (`* as ns`) or `ts.NamedImports` (`{ a, b as c }`).
  - `importClause.isTypeOnly` → file-level type-only flag.
  - Each `ImportSpecifier.isTypeOnly` → per-symbol type-only flag.
- Side-effect imports have no `importClause`.
- For each symbol (or one row for default/namespace/side-effect), call `pushBase(node, { kind: "import", ... })`. Reuse the existing `pushBase` helper at line 169 so file/line/package/touched_in_window come for free.

**2. `ts.isExportDeclaration(node)` with `node.moduleSpecifier` present — covers `export { X } from "pkg";` re-exports.**

- Same treatment as `ImportDeclaration` with `import_form: "re-export"`.
- Star re-exports (`export * from "pkg";`) → one row with `name: "*"`, `import_form: "re-export"`.

**3. `ts.isCallExpression(node)` for dynamic `import()` and `require()`.**

- Dynamic imports: `node.expression.kind === ts.SyntaxKind.ImportKeyword` (TS represents `import()` as a CallExpression with the `ImportKeyword` callee).
- `require()`: `ts.isIdentifier(node.expression) && node.expression.text === "require"`. Walk parent assignments to recover destructured names.
- Both have a single argument; check `ts.isStringLiteral` and emit; otherwise emit with `origin_specifier: "<computed>"`.

The existing `ts.forEachChild(node, visit)` recursion at line 269 will already reach these nodes at the appropriate depth.

### Resolution helper

```javascript
function resolveOriginPackage(specifier) {
  if (specifier.startsWith('.') || specifier.startsWith('/')) {
    return { origin_package: null, origin_resolution: 'relative' };
  }
  const parts = specifier.split('/');
  const pkg = specifier.startsWith('@') ? `${parts[0]}/${parts[1]}` : parts[0];
  return { origin_package: pkg, origin_resolution: 'bare-specifier' };
}
```

### CLI flag

**Gate v1 behind `--include-imports` initially.** Rationale:

- The current extractor's contract is declarations-only; tools and consumers built against it may parse the catalog with assumptions about row volume or kind shape.
- A flag lets early adopters opt in while the schema settles.
- Default-on can ship in a follow-up PR once cross-repo queries are exercising the data.

**Flip default-on in a second PR** after the F1 query lands and proves the data shape works.

### PR scoping

**Two PRs, sequential:**

1. **PR 1 — schema + extractor + flag + tests.** Adds `kind: "import"` rows behind `--include-imports`. Includes synthetic fixtures + golden catalogs. Updates `pipeline-contract.md` with the new `kind` and field set. No query changes (existing queries already filter on `kind` correctly; only `name-collisions.jq` needs the explicit `select(.kind != "import")` guard, included here).
2. **PR 2 — F1 consumers-of.jq query.** Adds the first consuming query, once schema is in. Demonstrates the data shape works on a merged catalog from 2-3 real repos.

Both PRs should be under the 1000-line target.

## 7. Cross-language contract

### Python (stdlib `ast`)

- `ast.Import` (e.g., `import os`, `import numpy as np`):
  - One row per name: `{ name: "os", import_form: "namespace", imported_as: "os", origin_specifier: "os", origin_package: "os" }`.
  - The `import_form` for plain `import x` is conceptually `namespace`; for `from x import y` it's `named`.
- `ast.ImportFrom` (e.g., `from pydantic import BaseModel`):
  - One row per imported symbol with `import_form: "named"`.
  - `node.module` (string) → `origin_specifier` and (after bare-specifier resolution) `origin_package`.
  - Relative imports (`from .foo import bar`, `node.level > 0`) → `origin_package: null`, `origin_resolution: "relative"`.

### Swift (SwiftSyntax)

- `ImportDeclSyntax`:
  - `import Foundation` → `{ name: "Foundation", import_form: "module", origin_specifier: "Foundation", origin_package: "Foundation" }`.
  - `import struct Foundation.Date` (selective) → adds `import_kind_specifier: "struct"` to `language_data.swift.*`; `name: "Date"`, `origin_package: "Foundation"`.

Swift imports don't have named/default/namespace distinctions like JS; the catalog should accept `import_form: "module"` for Swift's case. The shared contract is the union of valid `import_form` values: `{ named, default, namespace, side-effect, re-export, dynamic, require, module }`.

### Shared contract guarantee

All three languages emit rows with: `name`, `import_form`, `origin_specifier`, `origin_package`, `imported_as`. Per-language quirks live in either top-level optional fields (when shared) or `language_data.<lang>.*` (when truly per-language).

## 8. Open questions / decisions still needed

1. **Should re-exports also generate a declaration row in the re-exporting file?** Currently a re-export only generates an import row. But `export { DiscogsTrack } from "@wxyc/shared";` arguably "creates" a `DiscogsTrack` symbol in the re-exporting module. Defer to evidence — handle as import-only in v1.
2. **Should the extractor walk subpaths for resolution?** `import { Foo } from "@wxyc/shared/dtos/lookup"` — does F1 want `origin_package: "@wxyc/shared"` (broad) or `origin_package: "@wxyc/shared/dtos/lookup"` (precise)? Recommend strip-to-bare for v1; add a separate `origin_subpath` field if precision is needed later.
3. **`name: null` for side-effect imports** breaks the otherwise-invariant that every row has a non-null `name`. Acceptable, but queries that group by `.name` need a `select(.name != null)` guard. Document this in the contract.
4. **Computed and dynamic specifiers** — record opaquely with `origin_specifier: "<computed>"`, or skip entirely? Record with marker; missing-data is worse than partial-data for audit reports.
5. **Should `kind: "import"` rows have `exported: false` or omit the field?** Always emit `exported: false` for shape uniformity.
6. **Cluster-query guard policy:** should every existing query gain `select(.kind != "import")` defensively, or rely on `kind`-positive filters? Recommend the latter — positive filters are more robust to future kind additions. Convert `name-collisions.jq` to use positive filtering as part of this PR.
7. **Tier 2 resolution (tsconfig paths / package.json walking)** — gate behind a flag, or omit entirely from v1? Omit; revisit when a query demonstrably needs it.

## 9. Sub-ticket boilerplate

**Title:** `Imports kind: emit consumer-edge rows in the TypeScript catalog`

**Direction:**

> The catalog today records declarations only, which means cross-repo queries Q1 (consumers-of `@wxyc/shared`) and Q3 (rename + stale-consumer detection) cannot be answered. This sub-issue adds `kind: "import"` rows to the TypeScript extractor — one row per imported symbol, with `origin_package` resolved from the bare specifier and `import_form` discriminating named / default / namespace / type-only / side-effect / re-export / dynamic / require. Resolution algorithm is bare-specifier-only in v1 (covers ≥95% of cross-repo cases without tsconfig parsing); ships behind `--include-imports` until the data shape is exercised by the consumers-of query. Existing cluster queries are unaffected because they already filter on `.kind`; `name-collisions.jq` gets a defensive guard added in the same PR. The schema generalizes cleanly to Python (`ast.Import` / `ast.ImportFrom`) and Swift (`ImportDeclSyntax`) so the cross-language extractor work in #115 inherits a ratified contract for consumer-edges.

## Key file references

- [`/Users/jake/Developer/code-audit-pipeline/extractors/typescript/type-catalog.mjs`](../../extractors/typescript/type-catalog.mjs) (lines 181-272: visit function where new branches land; line 169: `pushBase` helper to reuse)
- [`/Users/jake/Developer/code-audit-pipeline/docs/pipeline-contract.md`](../pipeline-contract.md) (catalog schema; needs the new kind entry and import-row field documentation)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/name-collisions.jq:9`](../../pipeline/queries/name-collisions.jq) (needs `select(.kind != "import")` guard or positive `.kind` filter)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/cross-package-shadows.jq:16`](../../pipeline/queries/cross-package-shadows.jq) (positive-filter pattern to mirror)
- [`/Users/jake/Developer/code-audit-pipeline/docs/case-study.md`](../case-study.md) ("Pure missed imports" section: motivating `DiscogsTrackItem` finding)
- [`/Users/jake/Developer/code-audit-pipeline/docs/dj-site-divergence-experiment.md`](../dj-site-divergence-experiment.md) (lines 49-62: cold-agent HIGH findings that imports-kind makes mechanical)
- [`/Users/jake/Developer/code-audit-pipeline/docs/python-extractor-design-notes.md`](../python-extractor-design-notes.md) (File 6: Python's `kind: "external-import"` sketch this brief aligns with)
- [`/Users/jake/Developer/code-audit-pipeline/docs/swift-extractor-design-notes.md`](../swift-extractor-design-notes.md) (Swift `ImportDeclSyntax` design surface for cross-language compatibility)
