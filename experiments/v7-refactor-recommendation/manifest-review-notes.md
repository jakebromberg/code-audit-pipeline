# V7 plant-manifest review notes (§2.5)

Per [`plans/v7-refactor-recommendation-implementation-plan.md`](../../plans/v7-refactor-recommendation-implementation-plan.md) §2.5 and methodology [§10](../../docs/refactor-recommendation-experiment-methodology.md#pre-registration). Reviewer scope: 25 plants in [`plant-manifest.yaml`](plant-manifest.yaml) and [`rubric.yaml`](rubric.yaml).

**Verdict: approved with two flagged observations.** None of the observations is blocking; both are recorded so the trial-execution and panel-grading phases know what to watch.

## 1. Do plant categories map to distinct refactors?

**Yes.** Each category exercises a structurally distinct primitive:

| Cat | Primitive | Substrate signal |
|---|---|---|
| 1 | Lift duplicate to a shared package | `exact-duplicates`, `cross-package-shape-near-duplicates-any` |
| 2 | Lift shared protocol surface to a new parent | `subset-pairs`, `protocol-inheritance-candidates` |
| 3 | Move identical method body to a protocol default | `function-duplicates`, `default-impl-candidates` |
| 4 | Replace one type slot with an associated type | `pat-candidates`, `cross-package-shape-near-duplicates-any` |
| 5 | Replace one type slot with a generic parameter | `function-duplicates` or `generic-struct-candidates` plus the Cat-5 query family |

The Cat 4 PAT vs Cat 5 generic-struct distinction is sharp at the language level (protocol-with-associated-type vs concrete-generic-struct); the structural shapes the substrate surfaces overlap, but the *answers* diverge. Plant 4.1 acknowledges this by listing `generic-parameterization` as a high-weight (0.7) alternative — agents that choose either framing for a struct pair score reasonably; the primary answer rewards the protocol-shaped read for that specific case.

## 2. Are alternative answers defensible? Do weight values track real Swift idiomaticity?

**Yes, with two-sigma confidence.** Spot-checked all 20 canonical plants. The weight schedule clusters around 0.3–0.7, consistent with methodology §8's range for partial credit. Notable calibration choices that look correct:

- **Plant 3.1 (HSBColor init)** lists `composition` at weight **0.6** above `extract-to-common` at 0.4 — correctly reflects that Swift cannot default-implement designated initializers in protocol extensions, so a composed `HSBValues` field is the idiomatic answer. The `specifics_tolerance.acknowledging_init_cannot_default_impl_directly_acceptable: true` flag carries the same caveat into auto-scoring.
- **Plant 1.3 (Notification-message cluster)** lists `protocol-inheritance` at **0.7** with the note that a `NotificationMessage` parent protocol with `static var name` is arguably stronger than a struct lift — accurate for a 1-field surface where the protocol shape carries semantic weight.
- **Plant 4.1 (NowPlayingItem ↔ PlaycutSelection)** lists `generic-parameterization` at **0.7** — both framings work for struct pairs; PAT wins on the protocol-shaped read.
- Cat 1 plants consistently list `subclass-lift` only in `wrong_answers` (with the "structs don't subclass in Swift" reason), and Cat 2/4 plants list it for protocols similarly. The language-level error class is correctly enumerated as wrong, never as alternative.

No miscalibrations identified.

## 3. Are restraint twins distinguishable from their canonicals only via context flags?

**Yes, for the intra-pair shape match that's what the criterion actually tests.** The §10 criterion is about whether the *substrate-visible cluster the agent sees* requires the context flag for discrimination — not whether the restraint and its category's canonical share the same field-level shape (they don't have to, and 1R↔1.1 demonstrably don't).

Per-restraint check (the **discriminator** column is what the agent must use to reach the no-action answer):

| Restraint | Cluster | Discriminator |
|---|---|---|
| 1R | `MetricRow` (DebugPanel) ↔ `MetricRow` (WallpaperSampleApp) | `is_sample_app=true` on WallpaperSampleApp |
| 2R | `_Plant_MockNotificationMessage` clustered with 2.1's children via `subset-pairs` | `is_test=true` (CoreTesting target) |
| 3R | `Breakpoint.stub` / `Talkset.stub` / `_Plant_PlaycutStub` (PlaylistTesting) | `is_mock=true` (Testing target, stub suffix) |
| 4R | `CPUSessionEvent` ↔ `CPUSessionEventProxy` | `is_mock=true` (AnalyticsTesting target, Mock prefix) |
| 5R | Same cluster as 3R, scored under Cat-5 lens | `is_mock=true` (as 3R) |

In every restraint, the intra-pair (or intra-triple) shape match is exact or near-exact, and the context flag is the *only* signal that says "don't lift this." That matches the §10 intent.

## 4. Does any plant accidentally test two categories at once?

**No accidental cases.** Three deliberate cross-category overlaps are acknowledged in the manifest's cross-checks footer, and each is one of these patterns:

- **Plant 2.1 ↔ Plant 5.3** share the MainActor/Async notification cluster. The two plants exercise different substrate queries (`subset-pairs` / `protocol-inheritance-candidates` vs `generic-struct-candidates`); the agent sees different clusters, scored independently.
- **Plant 3.2** has a Cat-5 struct angle. It scores Cat-3 only; the Cat-5 angle is covered by a separate plant (**5.4**).
- **Plant 3R ↔ Plant 5R** share the PlaylistTesting stub cluster, scored under different category lenses. Both answer `no-action`; the test is whether the agent reaches it via `default-implementation` restraint-reasoning (3R) or `generic-parameterization` restraint-reasoning (5R).

In none of these is the same plant scored twice for the same recommendation.

## Flagged observations (non-blocking)

These don't block approval but should be remembered when Phase D/E runs:

### F1. Plant 2R depends on inheritance-edge resolution being live

**Observation.** 2R is the only restraint that's a single synthesized protocol file. It surfaces in `subset-pairs` / `protocol-inheritance-candidates` only when the substrate clusters `_Plant_MockNotificationMessage` with at least one of 2.1's children (`MainActorNotificationMessage`, `AsyncNotificationMessage`).

**Why this matters.** Until §6.3 (protocol-inheritance edges + resolution) is fully wired and re-runs against the planted tree show 2R appearing in at least one expected query, the restraint isn't actually testing what it claims to test. Phase C's plant-recall sanity check (§4.4 in the plan) is the gate that catches this — if 2R doesn't surface, mark `expected_substrate_gap: true` per the V6 precedent or refactor 2R to a pair.

**Action.** Re-run plant-recall sanity check (§4.4) once §6.3 lands and confirm 2R appears in ≥1 expected substrate signal. If it doesn't, fix in a follow-up before pre-flight.

### F2. `specifics_tolerance` flags are documented but not auto-scorer-load-bearing

**Observation.** Each canonical plant carries one or more `specifics_tolerance` flags (e.g., `target_package_must_be_upstream_of_all_consumers: true`, `acknowledging_init_cannot_default_impl_directly_acceptable: true`). These are human-readable annotations of the scoring nuance, but the auto-scorer's current MVP scope (per the scorer's documented limits and rubric §74–82) consumes only the closed-set schema; per-flag tolerance handling routes through the panel. A recommendation that names a downstream package as the extraction target on Plant 1.1 will Case-1 against the closed-set schema and only fail when a panel member catches the upstream-direction violation.

**Why this matters.** It's not a manifest defect — it's a calibrated scope choice — but the panel review (Phase E §7.2) needs to know to look for these violations because the auto-scorer won't flag them.

**Action.** Add to the panel-review checklist: when scoring a Case-1 (primary-match) recommendation, cross-check the recommendation's specifics against each canonical's `specifics_tolerance` keys and flag any violation. Tracking ticket: file as a follow-up issue if the panel finds this pattern fires more than ~2× across the trial set.

## Approval

Manifest approved for Phase C plant-tree generation and Phase D trial execution, subject to F1 (plant-recall check after §6.3 merges) and F2 (panel checklist amendment). No revisions required to `plant-manifest.yaml` or `rubric.yaml` at this time.
