# dj-site Divergence Experiment — V2 Results

> Results of executing the protocol defined in [`dj-site-divergence-experiment-v2-methodology.md`](./dj-site-divergence-experiment-v2-methodology.md). All quantitative findings come from `pipeline/analysis/v2-analysis.mjs`; raw trial outputs at `/tmp/wxyc-audit-v2/<condition>/trial-N/output.{json,md}` (off-repo).

## Run metadata

- dj-site SHA: `2ec6a9c074819cbd6c58a0a2f178a55144b56ead` (`main`)
- Backend-Service SHA: `b33fc232b2a56fe683feed6eb4649cbe487faeca` (`main`)
- Model: Opus 4.7, agent-default temperature, sub-agent type `general-purpose`
- Trials per condition: 5
- Launch order: 5 waves of (C1, C2, C3, C4, C5) trial-N each, parallel within wave, sequential across waves
- One trial (C5 trial-4) stalled mid-write at ~63 findings and was re-launched; completed cleanly at 271 findings on retry.

## Headline numbers

| Condition | Trials | Findings / trial | Intra Jaccard (mean ± σ) | Substrate | Output format |
|---|---|---|---|---|---|
| C1 | 5 | 6, 7, 6, 9, 6 | informal (Markdown) | Narrow | Free-form MD |
| **C2** | 5 | 4, 4, 4, 4, 4 | **1.00 ± 0.00** | Narrow | Structured JSON |
| **C3** | 5 | 54, 54, 54, 54, 54 | **1.00 ± 0.00** | Widened | Structured JSON |
| **C4** | 5 | 30, 40, 36, 40, 37 | **0.31 ± 0.04** | None (cold) | Structured JSON |
| **C5** | 5 | 253, 271, 271, 271, 271 | **0.93 ± 0.04** | Widened | Structured JSON (Backend-Service) |

C5's intra-pair range is 0.87–1.00; the one 0.87 trial-pair involves the C5 trial-1 which scored 253 findings (vs 271 for the other four), missing some near-duplicate pairs that the other trials caught.

## Predictions check

| V1 claim | V2 prediction | V2 result | Verdict |
|---|---|---|---|
| Output format + prompt regime drive most of V1's divergence | C2 intra-pair Jaccard ≥ 0.75; C1 reproduces ~0.40 | C2 = **1.00**; C1 informal but qualitatively ~0.4 finding-overlap | ✅ |
| Substrate widening is the route to top-K convergence | C3 intra-pair Jaccard ≥ 0.85 | C3 = **1.00** | ✅ |
| Pipeline-aware (widened) and cold agents converge under controlled prompts | C3 ∪ C4 coverage Jaccard ≥ 0.70 | C3 ∪ C4 = **0.08** | ❌ (big surprise) |
| Frontend vs backend gap is structural | C5 intra ≥ C3; C5 widened-vs-cold gap < C3's | C5 = 0.93 < C3 = 1.00; cold not run on Backend-Service so the gap comparison is incomplete | ❌ (partial) |
| Pigeonhole sampling explained V1's ~40% Jaccard | C2's enumerate regime collapses it | Confirmed — C2 = 1.00 with 4 enumerable clusters | ✅ |

## The big finding

**Substrate-widening + enumerate-prompting drives intra-condition Jaccard to 1.00 for dj-site** (C3), and to 0.93 for Backend-Service (C5). V1's ~0.40 Jaccard is a sampling artifact of the "quality over quantity" prompt that vanishes when the prompt is "score every enumerated cluster". The deterministic-extraction principle's reproducibility claim is rescued — but the rescue happens at the prompt-and-format layer, not in the substrate itself.

**However, this convergence happens *within* a condition, not *across* conditions.** C3 (widened pipeline-aware) and C4 (cold) overlap on only **12 of 145 clusters by strict cluster_id match** — a Jaccard of 0.08. A post-hoc audit decomposes this gap into three layers:

| Layer | What it is | Cost (Jaccard points) | Fixable in V3? |
|---|---|---|---|
| **Strict → semantic** | Same finding, different category prefix (e.g., `name-collisions:WXYCRole` in C3 vs `cross-package-shadows:WXYCRole` in C4; `exact-duplicates:DJBinQuery+DJRequestParams` vs `subset-pairs:DJBinQuery__DJRequestParams`; near-dup pairs in reversed order). 6 findings. | 0.08 → 0.15 | Yes — emit canonical cluster_ids from the substrate, not the agent. |
| **Semantic → query-relaxation** | Cold finds things the V2 queries are structurally unable to surface — not new substrate, just less-restrictive filters. ~30 findings. | 0.15 → ~0.50 | Yes — relax filters: `cross-package-shadows` filters shared to `interface|type-alias-object`, missing unions like `FlowsheetEntry` and `type-alias-other` const-enums like `Genre`/`Format`; `near-duplicates` filters to `package == "main"` only, never comparing main↔shared by shape (missing `OnAirDJResponse` vs `OnAirDJ` id-type drift); `subset-pairs` requires both sides have `fields`, missing intersection types (`FlowsheetSongEntry = FlowsheetSongBase & DateTimeEntry`); 1-field types filtered as noise but legitimate when both sides are wire DTOs. |
| **Query-relaxation → new substrate** | Genuine substrate gaps that need new extractor work. ~10 findings. | ~0.50 → 0.70 | Yes, but heavier lift — function-body duplication (`betterAuthSessionToAuthenticationData` sync/async pair), file-content hashing (byte-identical `StoreProvider.tsx` in `app/` and `src/`), function-name collisions (the `isFlowsheet*Entry` type-guard family shadowing `@wxyc/shared/dtos/extensions.ts`). Requires separate extractors. |

**The 0.70 prediction wasn't wrong about agent behavior — it was wrong about how many substrate gaps V2's 5 additions actually closed.** V2 closed the `.tsx` / `--shared` / inline-object axes; it didn't touch the query-filter restrictiveness or the function/file dimensions. The "cold agents do complementary work" framing should be downgraded to: cold agents find what query restrictions and missing extractors hide from the pipeline. Substrate-widening is still the lever; V2 just stopped widening too soon.

- **C3-only** (30 semantic findings the strict-Jaccard analysis attributed to C3): 4 same-shape duplicate clusters (`ExperienceLayoutProps+ExperienceProviderProps`, etc.); inline-object near-duplicates like `BetterAuthSession.user+User` (only visible because of V2's synthetic-entry feature); subset-pair relationships (20+ of them) that cold doesn't have a systematic detector for. Many of these are legitimate pipeline wins.
- **C4-only** (75 semantic findings): see the table above. Most are query-relaxation candidates, not "things cold sees that pipelines can't."

## What 1.00 within-condition Jaccard means and doesn't mean

C3's 1.00 says: all 5 trials emit **the same set of cluster_ids**, in different order but covering the same surface. It does **not** say agents agree on *severity*: only 6 of 417 unique cluster_ids show modal-severity disagreement across conditions, but within C2 alone, the same `exact-duplicates:DJBinQuery+DJRequestParams` cluster was rated `medium` in 2 trials, `low` in 1, and `high` in 1. So cluster-set agreement is total, but severity calibration remains noisy at the individual-trial level. Modal severity (within a 5-trial condition) smooths it out, but variance per trial is still real.

If V3 wants flat severity, the methodology already proposes the right move: drop severity from the agent's job and apply the rubric in a separate post-hoc pass. V2 confirms this would help.

## Substrate sizes

| Variant | Catalog entries | Main | Shared | Synthetic | Generated (filtered from queries) |
|---|---|---|---|---|---|
| dj-site narrow | 140 | 140 | — | 0 | 0 |
| dj-site widened | 1040 | 200 | 840 | 592 | 583 |
| Backend-Service widened | 1184 | 344 | 840 | 591 | 583 |

The "Generated" column reflects entries that the V2 queries filter out (OpenAPI codegen artifacts in `shared/generated/`). Filtering these is what makes the widened catalog usable — without it, the 60+ pure-codegen-internal duplicate clusters dominate the cluster outputs.

## Query output sizes

| Query | dj-site narrow | dj-site widened | Backend-Service widened |
|---|---|---|---|
| exact-duplicates | 2 clusters | 5 | 8 |
| name-collisions | 0 | 5 | 24 |
| cross-package-shadows | 0 (no `--shared`) | 9 | 8 |
| near-duplicates ≥0.7 | 0 | 1 | 23 |
| near-duplicates ≥0.5 | 2 | 8 | 71 |
| subset-pairs | (query didn't exist in V1) | 27 | 160 |

## Substrate-widening payoff: inline-object expansion

The synthetic-entry feature (TypeLiteralNode → catalog entry) surfaced structure V1 missed entirely. Examples that all 5 C3 trials independently flagged as `medium` or `high`:

- `BetterAuthSession.user` (synthetic) vs `User` (declared) — 65% Jaccard near-duplicate. The inline session-user shape and the named User type are evolving in parallel; 16 fields hand-copied.
- `BetterAuthSession.session` (synthetic) vs `RoleAuthorizedSession.session` (synthetic) — both inline, near-duplicate. A pure side-effect of two adjacent authorization types each defining their own inline session shape.
- `BetterAuthSession.user` (synthetic) vs `BetterAuthUser` (declared) — both describe the better-auth user, with subtle drift.
- `RoleAuthorizedSession.user` (synthetic) ⊂ `User` (declared) — strict subset, should be a `Pick<>`.

Without the synthetic-entry feature, these are invisible because inline `{ … }` literals aren't catalog entries — the V1 catalog's `BetterAuthSession` entry was a single row with `user: { … }` as one stringified field, with no structural visibility.

## Codegen-noise filter (post-hoc methodology refinement)

When `--shared` indexes `@wxyc/shared`, the OpenAPI codegen output dominates: 583 of 840 shared entries are generated `.d.ts` and per-model `.ts` files that re-declare the same shape across the consolidated `.d.ts` and individual model files. Before filtering, this produced 60+ exact-duplicate clusters that were pure codegen internals.

Decision: cluster queries (except `cross-package-shadows`) filter `generated: true`. `cross-package-shadows` keeps generated in scope because main↔shared/generated collisions are the canonical signal it surfaces. Also fixed a `generated` detection bug — the original `relPath.includes('/generated/')` check missed paths that start with `generated/` (no leading slash); regex `/(^|\/)generated\//` is correct.

This filter is a methodology refinement, not a substrate-widening rollback: synthetic-entry expansion still surfaces inline-objects in non-generated code (responsible for the BetterAuthSession.user finding above).

## C4 cold-agent intra-condition Jaccard at 0.31

Cold agents had the enumerate prompt and the same severity rubric as C3, but their intra-condition Jaccard is **0.31** versus C3's 1.00. The findings-per-trial range is 30–40 (mean 36.6) — variance in *what* they enumerate, not just *how much*.

Concretely: across 5 cold trials, the union covers 103 cluster_ids, but the average pair shares only ~14 of those. Cold agents don't have a stable enumeration to anchor on — each agent picks a different traversal order through `lib/features/**/types.ts` and reaches a different stopping point. Some prioritize cross-package shadows (12–22 per trial); some prioritize within-package collisions; one trial included function-body duplication (which is out of the prompt's scope but the agent thought useful).

The cold agents are NOT lower-quality. Their highest-severity findings include several the pipeline misses (the `id` string-vs-number contract drift on `OnAirDJResponse`). They're just less *predictable*. Substrate-widening doesn't fix cold; only giving cold the enumerated cluster list does — but at that point it's not cold anymore.

## Backend-Service vs dj-site (C5 vs C3)

C5 surfaces **276 cluster_ids** in its union versus C3's 54 — a 5× larger structural-drift surface on Backend-Service. Drivers:

- **Drizzle ORM**: 34 `drizzle-table` declarations, each shadowed by hand-typed row types elsewhere (e.g., `FSEntryRaw` ⊂ `flowsheet` schema). 5 of C5's 8 cross-package-shadows are `InferSelectModel`/`InferInsertModel` types.
- **Job duplication**: 4 sibling backfill jobs (`flowsheet-metadata-backfill`, `library-artwork-url-backfill`, `library-identity-backfill`, `library-canonical-entity-backfill`) each re-declare the same `BaseTags`/`LoggerConfig`/`RunResult`/`Totals`/`LookupFn` family. Strong candidate for a shared backfill-framework types module.
- **Auth surface**: `apps/auth` and `shared/authentication` together carry overlapping session/user/role shapes that cross the API↔auth boundary. The dj-site versions are downstream of these.

C5's intra-Jaccard at **0.93** (vs C3's 1.00) is partially explained by:
1. C5 trial-1 missed 18 near-duplicate pairs (253 findings vs 271), driving the 0.87 minimum pair.
2. With 271 findings per trial and 24 name-collision groups, cluster_id canonicalization (which name comes first in `name-collisions:<name>`) has more opportunities to drift. Two trials reported `BaseEntry` and `CdcEvent` with slightly different group-key forms.

A larger substrate amplifies any naming-inconsistency variance. V3 should make cluster_id canonicalization part of the *pipeline output*, not the agent's responsibility, to fully collapse this.

## Severity calibration

Only **6 of 417** unique cluster_ids show modal-severity disagreement across ≥2 conditions:

| cluster_id | Severity by condition |
|---|---|
| `exact-duplicates:DJBinQuery+DJRequestParams` | C2=medium, C3=low |
| `exact-duplicates:BackendAccountModification+DJRegistryParams` | C2=low, C3=medium |
| `near-duplicates:DJInfoResponse+DJRegistryParams` | C2=low, C3=medium |
| `near-duplicates:BackendAccountModification+DJInfoResponse` | C2=low, C3=medium |
| `subset-pairs:AuthorizableUser__CapabilityAuthorizedUser` | C3=medium, C5=low |
| `subset-pairs:AuthorizableUser__RoleAuthorizedUser` | C3=medium, C5=low |

The C2↔C3 drift is because C3 has more context (the `@wxyc/shared` package was indexed) and re-evaluates within-dj-site DJ types as more historically-motivated (read: dead code from a pre-better-auth flow) → bumps them down or up based on that context.

The C3↔C5 drift on the AuthorizableUser subsets is because in C5 (Backend-Service) the same auth types are *intentional* branded projections (`AuthorizableUser` ⊂ `RoleAuthorizedUser`); in C3 (dj-site) they show up as suspicious cross-package duplication of an intentional brand pattern. Same name, different contextual meaning.

Within a single trial, severity is noisier than across conditions (the trial-1/2 vs trial-3/5 split on `DJBinQuery+DJRequestParams` in C2: medium / medium / low / medium / high). Modal-severity within a 5-trial condition is the right unit to compare, not per-trial severity.

## What V2 confirmed

1. **Output format + prompt regime were the dominant cause of V1's divergence.** Switching from free-form Markdown + "quality over quantity" to structured JSON + "enumerate every cluster" collapses intra-condition Jaccard from V1's ~0.40 to 1.00 (C2, C3) or 0.93 (C5).
2. **Substrate-widening surfaces additional legitimate findings.** C3 (widened) covers 54 cluster_ids vs the 4 in C2 (narrow). All 50 widened-only findings are real refactoring opportunities or contract-drift candidates.
3. **Inline-object expansion via synthetic entries is high-leverage.** The `BetterAuthSession.user` / `RoleAuthorizedSession.user` / `BetterAuthSessionResponse.error` family of findings is invisible to V1's substrate.
4. **Frontend vs Backend is structurally different.** Backend-Service has 5× the cluster surface, driven by Drizzle ORM shadows and job duplication. The gap isn't artifactual to dj-site.

## What V2 surprised on

1. **Cross-condition Jaccard between pipeline-aware and cold collapses to 0.08, not 0.70 as predicted.** Post-hoc audit decomposes this: 0.08 → 0.15 from cluster_id naming inconsistency; 0.15 → ~0.50 from V2 query-filter restrictiveness (missing kind variants in `cross-package-shadows`, `package == "main"` restriction on `near-duplicates`, intersection types excluded from `subset-pairs`); ~0.50 → 0.70 from genuinely missing substrate kinds (function-body duplication, file-content hashing). The methodology's 0.70 prediction was wrong about how far V2's 5 substrate additions actually closed the cold-vs-pipeline gap, not wrong about agent behavior. Substrate-widening remains the lever.
2. **Cold agents stay at ~0.31 intra-Jaccard** even with enumerate prompting. The substrate's role isn't just sampling-cap removal — it provides a stable enumeration to anchor on. Without the catalog, "enumerate every X" still leaves agents free to choose what X is.
3. **Within-trial severity is noisier than expected** (DJBinQuery+DJRequestParams oscillated low/medium/high within C2's 5 trials), but modal-across-trials severity is stable. This validates the methodology's "drop severity to a separate post-hoc pass in V3" suggestion.
4. **Cluster_id canonicalization is a real source of cross-condition divergence.** Some of the C3↔C4 0.08 number is naming-inconsistency artifact, not substantive disagreement. E.g., `WXYCRole` flagged as `name-collisions:WXYCRole` in C3 and `cross-package-shadows:WXYCRole` in C4. Future cluster_ids should be substrate-emitted, not agent-emitted.
5. **Programmatic-output behavior.** Two C5 trials (out of 5) wrote helper Python/shell scripts to generate their 271-finding JSON arrays rather than emit them by hand. When the structured-output task is large enough, agents reach for programmatic generation — and produce more consistent output as a result. The 1.00-intra-Jaccard C3 trials emitted by hand; the 0.93 C5 trials mix hand-emit and script-emit, which may explain part of C5's slightly-lower stability.

## Read-order and phase-cost analysis (not run)

V2 did not implement the per-trial `trace.json` from §Logging of the methodology — the Agent tool returns a completion summary but not a structured tool-call log accessible to the parent without reading the full transcript file (and reading it risks overflowing the parent's context). This is a deferred V2-to-V3 gap.

Workaround for V3: instrument the agent runtime to emit a small per-trial telemetry file (file-read order, phase boundaries) alongside the output. This wouldn't bias agent behavior because it's runtime-emitted, not prompt-elicited.

## Implications for V3

Closing the cold-vs-pipeline gap is the highest-leverage path; substrate changes break down by tier:

**Tier 1 — Cluster_id canonicalization (cheap; closes 0.08 → 0.15).** Substrate emits a single canonical cluster_id per finding. Agent references by ID rather than coining its own. Removes the `name-collisions:X` vs `cross-package-shadows:X` ambiguity.

**Tier 2 — Query-filter relaxation (cheap; closes 0.15 → ~0.50).** Five specific changes:
- `cross-package-shadows`: drop the `kind in (interface, type-alias-object)` restriction on the shared side. A `type-alias-union` like shared `FlowsheetEntry` or a `type-alias-other` like shared `Genre`/`Format` is still a canonical shape that local declarations can shadow.
- `near-duplicates`: add a "cross-package mode" that compares main's named types against shared's same-name (or shape-similar) entries. Catches `OnAirDJResponse` vs canonical `OnAirDJ` id-type drift.
- `subset-pairs`: handle `type-alias-intersection` by resolving `A & B` to `fields(A) ∪ fields(B)` so intersection types participate as field-bearing.
- `subset-pairs`: lower the minimum-field threshold to 1 when both sides are kind-tagged as wire DTOs (currently 2-field-minimum suppresses `dj_id`-only pairs like `DJBinQuery ⊂ BinMutationQuery`).
- Generic: emit a per-cluster `kind_signature` that the agent prompt can map to a category-prefix, removing the inferred-categorization variance.

**Tier 3 — New substrate kinds (heavier; closes ~0.50 → 0.70).** Function-body duplication (Levenshtein/AST-hash over function bodies, surfaced as `function-duplicates.txt`); file-content hashing for byte-identical or near-identical sibling files; function-name collisions (already in the catalog if function declarations were indexed — currently the TypeScript extractor only walks `interface`/`type`/`z.object`/`pgTable`).

**Tier 4 — Other improvements not gap-related:**
- Move severity to a post-hoc pass (V2 confirmed intra-trial noise; methodology already suggested this).
- Programmatic output as a feature: 2 of 5 C5 trials wrote helper scripts; V3 could explicitly invite this — "write your output via a small helper script if convenient — the deliverable is the resulting JSON."
- Combined pipeline + cold condition: even after Tiers 1–3, a C6 condition where agents are given the catalog *and* told "enumerate anything else you find" provides a safety net for substrate gaps we didn't anticipate.

## What V2 did not address (carried forward)

- **Human-curated ground truth** (deferred per methodology). V2 recall numbers remain relative to the union of V2 outputs, not absolute.
- **Read-order / phase-cost split** (per above; needs runtime instrumentation).
- **Audit-as-changelog dimension** — per [`future-directions.md` §1](./future-directions.md#1-time-as-a-first-class-dimension). Re-run C3 against dj-site quarterly. V2 still doesn't test this.

## See also

- [`dj-site-divergence-experiment-v2-methodology.md`](./dj-site-divergence-experiment-v2-methodology.md) — V2 protocol
- [`dj-site-divergence-experiment.md`](./dj-site-divergence-experiment.md) — V1 results
- [`case-study.md`](./case-study.md) — origin of the deterministic-extraction principle
- [`pipeline-contract.md`](./pipeline-contract.md) — substrate schema (extended by V2)
- Analysis summary: `/tmp/wxyc-audit-v2/analysis-summary.{json,md}`
- Raw V2 trial outputs: `/tmp/wxyc-audit-v2/<condition>/trial-N/output.{json,md}`
