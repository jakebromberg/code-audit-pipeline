# Strategy candidate: name-identical / type-divergent re-typed contract → import the shared type

- **Captured:** 2026-08-06 (PT) from `WXYC/dj-site @ 35099ab6`, consuming `@wxyc/shared` (published npm package, `node_modules/@wxyc/shared/dist/*.d.ts`)
- **Tier:** 1
- **Status:** proposed (not yet implemented as a query)

## Provenance — the observed sites

A consumer repo hand-declares a request/response body type that already exists as an exported type in the shared contract package. The declaration is not merely redundant — it *disagrees* with the contract on one or more field **types**, while agreeing on every field **name**. TypeScript validates call sites against the local lie, so the code compiles, the unit tests pass, and the server rejects the request at runtime.

Five sites in one feature slice (`lib/features/*/types.ts`), all redeclaring types that `@wxyc/shared/dtos` exports today:

| # | Local decl | Shared decl | Field-name delta | Field-type delta |
|---|---|---|---|---|
| 1 | `KillRotationParams` (`lib/features/rotation/types.ts:14`, at `72eef04f~1`; deleted by `72eef04f`) | `KillRotationRequest` | **none** | `kill_date: Date \| undefined` vs `kill_date?: string` |
| 2 | `UpdateAlbumRequestBody` (`lib/features/catalog/types.ts:71`) | `UpdateAlbumRequest` | **none** | `label_id?: number` vs `number \| null`; `alternate_artist_name?: string` vs `string \| null` |
| 3 | `AddArtistRequestBody` (`lib/features/catalog/types.ts:87`) | `AddArtistRequest` | +`code_number`, +`alphabetical_name` | — |
| 4 | `AddAlbumRequestBody` (`lib/features/catalog/types.ts:49`) | `AddAlbumRequest` | −`album_artist` | — |
| 5 | `AlbumSearchResultJSON` (`lib/features/catalog/types.ts`) | `AlbumSearchResult` | +3 (deliberate, documented) | `add_date: Date` → `string` (deliberate JSON-boundary adapter) |

**Site 1 is the severity case and the reason to capture this.** `kill_date` was sent as a JS `Date`, which serializes to `"2026-08-05T23:12:06.729Z"`; the server validates `/^\d{4}-\d{2}-\d{2}$/`. Every kill request returned 400 — a 100% failure rate on a shipped MD workflow — behind ten passing unit tests, one of which asserted `typeof body.kill_date === "string"` and was satisfied by the malformed value. Fixed by deleting the local type and omitting the field so the server dates the kill itself.

This is the "closed refactor PR as detector template" pattern (future-directions §5): the fix commit `72eef04f` *is* the after-state, and the deleted declaration is the before-state.

**Sites 3 and 4 are the contrast that makes the case.** They differ from the contract by field *name*, so the existing `cross-package-shape-near-duplicates` query surfaces them in `left_only` / `right_only`. Sites 1 and 2 — the ones that produce or would produce wrong wire payloads — are name-identical, so the same query scores them Jaccard **1.0** with `left_only: []` and `right_only: []`. **The existing detector renders the highest-severity members of this family as perfectly matching shapes.** An agent judging that row is told the two types agree.

(Site 3 also exposes a real contract defect in the other direction: Backend-Service `apps/backend/controllers/library.controller.ts:323-325` throws `400 Missing Request Parameters` when `code_number` is absent, and reads `alphabetical_name` at :339, but `api.yaml`'s `AddArtistRequest` declares neither. Direction of truth is a judgment call for the agent, not the detector — the detector's job is to surface the disagreeing pair.)

## Before-signal (the predicate)

A `main`-package shape-bearing type and a `shared`-package shape-bearing type whose **field-name sets** are identical or near-identical (name-Jaccard ≥ `name_threshold`), **and** for which at least one shared field name carries a non-equivalent normalized type annotation on the two sides.

Stated over catalog rows: for a pair `(a, b)` with `a.package == "main"`, `b.package == "shared"`, both with non-null `fields`, build per-side maps `name → type_text` by splitting each `fields[]` member on its **first** colon; flag the pair when the name-key sets overlap at ≥ `name_threshold` and the intersection contains ≥1 key whose normalized type strings differ.

Passes the lit test: every input (`package`, `fields[]`) is an existing structured catalog field; the predicate is set arithmetic and string comparison over them.

## Detector spec

- **Proposed query:** `cross-package-field-type-drift.jq`
- **Catalog(s):** type-catalog
- **Shape:** pair (asymmetric — `left` = main, `right` = shared; matches `cross-package-shape-near-duplicates`)
- **Logic:**
  1. Candidates: `kind | startswith("type-alias") or . == "interface" or . == "zod-object"`, `fields != null`. Main side additionally `(.generated // false) != true`; shared side keeps generated rows (a published `.d.ts` contract package is `generated: true` under the contract's rule `relPath.endsWith('.d.ts')` — and it is precisely the canonical artifact to compare against).
  2. For each side, `fields[] → {name, type}` where `name = (split(":") | .[0] | sub("\\?$"; ""))` and `type = (split(":") | .[1:] | join(":"))`. **The type must be rejoined, not taken as `.[1]`** — inline object and mapped types (`x:{ a: string }`, `x:Record<string, number>`) contain further colons, and `.[1]` silently truncates them into a false mismatch.
  3. Pair main × shared. Compute name-Jaccard. Keep pairs ≥ `name_threshold`.
  4. `drift = [ shared name keys ∩ main name keys | select(normalize(main.type) != normalize(shared.type)) ]`. Keep pairs where `drift | length > 0`.
  5. Emit both endpoints, `name_jacc`, and `drift[]` as `{field, main_type, shared_type}` — the drift list is the whole judgment payload.
- **Type normalization before comparison (must be explicit, or the query is all noise):** lowercase; collapse whitespace runs; sort union members and strip a trailing `| undefined` when the counterpart field is `?`-optional (the extractor puts optionality on the *name* as `?` and TS also spells it in the union — `kill_date?:string` and `kill_date:string | undefined` are the same contract and must not read as drift). Everything surviving that is a genuine disagreement.
- **Ready-to-paste query header:**
  ```
  #! query: cross-package-field-type-drift
  #! shape: pair
  #! catalog: type-catalog
  #! arg: name_threshold number required
  #! formats: text, jsonl
  #! desc: Re-typed contract: main/shared pairs agreeing on field names but disagreeing on field types.
  ```
- **Known recall gaps (required):**
  - **The ≥3-field floor must not be inherited.** `cross-package-shape-near-duplicates` requires `(fields | length) >= 3` on both sides. Observed site 1 (`KillRotationParams`) has **two** fields and would be filtered out before any type comparison ran — the worst offender found in this corpus is invisible to the existing query on *two* independent grounds (field floor, then name-only Jaccard). This query should floor at ≥1 shared field key with drift, not at a field count. The name-only queries need the floor because a 1-field name match is meaningless; a 1-field *type* disagreement on a matched contract name is not.
  - Requires the shared package to be in the catalog. The TypeScript extractor's `--shared` auto-detection (`findSharedCandidates`, `type-catalog.mjs:300-316`) looks for a **sibling directory containing `src/`** whose name or `package.json` name matches `/shared/i`. A contract consumed as a published npm dependency (`node_modules/@wxyc/shared/dist`) will **not** be auto-detected and must be passed explicitly as `--shared node_modules/<pkg>/dist`. Nothing in the extractor forbids this — `EXT_RE` matches `.d.ts` and `walkDir`'s `SKIP_DIRS` only applies below the given root — but a run that forgets it silently yields zero pairs, which reads identical to "no drift."
  - Blind to drift expressed outside a named type: inline parameter annotations, `satisfies` expressions, and request bodies assembled ad hoc at the call site. Only named declarations are catalog rows.
  - Blind to *semantic* drift under an identical type string (a `string` that must be `YYYY-MM-DD` vs a `string` that may be any ISO-8601 instant). Site 1's fix landed at exactly this boundary — the post-fix contract is `kill_date?: string` and a caller could still send `new Date().toISOString()` and 400. That residue belongs to a schema-validation layer, not to this detector.
  - Deliberate JSON-boundary adapters (site 5) are true positives by the predicate and false positives by intent — see Restraint.

## Catalog needs & tier justification

- `package` — **exists today**. `verified: contract "Type catalog" §entries; emitted by extractors/typescript/type-catalog.mjs`.
- `fields[]` as sorted `"name:type"` strings, with optionality carried as a trailing `?` on the *name* — **exists today, and carries the type text this detector needs**. `verified: extractors/typescript/type-catalog.mjs:377-410 membersToFields`, which returns `` `${name}${optional}:${typeText}` `` where `typeText = normalize(typeNode.getText(sf))`. This is the load-bearing verification for the Tier-1 claim: **every field-comparing type query in the repo discards this data, but the extractor has always emitted it.**
- `kind`, `generated` — **exist today**. `verified: contract "Kinds" table; generated at type-catalog.mjs:584 (relPath.endsWith('.d.ts') || /(^|\/)generated\//)`.
- `fields_structured[]` (`{name, type, is_optional, is_static}`) — **exists in the contract, NOT emitted by the TypeScript extractor.** `verified: contract §"V7 §6.1: fields_structured" states "Populated by the Swift extractor (V7 §6.1). TypeScript extractor parity follows the same schema and is tracked separately"; the TS example there is labelled "forward-looking"; grep for fields_structured in extractors/typescript/type-catalog.mjs returns zero matches.` **This query must therefore parse `fields[]`, not `fields_structured[]`** — which is what keeps it Tier 1 rather than Tier 2. When TS parity lands, step 2's split/rejoin collapses to a direct read of `.type` / `.is_optional` and the optional-union normalization becomes unnecessary; that is a simplification, not a blocker.
- **Unverified assumptions:**
  - `unverified — needs check`: that a `--shared node_modules/@wxyc/shared/dist` run produces usable rows end to end. The path is not forbidden by anything read here, but no run was performed and no fixture exercises a `node_modules` shared root.
  - `unverified — needs check`: whether Swift/Python/Rust extractors encode optionality on the name (as TS does) or only in the type. The normalization in step 2 is written against the TS encoding; a cross-language version needs per-extractor confirmation.

## Implementation sequencing

Single PR, no contract change: the query consumes `fields[]`, `package`, `kind`, and `generated`, all emitted today by the TypeScript extractor. Ships independently of TS `fields_structured` parity.

A follow-up (separate PR, only after TS `fields_structured` parity lands) simplifies the split/rejoin and optional-union normalization into direct `.type` / `.is_optional` reads. Do not couple the two — the value is available now and the parity work has its own schedule.

## Restraint — when this before-state is intentional

- **JSON-boundary adapters.** The canonical legitimate case, and the most common one in any RTK-Query/`fetch` client: the wire delivers `string` where the domain type says `Date`. Observed site 5 (`AlbumSearchResultJSON = Omit<AlbumSearchResult, "add_date"> & { add_date: string }`) is exactly this and is correct code. Downrank main-side names matching `(JSON|Wire|Dto|Raw|Payload|Serialized)$`, and downrank a pair whose *only* drift is `Date ↔ string` on a field whose name matches `(_at|_date|Date|At)$`. Note the tension with site 1, whose drift was also `Date ↔ string` on a `_date` field — the discriminator is direction and role: an adapter widens a *response* toward the wire, site 1 narrowed a *request* away from it. If a `direction` signal isn't available, keep these rows but rank them below non-date drift rather than dropping them.
- **Deliberate narrowing.** A consumer may legitimately declare a *stricter* type than the contract (a required field the contract marks optional, a literal union where the contract says `string`). Where one side's normalized type is a strict subset spelling of the other's, mark it and rank it lower than a genuine mismatch.
- **Structural noise.** Downrank `is_test`, `synthetic`, and main-side `generated` rows, per repo convention.
- **Pairs already unified.** If the main decl's `references[]` names the shared decl (`Omit<Shared, …>`, `Pick<Shared, …>`, `Shared & {…}`), the abstraction is already in use and the drift is an intentional local override. This is the same demotion `near-duplicates.jq` applies via its `demoted` flag for pairs already conforming to a shared protocol — mirror that flag rather than inventing a new field.

## Related existing queries

- `pipeline/queries/cross-package-shape-near-duplicates.jq` — **implemented**. The direct sibling and the reason this candidate exists. Same main×shared pairing, same Jaccard machinery, same `pair` envelope; it discards types at `split(":") | .[0]` and strips `?` at `sub("\\?$"; "")`, and it excludes same-name pairs entirely (deferring them to `cross-package-shadows`). This candidate is its **complement**: it should include same-name pairs, and it fires precisely where that query's Jaccard saturates at 1.0. Reuse its `loc_key` / `cluster_id_sorted_pair` helpers — `verified: both are defined in pipeline/queries/_canonical.jq` and used by that query.
- `pipeline/queries/cross-package-shadows.jq` — **implemented**. Catches main-package decls whose *name* also exists in shared. Would not have caught any observed site: every local decl here is deliberately renamed (`…RequestBody`, `…Params`, `…JSON`), which is what let the redeclaration read as a distinct concept rather than a shadow. Worth noting in the query header that the two queries partition the space by naming discipline: shadows catches the lazy copy, this catches the *renamed* copy.
- `pipeline/queries/near-duplicates.jq` — **implemented**. Same name-only limitation, stated explicitly in its header ("Threshold is on field NAMES only (ignoring types)"). Within-package, so it does not overlap this candidate's main×shared scope, but it shares the blind spot; if this candidate proves out, the same type-aware pass is a natural extension there.
- `pipeline/queries/subset-pairs.jq` — **implemented**. Header states "Comparison is on field NAMES only (ignoring types, `?` optionality) — same convention as near-duplicates.jq." Confirms the name-only convention is repo-wide and deliberate; this candidate is a scoped exception to it, not a correction of it.
- `pipeline/queries/versioned-type-pairs.jq`, `pipeline/queries/test-prod-drift.jq` — **implemented**. Adjacent "two declarations of one concept drifted apart" family; neither compares field types across a package boundary.

---

# Note (not a candidate): duplicated dropdown components are already covered

The same session found ~90 lines of near-identical React component body shared by `TrackPickerDropdown.tsx` and `RotationReleaseDropdown.tsx` in `WXYC/dj-site` (identical local state names `open` / `query` / `highlightIndex`, identical handler names `openPanel` / `closePanel` / `handleSelect` / `handleKeyDown`, and one comment block reproduced verbatim), with a third partial variant in `ArtistSearchTypeahead.tsx`. One of the three carries a defect the others don't, which is the usual cost of forked copies.

This needs **no new strategy**: `pipeline/queries/function-duplicates.jq` (**implemented**) already has a near-duplicate-pairs section computing pairwise Jaccard over `body_lines` at `--argjson threshold`, which is the right detector for a forked-then-edited component body. Recorded here only so a future session doesn't re-propose it.

`unverified — needs check`: whether the TypeScript function extractor emits rows for React function components whose props are an inline destructured object annotation, and whether locally-scoped arrow consts inside a component body become their own `arrow-function` rows. If component bodies are catalogued as single functions, the existing query covers this at a threshold near 0.5–0.6 (the two bodies differ in identifier names throughout); if they are not, the pattern is out of reach and this note becomes a Tier-3 reject.

---

# Secondary candidate: exported declaration kept alive only by its own tests

- **Tier:** 2
- **Status:** proposed
- **Provenance caveat — read first:** this is a *generalization*, not a grounded observation. The two sites that suggested it (`AdminProtectedRoutes`, a `const` object; and a dead `"Rotation"` string in an RTK-Query `tagTypes` array) are both **values, not type declarations**, so neither is a type-catalog row and neither would be caught by the detector below. The pattern is recorded because the shape is real and recurs — a declaration whose only consumers are its own unit tests, which then encode a rule nothing enforces — but an implementer should find their own grounded sites before building it.

## Before-signal

An exported, non-generated declaration whose resolved incoming reference edges *all* originate from `is_test: true` files. Zero-reference decls are already `dead-code`; this is the adjacent class where the test suite is the sole consumer, which reads as alive in every existing query.

## Detector spec

- **Proposed query:** extend `dead-code.jq` with an `--argjson ignore_test_refs true` mode rather than adding a sibling — the counting logic is otherwise identical, and two near-copies of an edge-counting reducer will drift.
- **Catalog(s):** type-catalog + references-graph
- **Logic:** same reduction as `dead-code.jq`, but when `ignore_test_refs` is true, skip edges whose source is a test file.

## Catalog needs & tier justification

- `references.json` `edges[]` with `from: {package, name}`, `to: {package, name}`, `kind`, `resolved` — **exists today**. `verified: contract §"Sibling references.json artifact"`.
- **Additive field required (this is what makes it Tier 2):** `from.is_test` (or `from.file`, from which `is_test` is derivable) on each edge. Edges carry only `package` and `name` today, so there is no way to tell a test-originated reference from a production one. This must land in `docs/pipeline-contract.md` first, then in each extractor's reference walker.
  - Precedent for feasibility: `is_test` is already computed per row in the type catalog from file-path patterns (contract §"Test path patterns"), so the classification exists — it simply isn't propagated onto edges. **Granularity mismatch to note:** the existing flag is per *declaration row*; this proposal needs it per *edge source*, which is the same classification applied at a different join point. Not free, but not new logic.
- Interacts with the known v1 false-positive class already documented for `dead-code.jq` (barrel re-exports emit no synthetic edge), which this mode inherits unchanged.

## Restraint

Public API surface of a library package is referenced only by tests *by construction* — downrank or exclude decls in packages whose consumers are out of catalog. Fixture factories, test-only builders, and types under `is_test` paths are legitimately test-only and must be excluded on the *target* side, not just the source side.
