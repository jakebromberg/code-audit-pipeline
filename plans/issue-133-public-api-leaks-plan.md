---
issue: 133
title: public-api-leaks.jq + function-kind extraction
---

# Plan — Issue #133: `public-api-leaks.jq` + function signature extraction

## Context

#146 shipped the reference walker (`refsForDecl`, `extractReferences`, the deny-list, the scope-threaded generics filter) inside `extractors/typescript/type-catalog.mjs`. That work is the prerequisite for both #132 (just merged in PR #176) and #133.

#133 needs to surface exported functions whose param or return types reference an un-exported same-package declaration. The query joins **function signatures** with **type-catalog declarations**, which means the substrate needs to start emitting type-resolution data on functions.

**Where the new data lives — function-catalog, not type-catalog.** The contract (`docs/pipeline-contract.md:5-10`) explicitly draws the catalog line:

> - `type-catalog.json` — type / interface / Zod / Drizzle declarations (shape-of-named-members).
> - `function-catalog.json` — function / method / arrow-function declarations (body-of-named-callable).

`function-catalog.mjs` already exists and already extracts `FunctionDeclaration`, `MethodDeclaration`, `ArrowFunction`, `FunctionExpression` — the exact AST nodes #133 needs. Today it emits body-level data (body_hash, body_lines, param_count, param_names) for duplication clustering. #133 extends each row with **signature-level data** (typed params, return ref, outgoing references) so the leak query has something to join against the type catalog.

## Scope

### In scope (v1)

1. **Lift the reference walker** from `type-catalog.mjs` to a shared module `extractors/typescript/_lib/references.mjs`. Both catalogs import from it. Behavior-preserving for type-catalog (single internal refactor).
2. **Extend function-catalog rows** with new fields:
   - `params: [{name, type_ref, type_refs}]` — `type_ref` is the single-identifier ref when the param type is a simple `TypeReferenceNode`; `null` otherwise. `type_refs` is the full deduped set (same shape as the type-catalog's `references`).
   - `return_ref: string | null` — same encoding as `param.type_ref`.
   - `generics: string` — comma-joined type-parameter names, matching type-catalog's convention. Used as the binding-scope filter for `extractReferences`.
   - `references: [{name, kind}]` and `references_count: int` — union of param and return refs, deduped, sorted by name. Same shape as type-catalog's per-row `references`.
   - `is_test: bool`, `touched_in_window: bool`, `synthetic: false` — universal flags missing from function-catalog today. Bring it in line with type-catalog.
3. **Change the min-body-lines filter semantics**: today the filter is row-level (`if (normLines.length < MIN_BODY_LINES) return;` at line 136). Change to **field-level** — always emit the row with signature data, set `body_hash` / `body_lines` / `body_line_count` / `body_length` to `null` when body is below the threshold. This unlocks leak detection on one-liner exported functions, which today are invisible.
4. **Update three function-catalog-consuming queries** (`function-duplicates.jq`, `generic-function-candidates.jq`, `default-impl-candidates.jq`) to add an early `select(.body_hash != null)` filter. Preserves their existing behavior under the new schema.
5. **Wrap function-catalog output to schema v1.1** — `{schema_version: "1.1", extractor: {...}, entries: [...]}` — matching type-catalog. Update the three consumer queries to migrate to the `entries` helper from `_canonical.jq`. (The helper already accepts bare-array v1.0 for back-compat, so the migration is forward-only.)
6. **New `pipeline/queries/public-api-leaks.jq`**: primary input is the wrapped function-catalog; `--slurpfile types type-catalog.json` is required for cross-catalog resolution.
7. **Integration tests** — two-file fixture pair (`public-api-leaks-functions.input.json` + `public-api-leaks-types.input.json`) mirroring dead-code's pattern from PR #176.
8. **Extractor tests** — node:test fixture `21-function-kind.ts` plus assertions for: typed params, return ref, generics binding filter, missing type refs on primitives, anonymous-inline-shape handling, exported vs non-exported, ArrowFunction via `export const f = ...`, FunctionDeclaration, overloaded heads.
9. **Contract update** — Phase 1 deliverable, ahead of any extractor code. Update `docs/pipeline-contract.md`:
   - The `Function catalog` section gains the new field specs (signature/refs/universal-flags), wraps to schema v1.1.
   - The intro list (line 7-10) gets a one-line clarification that function-catalog now carries signature shape in addition to body shape.
10. **README entry** for the new query plus the schema bump note.

### Out of scope (deferred)

- **Overloaded signatures (Open Question Q1 in issue body)**. TS allows N declaration heads with one impl. V1 ships the simplest path: emit one row per head with `signature_index: 0..N`. The query side does NOT yet special-case overloads — leaks on any head fire. Future work: query-side dedupe by `(name, package, file)`. This is in scope because the data shape needs to land now; the consumer logic stays naive.
- **Class methods (Q2)**. `class Foo { method() {} }` already emits as `kind: "method"` from the existing function-catalog extractor — but its export status is governed by the enclosing class, and methods can leak types via the same mechanism as free functions. **V1 query skips `kind: "method"`** rows entirely. Documented limitation; reopens when class-kind work lands.
- **Default exports (Q3)**. `export default function foo() {}` — skip in V1.
- **Anonymous types in params (Q4)**. `function f(x: { a: string })` — V1 emits `params: [{name:"x", type_ref:null, type_refs:[]}]`. Query skips entries where ref list is empty.
- **Class-scope generics binding (Q5)**. Not relevant until methods land.
- **Re-export tracking**. Same v1 false-positive class as #132. Documented inline.

## Schema additions

### Function-catalog row (v1.1)

```jsonc
{
  // ─── existing fields (preserved) ─────────────────────────────────
  "name": "lookupTrack",
  "kind": "function",                  // | "method" | "arrow-function" | "function-expression"
  "package": "main",
  "file": "src/services/lookup.ts",
  "line": 47,
  "generated": false,
  "exported": true,
  "async": false,
  "param_count": 2,
  "param_names": ["input", "options"],

  // body fields — now NULL when normalized body < --min-body-lines (default 3)
  "body_hash": "<sha256>",             // null for one-liners
  "body_line_count": 48,               // null for one-liners
  "body_length": 1500,                 // null for one-liners
  "body_lines": ["…"],                 // null for one-liners

  // ─── new fields ──────────────────────────────────────────────────
  "is_test": false,                    // file-path derived, same convention as type-catalog
  "touched_in_window": false,          // from --touched JSON list (type-catalog parity)
  "synthetic": false,                  // always false on function-catalog rows; reserved for future

  "generics": "T,U",                   // comma-joined; empty string if none

  "params": [
    {
      "name": "input",
      "type_ref": "LookupRequest",     // single ident or null
      "type_refs": [                   // full deduped set (matches type-catalog's references[] shape)
        {"name": "LookupRequest", "kind": "type-ref"}
      ]
    },
    {
      "name": "options",
      "type_ref": "LookupOptions",
      "type_refs": [{"name": "LookupOptions", "kind": "type-ref"}]
    }
  ],

  "return_ref": "LookupResponse",      // single ident or null

  "references": [                       // union of all params[].type_refs + return_ref, sorted by name
    {"name": "LookupOptions",  "kind": "type-ref"},
    {"name": "LookupRequest",  "kind": "type-ref"},
    {"name": "LookupResponse", "kind": "type-ref"}
  ],
  "references_count": 3,

  "signature_index": 0                 // 0 for non-overloaded; >0 for additional overload heads
}
```

### Field-encoding decisions

- **`type_ref` vs `type_refs`**: `type_ref` is sugar for the common case of a simple `TypeReferenceNode`; consumers that just want "what does this param point at" don't need to walk the array. `type_refs` is the full set for richer queries.
- **`null` vs `[]`**: `params[].type_ref` is `null` for non-reference types (primitives, anonymous inline shapes); `params[].type_refs` is `[]` in the same case. `return_ref` is `null` when the return is implicit/inferred or non-reference.
- **`references` at the function level**: sorted-deduped union of all param `type_refs` plus the return ref's identifier (when non-null), generics-bound names filtered out. Same shape as type-catalog's per-row `references[]` so future kind-agnostic queries (like `dead-code.jq`) can treat function rows uniformly.
- **`signature_index`**: lets future overload-aware queries dedupe; non-overload-aware queries ignore it.
- **Universal flags**: `is_test` per the contract's test-path patterns (`tests/`, `__tests__/`, `*.test.ts`, etc.). `touched_in_window` derived from the optional `--touched` JSON file. `synthetic: false` because function-catalog doesn't emit synthetic rows today.

### Schema wrap to v1.1

```jsonc
{
  "schema_version": "1.1",
  "extractor": {
    "language": "typescript",
    "name": "function-catalog",
    "version": "0.5.0"     // bumped from current 0.x
  },
  "entries": [ /* function rows */ ]
}
```

Consumer queries adopt the `entries` helper from `_canonical.jq` (the same migration pattern type-catalog went through in #146). Bare-array v1.0 input continues to work via the helper's back-compat branch.

### Reference walker — shared module

Lift from `type-catalog.mjs` to `extractors/typescript/_lib/references.mjs`. Exports:

- `extractReferences(typeNode, sf, scope, sink)` — recursive walker (current type-catalog implementation).
- `BUILTIN_TYPE_DENYLIST` — the existing denylist.
- `getLeftmostIdentifierText(typeName)` — qualified-name helper.
- `pushNamedRef(...)` — the unified named-ref helper.

`type-catalog.mjs` then imports these instead of defining them locally. Single behavior-preserving refactor commit before the function-catalog work.

`function-catalog.mjs` imports `extractReferences` and `BUILTIN_TYPE_DENYLIST`, calls the walker once per param's `type` AST node (passing the function's generic param names as `scope`), and once on the return type. Per-call output is a `Set`; the function-level `references[]` is the union sorted by name.

## Query semantics

`public-api-leaks.jq` invocation:

```bash
jq -L pipeline/queries -r --slurpfile types type-catalog.json \
  -f pipeline/queries/public-api-leaks.jq function-catalog.json
```

The query:

1. Build a same-package index from `$types[0].entries`: `(.package, .name) → list-of-decls`. Lookup map keyed by `[.package, .name] | tojson` (same encoding as #132).
2. Walk function-catalog entries:
   - Skip rows where `(.synthetic // false) == true`, `.exported != true`, `(.generated // false) == true`, or `(.kind // "") == "method"` (deferred per scope).
3. For each surviving function:
   - For each `param.type_ref` (when non-null) and the `return_ref` (when non-null):
     - Look up the SAME-PACKAGE decl by name in the type index.
     - If any match has `.exported == false` AND `(.generated // false) != true`, record a leak: `{kind: "param" | "return", param_name, ref_name, decl_package, decl_file, decl_line}`.
4. Emit one row per offending function — only when `leaks` is non-empty.
5. Sort by `(.package, .file, .line, .name)`.

### Output format

**Text:**
```
LEAK lookupTrack (main:src/services/lookup.ts:47) — exported
  return: LookupResponse — declared at main:src/lookup/types.ts:12 (not exported)
  param `input`: LookupRequest — declared at main:src/lookup/types.ts:5 (not exported)
cid=public-api-leaks:main:src/services/lookup.ts:47:lookupTrack
```

**JSONL:**
```jsonc
{"cluster_id":"public-api-leaks:main:src/services/lookup.ts:47:lookupTrack","query":"public-api-leaks","name":"lookupTrack","package":"main","file":"src/services/lookup.ts","line":47,"touched_in_window":false,"leaks":[{"kind":"param","param_name":"input","ref_name":"LookupRequest","decl_package":"main","decl_file":"src/lookup/types.ts","decl_line":5},{"kind":"return","param_name":null,"ref_name":"LookupResponse","decl_package":"main","decl_file":"src/lookup/types.ts","decl_line":12}]}
```

`cluster_id` format: `public-api-leaks:<package>:<file>:<line>:<name>` (per-decl `loc_key`, matching `orphan-infer-model.jq` and `dead-code.jq`).

## Test plan

### Extractor tests (node:test)

New fixture `extractors/typescript/fixtures/21-function-signatures.ts`:

```ts
// Primitives only — no refs to extract
export function noLeakPrimitives(s: string, n: number): boolean { return n > 0; }

// Typed param + typed return
type InternalRequest = { id: string };
export type PublicResponse = { ok: boolean };
export function leakyHandler(req: InternalRequest): PublicResponse {
  return { ok: req.id.length > 0 };
}

// Arrow function via `export const`
export const boxArrow = <T>(value: T): { wrapped: T } => ({ wrapped: value });

// Non-exported
function privateHelper(x: number): number { return x; }

// Generics — T must NOT appear in references[]
export function identity<T>(value: T): T { return value; }

// Overloaded
export function overloaded(x: string): string;
export function overloaded(x: number): number;
export function overloaded(x: string | number): string | number { return x; }
```

Assertions:

1. Six function rows emitted (4 simple + 2 overload-heads + 1 overload-impl + 1 arrow = the exact count depends on how the existing function-catalog already counts these; verify with a smoke run first and assert the deltas).
2. `noLeakPrimitives.params` = `[{name:"s", type_ref:null, type_refs:[]}, {name:"n", type_ref:null, type_refs:[]}]`.
3. `noLeakPrimitives.return_ref` = `null`.
4. `leakyHandler.params[0]` = `{name:"req", type_ref:"InternalRequest", type_refs:[{name:"InternalRequest", kind:"type-ref"}]}`.
5. `leakyHandler.return_ref` = `"PublicResponse"`.
6. `leakyHandler.references` (sorted, deduped) = `[{name:"InternalRequest", kind:"type-ref"}, {name:"PublicResponse", kind:"type-ref"}]`.
7. `boxArrow.exported` = true, `boxArrow.generics` = `"T"`.
8. `boxArrow.params[0].type_refs` is `[]` (T filtered as generic binding).
9. `boxArrow.return_ref` = null (inline `{ wrapped: T }` is anonymous, not a single ref).
10. `privateHelper.exported` = false.
11. `identity.params[0].type_refs` = `[]` AND `identity.return_ref` = null AND `identity.references` = `[]` (everything filtered).
12. Overloaded heads get `signature_index` 0/1/2. Refined assertions to catch off-by-one and head-vs-impl confusion: (a) exactly 3 rows for name `overloaded`, (b) the sum of `signature_index` across them is `0 + 1 + 2 == 3`, (c) exactly one of the three has a non-null `body_hash` (the impl head), (d) the other two have `body_hash == null` (the declaration heads have no body).
13. **Body-fields gating**: `noLeakPrimitives` has a 1-line body (under default `min-body-lines=3`) — assert `body_hash == null && body_lines == null`. `leakyHandler` has a multi-line body — assert `body_hash != null && body_lines != null && body_lines | length >= 1`.
14. **Schema wrapper**: parse output as `{schema_version, extractor, entries}`. Assert `schema_version == "1.1"` and `extractor.name == "function-catalog"`.

### Integration tests (`pipeline/queries/_tests/test_queries_integration.sh`)

Two new fixture files:

- `pipeline/queries/_tests/fixtures/public-api-leaks-functions.input.json` — wrapped function-catalog with 8 planted functions.
- `pipeline/queries/_tests/fixtures/public-api-leaks-types.input.json` — wrapped type-catalog with the 6 type decls the functions reference.

Planted cases (functions side):

| Function | Expected verdict | Reason |
|---|---|---|
| `main:cleanFn` (exported, params/return all exported types) | no leak | base clean |
| `main:leakyParam` (exported, param `InternalReq` unexported) | **flag**: param leak | core positive |
| `main:leakyReturn` (exported, returns `InternalResp` unexported) | **flag**: return leak | core positive |
| `main:leakyBoth` (exported, both un-exported) | **flag**: 2-leak row | combined case |
| `main:nonExportedFn` (NOT exported, refs un-exported types) | no leak | non-exported caller |
| `main:genericFn` (exported, all refs are generic bindings) | no leak | binding filter |
| `main:crossPkgClean` (exported, refs `shared:CommonType` exported) | no leak | cross-pkg, target is exported |
| `main:anonymousParam` (exported, `type_ref: null`) | no leak | skipped (no ref to check) |
| `main:leakyMethodSkipped` (`kind:"method"`, exported, references un-exported `InternalReq`) | no leak | v1 query skips methods — paired with `main:leakyFunctionVerifies` below, the absence of a leak row for the method (despite identical leaky type) proves the skip is *query-side*, not vacuous |
| `main:leakyFunctionVerifies` (`kind:"function"`, exported, references the SAME `InternalReq`) | **flag**: param leak | confirms the type-resolution would have caught the method too if not for the kind skip |

Three new assertions in the harness (following dead-code's pattern from PR #176):

1. `assert_jsonl_has_prefix public-api-leaks.jq "$LEAKS_FUNCTIONS_FIXTURE" "public-api-leaks:" --slurpfile types "$LEAKS_TYPES_FIXTURE"`.
2. `assert_public_api_leaks_baseline` — new helper. Runs query, asserts exactly 4 leak rows emitted (leakyParam, leakyReturn, leakyBoth, leakyFunctionVerifies), asserts the row set matches the expected `(package, name)` tuple set. The absence of `leakyMethodSkipped` from the output (despite its identical leaky type) confirms the kind-skip is firing.
3. `assert_text_has_cid public-api-leaks.jq "$LEAKS_FUNCTIONS_FIXTURE" --slurpfile types "$LEAKS_TYPES_FIXTURE"`.
4. End-to-end smoke `assert_public_api_leaks_e2e_extractor`: runs the live extractor over `21-function-signatures.ts`, runs the query against the resulting catalog pair, asserts at least one leak fired (the `leakyHandler` from the fixture).

The helper extension: `assert_jsonl_has_prefix` already forwards `extra_args[]` through to jq, so `--slurpfile types ...` rides through with no helper-signature changes — same trick dead-code used.

## Implementation phases

Phases are sequenced commits, rebased before push:

1. **Contract update (Phase 1, ahead of code)**: write the function-catalog v1.1 schema spec into `docs/pipeline-contract.md`. Reviewers can read the contract before reviewing extractor code.
2. **Refactor — lift reference walker**: extract `extractReferences`, `BUILTIN_TYPE_DENYLIST`, `getLeftmostIdentifierText`, `pushNamedRef` to `extractors/typescript/_lib/references.mjs`. Update `type-catalog.mjs` to import. Run existing type-catalog tests — must be 27/27 green (behavior-preserving).
3. **Extractor — TDD red**: add `21-function-signatures.ts` + assertions in `extract.test.mjs`. Run — verify they fail.
4. **Extractor — green**: extend function-catalog.mjs. Add signature extraction, universal flags, body-fields gating, v1.1 wrapper (same `{schema_version, extractor, entries}` shape as type-catalog at `extractors/typescript/type-catalog.mjs:18-65` — the wrapping happens at the final `JSON.stringify` site, currently at function-catalog.mjs:267 emitting a bare array). Run extractor tests — verify they pass. Re-run type-catalog tests — must still pass.
5. **Update consumer queries**: function-duplicates.jq, generic-function-candidates.jq, default-impl-candidates.jq — migrate to `entries` helper + add `select(.body_hash != null)`. Run integration tests — verify no regressions.
6. **Query — TDD red**: add fixture pair + integration tests for public-api-leaks. Run — verify they fail (query missing).
7. **Query — green**: write `pipeline/queries/public-api-leaks.jq`. Run integration tests — verify all green.
8. **README + contract polish**: README entry + any contract clarifications missed in Phase 1.
9. **CI sanity**: shellcheck, all test suites.
10. **PR**: rebase against origin/main → PR with `Closes #133`.

## Risks

- **Function-catalog v1.1 wrap is a real schema bump**. Three consumer queries need updating. Any out-of-tree consumer (none known) would break — but the project doesn't have stable external consumers yet, so acceptable.
- **Behavior change: rows for short functions now appear with null body fields**. The three consumer queries gain a `select(.body_hash != null)` early filter — preserves their behavior. The dead-code query (#132) will naturally pick up short exported functions as candidates for dead-code analysis, which is a new but correct emission.
- **Reference walker lift is a non-trivial refactor**. ~200 LoC moves from type-catalog to the new shared module. Mitigated by being commit-bounded (Phase 2) and behavior-preserving (existing type-catalog tests must stay 27/27 green).
- **The PR is larger than #132 (~340 LoC)**. Estimated ~550 LoC. Still under the 1000-LoC guideline in CLAUDE.md. Split into PRs only if reviewers push back during review-loop.

## Reviewer responses (from /review-plan round 1)

- **High #1 — function-catalog vs type-catalog**: accepted. Plan revised to extend function-catalog, with the shared reference walker lifted to `_lib/references.mjs`.
- **High #2 — contract update placement**: accepted. Contract update is now Phase 1, ahead of any extractor code.
- **High #3 — hybrid fixture clarification**: accepted via the two-file fixture approach (mirroring dead-code.jq from PR #176). Functions and types live in separate files; query joins via `--slurpfile types`. Avoids the hybrid catalog antipattern.
- **Medium #4 — extractReferences reuse strategy**: addressed in the "Reference walker — shared module" section above (lift to `_lib/`, function-catalog calls per-param, generics-bound names filtered via `scope` argument).
- **Medium #5 — test harness integration point**: addressed in the "Integration tests" section above with exact assertion-function names.
- **Low #6 — README entry text**: addressed below.

### README entry (verbatim)

```
| `public-api-leaks.jq` | Exported functions whose param or return types reference non-exported same-package types — likely API leaks. Joins function-catalog primary with `--slurpfile types type-catalog.json`. V1 skips `kind: "method"` rows (re-enables when class-kind work lands) | function, type |
```
