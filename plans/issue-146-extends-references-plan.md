# Plan: TS extractor `extends` + `references` edges + schema v1.1 (#146)

## 1. Scope

Extend `extractors/typescript/type-catalog.mjs` to emit two new per-declaration fields — `extends: [string]` and `references: [{name, kind: "type-ref"}]` — and bump the catalog top-level to `{schema_version: "1.1", extractor, entries: [...]}`. Ship a `--emit-references-graph <path>` flag that writes a sibling `references.json` keyed by `(package, name)`. Update `pipeline-contract.md`, `_canonical.jq`, and every consumer query for the wrapper migration.

**Boundary** (from #146 §1, §10): TS only; the renderer (#147), consumer queries that build on these edges (#132 dead-code, #133 public-API-leaks), and other-language extractors (#115) are explicitly out. We own the schema bump itself, in coordination with #117.

## 2. Why

#146 is the canonical successor of #131 (closed NOT_PLANNED). Two independent design memos arrived at the same requirement: #119 (Phase 4a of its graph-view build plan) and #116 (Schema additions roadmap item #2). The `extends` / `references` triplet unlocks three downstream consumers — #132 (dead-code), #133 (public-API-leaks), and #147 (graph view sub-issue) — clearing the project's load-bearing "every schema addition justified by ≥2 downstream queries" rule on its own.

Tactically: shipping this clears the largest remaining piece of #116's tracker. After it lands, #132 and #133 unblock and can ship in any order.

## 3. Files map

| Path | Change | Approx size |
|---|---|---|
| `extractors/typescript/type-catalog.mjs` | Add `BUILTIN_TYPE_DENYLIST`, `extractReferences()`, `extractExtends()`, `getNameFromTypeReference()`; thread scope through interface + type-alias + synthetic-inline branches; wrap output in `{schema_version, extractor, entries}`; add `--emit-references-graph` flag with post-pass edge builder | +200–250 LoC |
| `extractors/typescript/package.json` | Bump `version` 0.1.0 → 0.4.0 to match `schema_version` 1.1. Project is in major-version-zero (`0.x.y`), so a minor bump signals an additive, non-breaking extractor change — every downstream consumer continues to read the catalog after re-extraction. | 1 line |
| `extractors/typescript/fixtures/01..20-*.ts` | 20 fixture files, one per TS feature exercised (§7 below) | ~20 × ≤30 LoC |
| `extractors/typescript/fixtures/expected-catalog.json` | Golden output for the fixture tree | ~400 LoC |
| `extractors/typescript/test/extract.test.mjs` | `node --test` harness: golden compare, idempotency check, sorted-array check, runtime under ceiling | ~120 LoC |
| `pipeline/queries/_canonical.jq` | Add `def entries: if type == "array" then . else .entries end;` — centralizes the v1.0/v1.1 read | +10 LoC |
| `pipeline/queries/*.jq` (≈20 files) | Change `.[]` → `entries[]` at each top-level entry-point | 1–2 token edits each |
| `pipeline/queries/_tests/test_queries_integration.sh` | Existing tests that synthesize catalogs as bare arrays continue to work via `entries` helper; one new test asserts the wrapper round-trips | minor |
| `docs/pipeline-contract.md` | Document `schema_version` field, top-level wrapper, `extends` / `references` / `references_count` per-entry fields, sibling `references.json` format, deny-list rationale, query-migration recipe | +120 LoC |
| `README.md` | Add `extends`, `references`, `references_count` to the per-entry fields table; note schema_version in quick-start | +10 LoC |

**Why centralize via `_canonical.jq`**: spec §F9 says the catalog should accept the bare-array form as `schema_version: "1.0"` for one release. A per-query `(.entries // .)` repeated 20× is sloppy. A single `def entries: ...` lets us drop back-compat in one place when the deprecation window closes.

## 4. Schema delta (v1.1)

**Top-level (was bare array):**

```jsonc
{
  "schema_version": "1.1",
  "extractor": {
    "language": "typescript",
    "name": "type-catalog",
    "version": "0.4.0"
  },
  "entries": [ /* same per-entry records as v1.0, plus three new fields */ ]
}
```

**Per-entry additions** (additive — every existing field retains its semantics):

- `extends: [string, ...]` — direct supertype names, sorted alphabetically, deduplicated. Empty array when no heritage.
- `references: [{name: string, kind: "type-ref"}, ...]` — names referenced in type-syntactic position inside the declaration body, sorted alphabetically by `name`, deduplicated.
- `references_count: int` — `references | length`. Cheap derived field; the spec (A8) requires it. Distinct from existing `reference_count` (grep-style occurrence count, retained — see §5.1).

**Sibling artifact** (`references.json`, emitted only when `--emit-references-graph <path>` is passed):

```jsonc
{
  "schema_version": "1.1",
  "edges": [
    { "from": {"package": "main", "name": "A"}, "to": {"package": "main", "name": "B"}, "kind": "type-ref", "resolved": true },
    { "from": {"package": "main", "name": "C"}, "to": {"package": "main", "name": "Unknown"}, "kind": "type-ref", "resolved": false }
  ]
}
```

Resolution rule (§6.1 v2 in the spec): same-package first, then `shared`. Truly ambiguous → `resolved: false`, `to.package == from.package`.

## 5. Open-questions disposition

### 5.1 Naming collision: `reference_count` vs `references_count`

The existing extractor already emits `reference_count` — a grep-approximation of total identifier occurrences across all scanned files, populated by an existing second pass (`countIdentifiers` + the `reference_count` loop at the bottom of `type-catalog.mjs`). The spec asks for `references_count` (with `s`), defined as `references | length`. These are different signals:

- `reference_count` (existing, grep-based): total source-text occurrences. Includes mentions in implementation code, strings, comments. Coarse but catches usage outside extracted declarations.
- `references_count` (new, structural): count of *typed* references that the v1 walker found inside this declaration's body. Precise. Bounded by what the AST sees.

**Decision: keep both, document the distinction.** Zero risk (the existing `reference_count` is not yet used by any cluster query — verified by `grep -r reference_count pipeline/`), and the dual signal is useful: structural for graph-view consumers, grep for "is this name mentioned anywhere?" dead-code triage. The contract update calls this out so future-readers don't confuse the two. Deprecation of the grep version is a follow-up if structural proves to subsume it.

### 5.2 Wrapper migration: per-query edits vs `_canonical.jq` helper

**Decision: `_canonical.jq` helper.** Adds `def entries: if type == "array" then . else .entries end;`. Every query changes `[.[] | …]` → `[entries[] | …]`. Centralizes the back-compat read. When v1.0 support is dropped (one release later), the helper becomes `def entries: .entries;` and queries don't change.

### 5.3 `getText` vs `escapedText` perf

Spec §6.9 warns `getText` re-walks child nodes and proposes `escapedText` on `Identifier`. **Decision: use `escapedText` in the new walker, with a `QualifiedName` recursion that handles the nested case.** The existing code uses `getText` for `m.name.getText(sf)` (member name) — that stays; it's hot but already deployed. The new `extractReferences` walker is on the hot path.

`QualifiedName.right` is always an `Identifier` (TS AST guarantee — the right operand of `.` cannot itself be qualified). `QualifiedName.left`, however, can be another `QualifiedName` for deeply nested names like `Namespace.Inner.Deep.Type` — so the leftmost-identifier extraction must recurse. Implementation:

```js
function getLeftmostIdentifierText(typeName) {
  // typeName: Identifier | QualifiedName
  if (typeName.kind === ts.SyntaxKind.Identifier) return typeName.escapedText;
  if (typeName.kind === ts.SyntaxKind.QualifiedName) return getLeftmostIdentifierText(typeName.left);
  // Defensive fallback for any future AST node type
  return typeName.getText ? typeName.getText() : null;
}
```

Defense: the recursive case is rare in real codebases but unbounded in principle. The recursion depth is bounded by the depth of qualified-name nesting, which is small (typically 1–3). Fallback to `getText` for any unexpected node type so the walker never crashes — defensive coding matched to the spec's "doesn't crash" baseline.

### 5.4 Generics scope threading

Spec §6.4 sketch threads a `Set<string>` of in-scope type-parameter names. **Decision: build the set once from `node.typeParameters?.map(p => p.name.escapedText)` at the top of each interface/alias branch.** Pass it by reference into the recursion. For `MappedTypeNode`, construct a new `Set` that unions the outer scope with the mapped key (`K`) — push, recurse, do not mutate the parent. Same pattern for `ConditionalType.extends → infer R` (deferred to v2, but the scope-extension mechanic is the same).

### 5.5 Synthetic inline-object entries

The existing extractor emits synthetic entries for nested `TypeLiteralNode` properties (`{name: "Outer.prop", kind: "inline-object", ...}`). **Decision: synthetics get `extends: []` and a `references` array walked from their own inline body.** They inherit the parent's scope (their parent's type parameters are still in scope). The fixture corpus covers a one-level nested case (`08-pick-omit-partial.ts` or a new fixture).

### 5.6 Intersection-extends semantics

Spec §6.3 says `type X = A & B & {…}` → `extends: ["A", "B"]`. The existing extractor already records intersection operands as `{kind: 'ref', name}` for field-resolution. **Decision: reuse that operand classification — operands of kind `'ref'` go into `extends`; operands of kind `'literal'` do not (they extend an anonymous shape, not a name).** Pure intersection (`A & B`, no literal) emits both into `extends`. Union (`A | B`) — variants go into `references`, not `extends` (per §6.3 explicit guidance).

### 5.7 Zod / Drizzle handling

Spec §9 step 6: best-effort, v1 acceptance is "doesn't crash." **Decision: emit `extends: []` and `references: []` for `zod-object` and `drizzle-table` records in v1.** The Zod chain is a builder DSL whose type-position arguments are buried inside method chains; walking them properly is a separate ticket. Document this in the contract as a known v1 limitation.

### 5.8 Deny-list scope

Spec §F4 + §6.7 enumerate the deny-list: utility types (`Pick`, `Omit`, …), containers (`Array`, `Map`, …), async/iter (`Promise`, `Iterable`, …), built-in objects (`Date`, `URL`, …). **Decision: ship the spec's enumeration verbatim, in a single `const BUILTIN_TYPE_DENYLIST = new Set([...])` near `SKIP_DIRS`.** Adding new entries (e.g., `NoInfer` from TS 5.4) is a one-line PR.

## 6. TDD order

Following project convention (TDD by default, smallest viable change first):

1. **Test harness skeleton.** Create `extractors/typescript/test/extract.test.mjs` with `node --test`. Single failing test that runs the extractor against an empty fixture dir and asserts exit code 0.
2. **Fixture 01-simple-interface.** Minimal interface with no heritage, primitive fields → no `extends`, no `references`. Golden file captures the current shape. **The test fails here because the new fields don't exist yet.** Then add the schema wrapper change + `extends: []` / `references: []` defaults on every entry. Tests pass.
3. **Schema wrapper migration.** Add `def entries: ...` to `_canonical.jq`. Update queries in batches of ≤5 files at a time (mechanical `.[]` → `entries[]` token edits). Run `test_queries_integration.sh` after every batch — the suite catches `.[]` orphans the moment a query runs against a wrapped catalog. **In the same step, update the synthetic catalog fixtures in `test_queries_integration.sh` to the wrapped form (`{schema_version: "1.1", entries: [...]}`).** A query with a missed edit will fail loudly because `[.[] | …]` against an object errors out (jq: "Cannot iterate over object"). Optionally — and this is the belt-and-suspenders move — run each existing fixture *twice*, once wrapped and once bare-array, to confirm the `_canonical.jq` helper handles both forms during the deprecation window.
4. **F1: `extends` on interfaces.** Fixture 02-interface-extends. Implement `extractExtends()` for `node.heritageClauses` filtered to `ExtendsKeyword`. Sort alpha + dedupe.
5. **F2 + F3: `references` walker + scope threading.** Fixtures 03-type-alias-object, 06-generics-bound, 07-generics-shadowing. Implement `extractReferences(typeNode, sf, scope, sink)` for `TypeReferenceNode`, `TypeLiteralNode`, `UnionTypeNode`, `IntersectionTypeNode`, `ArrayTypeNode`. Threading scope set through.
6. **F4: deny-list.** Fixture 08-pick-omit-partial. `BUILTIN_TYPE_DENYLIST`. Member-test on every emitted name.
7. **F5: full node coverage.** Fixtures 09-typeof-query, 10-import-type, 11-mapped-type, 14-tuple-array, 15-function-type. Extend the walker for `TypeQueryNode`, `ImportTypeNode`, `MappedTypeNode`, `TupleTypeNode`, `FunctionTypeNode`, `ConstructorTypeNode`, `IndexedAccessTypeNode`, `ParenthesizedTypeNode`.
8. **F6: deferred nodes walk children.** Fixtures 12-conditional-type, 16-template-literal-type, 13-recursive-type. Default branch of the walker uses `ts.forEachChild(node, c => extractReferences(c, sf, scope, sink))` — buried identifiers surface.
9. **F7: intersection-extends.** Fixture 05-type-alias-intersection. Hook into the existing intersection-operand classification; `'ref'` operands → `extends`.
10. **F8: `references_count`.** Trivial: assign `e.references_count = e.references.length` in the same pass that produces `e.references`.
11. **Zod + Drizzle best-effort.** Fixtures 17-zod-with-refs, 18-drizzle-with-refs, 19-infer-model. Emit `extends: []`, `references: []` (or `references` walked from the `InferSelectModel<typeof T>` type-argument — cheap).
12. **Sibling `references.json` + `--emit-references-graph`.** Post-pass that builds the index + edge list. The harness invokes the extractor against the existing fixture corpus with `--emit-references-graph /tmp/refs.json`, then asserts:
   - (a) **File exists** at the path passed.
   - (b) **Top-level shape**: `{schema_version: "1.1", edges: [...]}`. `edges` is an array; no other top-level keys.
   - (c) **Edge structure**: every edge has `{from: {package, name}, to: {package, name}, kind: "type-ref", resolved: bool}`.
   - (d) **Resolution rules**:
     - For an edge where `to.name` exists in the catalog under `from.package`, `resolved: true` and `to.package === from.package`.
     - For an edge where `to.name` exists only under `shared`, `resolved: true` and `to.package === "shared"`.
     - For an edge where `to.name` does not exist in the catalog at all (unresolved external — e.g., a name not present in fixtures), `resolved: false` and `to.package === from.package` (fallback per §9 of the spec).
   - (e) **Deduplication**: an edge `(from, to)` pair appears at most once even if the same `references` entry shows up in multiple declarations on the `from` side.
   - (f) **Determinism**: two consecutive invocations produce byte-identical `references.json` (sort key documented: `from.package, from.name, to.package, to.name`).
   - (g) **Default behavior**: when `--emit-references-graph` is *not* passed, no sibling file is created (verified by `stat` on the path and asserting ENOENT).

   Test parameterization: three fixture-pair scenarios verifying resolved-same-package, resolved-shared, and unresolved-external. Each is asserted by its edge presence + `resolved` flag value, not by golden-file comparison (which would couple the test to insertion order).
13. **Contract + README updates.** `docs/pipeline-contract.md` documents schema_version, wrapper, three new fields, migration recipe. `README.md` adds the fields to the table.
14. **Determinism + perf gates.** Tests already cover idempotency (run twice, diff) and sorted-array assertion. Add a runtime check: extractor on the fixture corpus < 1 s; on a real-world repo (manual, recorded in PR description), < 6 s per spec A7.

Each numbered step is one or two commits — small, reviewable, each ending in a green test suite.

## 7. Fixture corpus

Per spec §6.10. One `.ts` file per feature, ≤30 LoC each:

| Fixture | Feature | Expected output |
|---|---|---|
| 01-simple-interface.ts | Interface, primitive fields | extends:[], refs:[] |
| 02-interface-extends.ts | `interface C extends A, B {}` | extends:["A","B"] |
| 03-type-alias-object.ts | `type X = { f: Other }` | refs:[{Other}] |
| 04-type-alias-union.ts | `type X = A \| B` | extends:[], refs:[{A},{B}] |
| 05-type-alias-intersection.ts | `type X = A & B & {f:N}` | extends:["A","B"], refs:[{N}] |
| 06-generics-bound.ts | `interface Box<T extends Item> { v: T; m: Item }` | refs:[{Item}] (T scoped) |
| 07-generics-shadowing.ts | `interface Outer<T> { fn: <T>(x:T) => T }` | refs:[] (both T's scoped in their scopes) |
| 08-pick-omit-partial.ts | `type X = Pick<Y, "id">` | refs:[{Y}] (Pick deny-listed) |
| 09-typeof-query.ts | `type Q = typeof userTable` | refs:[{userTable}] |
| 10-import-type.ts | `type R = import("./remote").Remote` | refs:[{Remote}] |
| 11-mapped-type.ts | `type S<T> = {[K in keyof T]: string}` | refs:[] (K, T scoped, string primitive) |
| 12-conditional-type.ts | `type C<T> = T extends U ? X : Y` | refs:[{U},{X},{Y}] via forEachChild |
| 13-recursive-type.ts | `interface N { children?: N[] }` | refs:[] (self-ref filtered? or emit; doc decision) — emit, per spec |
| 14-tuple-array-types.ts | `type T = [A, B[], readonly C[]]` | refs:[{A},{B},{C}] |
| 15-function-type.ts | `type F = (x: A) => B` | refs:[{A},{B}] |
| 16-template-literal-type.ts | ``type T = `prefix-${X}` `` | refs:[{X}] via forEachChild |
| 17-zod-with-refs.ts | `z.object({a: z.lazy(()=>OtherSchema)})` | refs:[] (v1 best-effort: empty) |
| 18-drizzle-with-refs.ts | Drizzle table referencing another | refs:[] (v1 best-effort: empty) |
| 19-infer-model.ts | `type U = typeof users.$inferSelect` | refs:[{users}] (existing infer_ref logic intersects) |
| 20-builtin-types-only.ts | Decl using only `Promise<string>`, `Pick<Foo,"a">` | refs:[{Foo}] (Promise + Pick denied) |

**Decision on self-reference (fixture 13):** emit. `interface Node { children?: Node[] }` produces `references: [{name: "Node"}]`. Spec doesn't explicitly forbid; matching what a graph-view consumer would want (a self-loop is a real edge). Documented in the contract.

## 8. Acceptance criteria mapping

Each numbered AC in #146 §7 maps to a test:

| AC | Where verified |
|---|---|
| A1 (extends ≥ grep count on case-study repo) | Manual measurement in PR description |
| A2 (≥70% non-empty refs on field-bearing decls) | Manual measurement in PR description |
| A3 (idempotency) | `extract.test.mjs` runs extractor twice, asserts `===` |
| A4 (T scoped out) | Fixture 07-generics-shadowing |
| A5 (Pick deny-listed) | Fixture 08-pick-omit-partial |
| A6 (wrapper + queries byte-identical) | `test_queries_integration.sh` post-migration |
| A7 (< 6s on case-study repo) | Recorded in PR description; CI gate ≤ 1 s on fixture corpus |
| A8 (references_count == references.length) | Fixture golden file |
| A9 (contract updated) | `docs/pipeline-contract.md` diff |
| A10 (test harness exists) | `extract.test.mjs` itself |
| A11 (sibling references.json with flag) | Dedicated test invokes extractor with `--emit-references-graph` |
| A12 (no new npm deps) | `package.json` review |

## 9. Rollout / back-compat

**v1.0 read accommodation:** The `_canonical.jq` `def entries` helper accepts both bare-array and wrapped forms. Existing catalog files (regardless of when they were generated) continue to feed every query without modification.

**One-release deprecation window:** the contract documents that v1.0 reads will be removed in v1.2. After that, queries assume the wrapper. This is the single load-bearing back-compat concession — every other change is additive.

**Coordination:**
- **#117 (snapshot/diff)** — `schema_version: "1.1"` is the field the diff tool refuses mixed-version comparisons against. Ping the #117 author at PR-open time.
- **#115 (language extractors)** — Python and Swift extractor designs need to land with the same `extends`/`references`/`references_count` shape. The contract change documents the cross-language semantics (§6.8 of the spec) so the second extractor doesn't reopen the design.
- **#119 / #147 (graph view)** — `references_count` and `references[]` are the load-bearing edge data for the graph view sub-issue. Coordinate at PR-open time so the renderer prototype consumes the wrapped catalog directly.

## 10. Risk register

| Risk | Probability | Mitigation |
|---|---|---|
| Per-query mechanical edits get a token wrong | Medium | Run `test_queries_integration.sh` after every batch of edits; the suite catches `.[]` orphans the moment a query runs against a wrapped catalog. |
| Deny-list misses a TS 5.x utility type (e.g., `NoInfer`) | Low | Single-constant location; a follow-up PR adds one line. |
| Perf > 6 s on case-study repo | Low | §6.9 estimate is 3–5× the < 2 s baseline, well below the 6 s ceiling. If hit: prefer `escapedText` on `Identifier`, avoid `getText` on type-expression bodies (already planned). |
| Wrapper migration breaks a downstream consumer outside the pipeline | Medium | `_canonical.jq` accepts both forms; existing artifacts continue to work. New consumers (graph view, diff) are coordinated with parent tickets. |
| Synthetic-entry refs explode (large nested objects with many type refs) | Low | Synthetics inherit parent scope; the walker treats them like any other field-bearing record. No special handling needed; size is bounded by the inline literal's own complexity. |

## 11. Out of scope (explicit)

- New consumer queries (`dead-code.jq`, `public-api-leaks.jq`) — those are #132 and #133.
- Graph renderer / HTML report — that's #147 / #144.
- Function-signature extraction as a new `kind` — that's #133 (or a follow-up to #115).
- Python / Swift / Rust extractor implementations — that's #115.
- Resolution of cross-package ambiguity beyond same-package-then-shared — documented as v2 in the contract.
- Removal of v1.0 bare-array back-compat — that's a follow-up at the end of the deprecation window.
- Removal or rename of the existing `reference_count` (grep) field — that's a follow-up after we see whether structural `references_count` subsumes its use cases.

## 12. PR shape estimate

- Extractor delta: +250 LoC
- Fixtures: +400 LoC across ~20 files
- Golden output: +400 LoC
- Test harness: +120 LoC
- Query edits: ~20 files, 1–2 tokens each
- Contract + README: +130 LoC

**Total: ~1300 LoC.** Above the project's 1000-line PR target (per global CLAUDE.md). Considered acceptable here because the schema change is naturally atomic — splitting it forces back-compat to live in two PRs. The fixture corpus + golden file is the bulk; it's mechanically generated. PR description will call out the line distribution.
