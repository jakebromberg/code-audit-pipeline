# Strategy candidate: hand-written field-copy mapper between twin types → `from_X` constructor + field-parity test

- **Captured:** 2026-07-28 (PT) from library-metadata-lookup PRs #610 (@ca6bb00) and #609 (@84f82b2)
- **Tier:** 1 (the identical-shape half is already caught by `exact-duplicates` — validation/plant, not new) + 2 (the mapper-function signal — a new function-catalog body field) + Tier 3 reject (detecting the drift *event* — out of lane)
- **Status:** proposed (extractor extension + one new query; not yet implemented)

This generalizes an observed-and-executed refactoring: two structurally-similar types kept in sync by a hand-maintained, field-by-field mapper function, which drifts silently when someone adds a field to one side and forgets the mapper. The detector's job is to find every *mapper function* whose body is essentially a run of pure `dst.x = src.x` field copies between two catalogued types, so a query can join it to those types, measure how completely it mirrors them, and recommend the exact fix the source PR chose — a `from_X` constructor plus a field-parity test that fails CI on divergence. The mapper is the signal that a shape rhyme is being *actively hand-maintained*, which is what separates a drift-risk 1:1 copy from an incidental shape overlap.

## Provenance — the observed sites

Two grounded before-shapes, both from library-metadata-lookup (a Python / FastAPI service; Pydantic + dataclasses), both closed in one refactor pass.

**Site A — the mapper (the novel slice), LML#610 @ ca6bb00.** `Identity` (`entity/store.py`, a `@dataclass` DB read-model — 8 artist-identity fields plus an internal `id` primary key) and `IdentityResponse` (`identity/models.py`, a Pydantic `BaseModel` wire model — the same 8 fields, no `id`) were kept aligned by a free function:

```python
def _identity_to_response(identity: Identity) -> IdentityResponse:
    return IdentityResponse(
        library_name=identity.library_name,
        discogs_artist_id=identity.discogs_artist_id,
        wikidata_qid=identity.wikidata_qid,
        musicbrainz_artist_id=identity.musicbrainz_artist_id,
        spotify_artist_id=identity.spotify_artist_id,
        apple_music_artist_id=identity.apple_music_artist_id,
        bandcamp_id=identity.bandcamp_id,
        reconciliation_status=identity.reconciliation_status,
    )
```

Called at two router sites (`identity/router.py` `resolve_identity` and `bulk_resolve_identities`). Adding a shared identity field was a silent three-place edit — the two models plus this mapper — and missing the mapper dropped the field from API responses with no test failing. The fix: an `IdentityResponse.from_identity` classmethod backed by `model_validate(identity, from_attributes=True)` (field-agnostic — reads every matching attribute, so a new shared field needs no edit here), delete the free function, repoint both callers, and add a parity test asserting `{f.name for f in dataclasses.fields(Identity)} - {"id"} == set(IdentityResponse.model_fields)` so future divergence fails CI.

**Site B — the identical-shape twin (the validation slice), LML#609 @ 84f82b2.** `BandcampResolveResult` (`release/bandcamp_resolver.py`) and `DiscogsResolveResult` (`release/discogs_resolver.py`) were byte-for-byte-identical 3-field `@dataclass`es (`canonical`, `identifiers`, `warnings`) differing only in a docstring noun, folded into one `release.models.ResolveResult`. There is no hand-mapper here — the two types were constructed directly at each resolver's return sites — so this slice is a pure shape duplicate.

The distinction between the two sites is the whole point of this candidate: Site B is **already** a finding the substrate emits today (see below); Site A is the one the substrate is blind to, and the mapper function is the missing signal.

External pattern name: "field-copy mapper" / "mapping method smell" (Fowler's *Middle Man* / boilerplate-projection family). Detector lineage: "each closed refactor pull request is a template" — future-directions §5 (#226, sub-item #225 find-next-instance), the exact premise this candidate is an instance of.

## Before-signal (the predicate)

Two related predicates, differing in what they need from the catalog:

- **Identical-shape twin (Site B) — already catchable, Tier 1.** Two shape-bearing types with equal `shape_sig`. `exact-duplicates.jq` groups by `shape_sig` regardless of `kind` or `package`, so the two identical 3-field dataclasses (both `kind: "type-alias-object"`, both package `main`, identical `fields`) cluster today with no new work. Treat this half as a **validation/plant case**, not the deliverable — if a future extractor change stops surfacing it, the plant caught a regression.

- **Hand-mapper between twins (Site A) — the new signal, Tier 2.** A callable whose body is essentially a run of *identity* field copies — `Model(x=src.x, y=src.y, ...)` keyword construction, or `dst.x = src.x` attribute assignments — between a single source type and a single dest type, both of which are catalogued shape-bearing types. The predicate is over the mapper's *body structure*, not over either type's `shape_sig`. This is what the shape queries structurally cannot see, and it is the reason a two-place-out-of-sync pair like `Identity`/`IdentityResponse` is invisible to them (next section).

Passes the lit test for the mapper slice: the question "which functions are pure field-by-field type projections?" is answered by clustering structured function-catalog rows once the extractor emits the copy structure — a deterministic AST predicate, not a token-clone search.

## Why the existing shape queries don't fully catch it

Grepped `pipeline/queries/` and traced each against the two concrete pairs:

- **`exact-duplicates.jq`** — catches Site B (equal `shape_sig`). Misses Site A: `Identity` carries `id`, `IdentityResponse` does not, so their `shape_sig`s differ and they never group.
- **`cross-package-shape-near-duplicates.jq`** — main-vs-shared only, and both Site-A types live in package `main`, so it never fires. Even cross-package it would need ≥0.7 Jaccard (8/9 = 0.89 clears it), but the package gate excludes the pair outright.
- **`shared-interface-candidates.jq`** — requires **mutual** residue (both sides keep a field the other lacks). `IdentityResponse`'s field names are a strict subset of `Identity`'s (residue only on the `id` side), so the mutual-residue gate drops it. Correct behavior — the recommendation here is a projection, not a shared interface.
- **`subset-pairs.jq`** — this one *does* emit the Site-A pair (`IdentityResponse` ⊂ `Identity` on field names, both ≥2 fields, comparison ignores `kind`). But it emits it as one of potentially hundreds of incidental subset pairs (every `{id, name, …}` fragment is a subset of every larger entity), with **no signal that a hand-mapper binds the two**. The mapper detection is the precision lift that promotes this specific subset pair from "incidental" to "actively hand-maintained, drift-risk."
- **`versioned-type-pairs.jq`** — name-suffix heuristic; the twins here don't share a `V?<n>`-stripped base name (`Identity` vs `IdentityResponse`), so it's silent.

Two structural facts make the mapper the load-bearing new signal:

1. **The cross-framework `kind` split.** The Python extractor classifies a `@dataclass` as `kind: "type-alias-object"` and a Pydantic `BaseModel` as `kind: "zod-object"` (`_classify_class`, `type_catalog.py:251`–`254`). Any clustering that partitions or filters on `kind` will split a dataclass↔pydantic twin even when the field sets are identical. The mapper body keys off neither `kind` nor `shape_sig`, so it bridges the split — exactly the case that motivates reading the body instead of the shape.
2. **The `id`-difference.** A one-field delta already defeats `exact-duplicates`; the mapper enumerates the *actually-copied* fields (8 of them) directly, and the join to the two types recovers the residue (`id`) as the field the projection intentionally drops.

## Detector spec

One extractor extension plus one new query. The identical-shape half needs neither.

### Extractor signal — `field_copy_map` on function-catalog rows (Tier 2)

- **Catalog:** function-catalog
- **What the extractor detects (AST):** a function / method / classmethod / `__init__` whose body, after dropping the docstring, consists (predominantly) of *identity* field copies from one source to one dest. Two body forms to recognize first, both present in the evidence:
  - **Constructor form** (LML#610): a single `return Dest(kw=<name>.<attr>, …)` (or an assignment of one) where every keyword `kw` equals the attribute `attr` and every `<name>` is the same operand (the sole parameter, of a single-identifier type). `Dest` is the constructed callee; the operand's declared type is the source.
  - **Attr-assign form**: a run of `dst.x = src.x` statements against an already-constructed `dst`, `src` each a stable operand, keyword/attr identity preserved.
- **What it emits** (additive object, absent when the function is not a field-copy mapper):

  ```jsonc
  "field_copy_map": {
    "source_type_ref": "Identity",          // single-ident type of the copied-FROM operand
    "dest_type_ref":   "IdentityResponse",  // single-ident type constructed / mutated
    "copied_fields":   ["apple_music_artist_id", "bandcamp_id", "discogs_artist_id",
                        "library_name", "musicbrainz_artist_id", "reconciliation_status",
                        "spotify_artist_id", "wikidata_qid"],   // sorted; identity copies ONLY
    "form": "constructor"                    // constructor | attr-assign | model_validate
  }
  ```

  `source_type_ref` / `dest_type_ref` use the **same single-identifier resolution** already used by `return_ref` and `params[].type_ref` (`_single_type_ref`, `function_catalog.py:85`), so the query's join against the type-catalog name index works uniformly with no new resolution rule. `copied_fields` counts *only* same-name attribute copies — a keyword whose value is anything other than a bare `<operand>.<same_name>` (a rename, a call, a computed expression) is deliberately excluded, so the field is a precise measure of 1:1 mirroring, not of adapter work.
- **Independent of the body-hash gate (precision note).** `_identity_to_response` is a single `return` statement; `ast.unparse` renders it as one logical line, which is below `--min-body-lines` (default 3), so the row's `body_hash`/`body_lines` are `null` today. `field_copy_map` must be computed from the constructor-call / assignment AST **before** body normalization, so short single-return mappers — the common case — still carry the signal even when body-level duplication fields are nulled.
- **`kind` vs additive field — the design choice.** Emit `field_copy_map` as an additive optional field, **not** a new `kind`. The row is still a real function with a name, signature, params, and (sometimes) a body_hash that `function-duplicates.jq` and `public-api-leaks.jq` consume; a distinct `kind` would strand that data and force every existing function-catalog query to learn a new kind. This mirrors `wraps_notification_name` (contract §"Optional but useful") — a Swift-only, body-reading field that reads a specific member's body verbatim and lets the query do the joining — and the `is_computed` precedent (additive, one language first, consumers default an absent key). Consumers read `.field_copy_map // null`.
- **Per-language, Python first.** The evidence is Python, and `ast` makes constructor-keyword and attribute-assignment walking cheap. The field is contract-level (documented once) but each extractor opts in; Swift/TS parity follows the `is_computed` precedent (schema stated, per-extractor rollout tracked separately).
- **Ready-to-paste contract note (schema-first PR):** document `field_copy_map` under function-catalog "Optional but useful," alongside `wraps_notification_name`, with the sub-field table and the "computed pre-normalization" guarantee.

### Consuming query — `field-copy-mapper-candidates.jq` (Tier 2)

- **Catalog:** function-catalog, joined to type-catalog via `--slurpfile types type-catalog.json` (same pattern as `public-api-leaks.jq` and `dead-code.jq`).
- **Shape:** pair (the finding is the source→dest type pair; the mapper is the joining evidence). `left` = source type, `right` = dest type.
- **The join, in one line:** mapper row (`select(.field_copy_map)`) → resolve `source_type_ref` and `dest_type_ref` against the type-catalog name index → keep pairs where both resolve to shape-bearing types **and** the copied-field set covers ≥ `$min_coverage` of the dest's fields.
- **Logic:**
  1. Keep function rows with a non-null `field_copy_map` whose `form` is `constructor` or `attr-assign` (see restraint on `model_validate`).
  2. Look up `source_type_ref` / `dest_type_ref` in the type-catalog; require both present, non-generated, non-test.
  3. Reuse the existing field-set machinery (the `fields | map(split(":")[0])` name-set + intersection/Jaccard used by `near-duplicates`, `subset-pairs`, `shared-interface-candidates`): compute `dest_coverage = |copied_fields ∩ dest.field_names| / |dest.field_names|` and the source residue (`source.field_names − copied_fields`, e.g. `id`).
  4. Flag pairs where `|copied_fields| ≥ $min_copied` (default 3) **and** `dest_coverage ≥ $min_coverage` (default ~0.9 — a near-total 1:1 mirror is the drift-risk; a partial copy is doing real projection work).
  5. Emit source/dest locations, the copied-field list, the residue, and the recommendation string: *"replace the hand-mapper with a `from_<source>` constructor over `model_validate(..., from_attributes=True)` (Pydantic) or an equivalent field-agnostic projection, and add a field-parity test asserting the two field sets stay aligned (modulo the residue)."*
- **Ready-to-paste header:**
  ```
  #! query: field-copy-mapper-candidates
  #! shape: pair
  #! catalog: function-catalog
  #! arg: min_copied number 3
  #! arg: min_coverage number 0.9
  #! desc: Hand-written field-by-field mappers between two catalogued types — from_X constructor + parity-test candidates.
  ```
- **Known recall gaps (state in the header):**
  - **Multi-statement transform bodies fall below the coverage floor by design.** A mapper that copies 5 fields identically and computes 3 more is a real adapter, not a drift-risk twin; the `dest_coverage` gate drops it. That is correct precision behavior, but it means a mapper that is *mostly* copies with a couple of legitimate transforms won't surface — the residual copy-boilerplate in it is below this detector's resolution.
  - **The drift *event* is invisible — permanently, here.** "Someone added a field to one side and forgot the mapper" is a temporal fact (direction #1) or a git-diff fact; this detector sees only the current tree. It surfaces the *before-shape* (a hand-mapper exists between two near-mirrors) as a proxy from which an agent installs the parity test that makes future drift fail CI. It cannot flag the specific forgotten edit. Recorded honestly as a Tier-3 reject, not a gap to close with a body-token heuristic.

## Catalog needs & tier justification

- **Fields used that exist today:** function-catalog `references`, `return_ref`, `params[].type_ref`, `name`, `kind`, `package`, `file`, `line`, `is_test`, `generated`; type-catalog `fields`, `shape_sig`, `kind`, `name`, `package`, `generated`, `is_test`. The mapper's `references` already carries both `Identity` and `IdentityResponse` as type-refs (weak co-location — many functions reference two types); the new field is what asserts *this is a 1:1 copy* rather than merely *this touches both types*.
- **Additive change required (Tier 2 — contract PR first):** the `field_copy_map` object on function-catalog rows. It is a genuinely new field-catalog extension (a function-*body* structural signal), distinct from the corpus's existing proposed function extensions (`params[].type_text`, `switch_case_sets`, `body_hash_erased`) and from the userdefaults candidate's *type*-catalog `persists_via_accessor`. Modeled on `wraps_notification_name` (verbatim body-reading, one language first, query does the join).
- **`unverified — needs check`:** that the Python `ast` walk can cheaply distinguish the `model_validate(..., from_attributes=True)` idiom (the *fixed* form) from an explicit field-by-field constructor so the extractor tags `form: "model_validate"` and the query demotes it rather than re-flagging an already-refactored site. `ast` exposes the call keyword `from_attributes`, so this looks tractable, but confirm before relying on it for the demotion path below.

## Restraint (when the before-state is intentional)

- **Real adapters are not findings.** Field renames (`dst.a = src.b`), type conversions (`dst.x = str(src.x)`), computed/derived fields, and intentional narrowing projections are legitimate transform work. The extractor counts *only identity* copies as `copied_fields`, and the `dest_coverage` floor demotes any body that is substantially transform rather than copy. Keep both gates; do not relax `copied_fields` to "any keyword argument."
- **The `model_validate(from_attributes=True)` form is the *after*, not the before.** A mapper already written field-agnostically is the fix, not the smell. Tag it `form: "model_validate"` and **demote** it (mirror the #217 `demoted` convention used by `exact-duplicates` / `shared-interface-candidates`) so the query self-extinguishes on sites that already adopted the recommended shape rather than re-recommending it.
- **Identical-shape twins with no mapper stay in their own lane.** Site B (`ResolveResult`) has no hand-mapper; it is `exact-duplicates`' finding, not this one. Don't double-count — this query fires only when a `field_copy_map` exists.
- **Deliberate wire/DTO boundary.** A projection that intentionally exists because the wire model and the storage model must evolve independently (versioned API contract, PII stripping) is a designed boundary, not drift. The detector cannot see intent; it should surface the pair with its copied-field list and residue and leave the keep-or-collapse judgment to the reader — advisory output, not a directive. Standard downrank on `generated` and `is_test` on either endpoint.

## Measurement plan

Follow the established plant-injection / plant-recall methodology (V5 hit 100% per-plant recall on dj-site; V6 hit 19/20 on Swift; `docs/refactor-recommendation-experiment-methodology.md` §1, with the per-plant manifest schema and the isolated-source-set procedure that keeps plants absent from baseline output). For this technique:

- **Plants (recall).** Inject hand-mapper before-shapes into a Python corpus drawn from the isolated-source set: (a) a constructor-form mapper (LML#610 shape), (b) an attr-assign-form mapper, (c) a cross-framework dataclass↔pydantic twin (the `kind`-split case), (d) a same-framework twin. Measure whether each surfaces as a `field-copy-mapper-candidates` pair.
- **Restraint twins (precision).** Pair each plant with a twin that shares the surface signal but where action is wrong: a real adapter with renames/transforms, an already-fixed `model_validate(from_attributes=True)` mapper, and an intentional narrowing projection across a designed wire/DTO boundary. Measure the false-positive rate — the restraint twins must *not* flag (or must flag demoted).
- **Natural validation.** LML#610 @ ca6bb00^ (pre-refactor) and #609 @ 84f82b2^ are real before-states in a real repo; run the extractor+query against those parents and confirm Site A surfaces as a mapper pair and Site B surfaces via `exact-duplicates` — a natural, un-planted check that the two slices land in the two lanes the design predicts.

## Implementation sequencing

- **Ships now:** nothing new for Site B — `exact-duplicates.jq` already clusters identical-shape twins. No Tier-1 work for the mapper slice.
- **Tier 2, schema-first, three small PRs (each well under the 1000-line delta rule):**
  1. Contract PR: document `field_copy_map` on function-catalog rows (sub-field table, `form` enum, "computed pre-normalization" guarantee, demotion note for `model_validate`).
  2. Python extractor PR: emit `field_copy_map` for constructor-form and attr-assign-form bodies; regenerate and commit the embed tree in the same PR.
  3. Query PR: `field-copy-mapper-candidates.jq` (function-catalog × type-catalog join), with the `demoted` path for `model_validate` and the plant/restraint fixtures.
- **Alignment to roadmap.** Direction #5 (#226 / #225 find-next-instance) is the literal premise — this candidate is a closed refactor PR turned into a before-shape detector. Direction #2 ("the catalog as a universal structural index — growing the substrate") is the mechanism: the function-catalog gains one more structural signal, and "which twins are hand-maintained?" becomes a join rather than an audit.

## Related existing queries

Grepped `pipeline/queries/` + `docs/`:

- **`exact-duplicates.jq`** (implemented) — owns Site B; the identical-shape twin needs no new work. This candidate's Tier-1 half is entirely "already covered — use as a plant."
- **`subset-pairs.jq`** (implemented) — emits the Site-A type pair today (as a name-subset), but drowned among incidental subsets and with no hand-maintenance signal. The mapper field is the precision lift over it, not a replacement; a promoting session could have `field-copy-mapper-candidates` cross-reference `subset-pairs` cluster_ids to show "this subset pair is the one with a live mapper."
- **`shared-interface-candidates.jq`** / **`cross-package-shape-near-duplicates.jq`** (implemented) — correctly silent on Site A (mutual-residue gate; main-vs-shared gate). Confirming they *don't* fire is the point: the gaps are structural, not queries merely missing.
- **`function-duplicates.jq`** (implemented) — clusters function *bodies* by hash/Jaccard; a mapper is typically a single short return whose body_hash is nulled, so it never clusters there. Not an overlap.
- **`notification-wrapper-grouping.jq`** (implemented, `wraps_notification_name`) — the design precedent for a verbatim body-reading, one-language-first, query-joined additive field. A mechanism to copy, not a coverage overlap.
- **`2026-07-23-userdefaults-keytable-boilerplate.md`** (proposed) — adjacent: its Detector B also reads a body-level structure into an additive field (`persists_via_accessor`). Different target (intra-type persistence boilerplate vs inter-type field-copy projection), same "read a specific body construct into an additive field and let the query join" lineage. Worth reading alongside so a promoting session keeps one body-reading-field convention rather than two.
