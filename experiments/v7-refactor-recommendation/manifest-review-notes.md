# V7 plant-manifest review notes (§2.5)

Per [`plans/v7-refactor-recommendation-implementation-plan.md`](../../plans/v7-refactor-recommendation-implementation-plan.md) §2.5 and methodology [§10](../../docs/refactor-recommendation-experiment-methodology.md#pre-registration). Reviewer scope: 25 plants in [`plant-manifest.yaml`](plant-manifest.yaml) and [`rubric.yaml`](rubric.yaml).

**Verdict: approved, unconditionally, for Phase C plant-tree generation and Phase D trial execution.** Two non-blocking observations (F1, F2) are recorded as watch-items for downstream phases; neither gates approval. No revisions required to `plant-manifest.yaml` or `rubric.yaml`.

**Artifacts under review (recorded for pre-registration audit trail per §10):**

| Artifact | SHA-256 |
|---|---|
| `plant-manifest.yaml` | `cc2e5a5ef0c0747a82fc05a35ae7df9020183e32a113cd00de7295ac42be4a7f` |
| `rubric.yaml` | `8704ebd317fd06f3bb0a6a5715685b8a6f08899ac97571b500829fcaafef1a77` |

Any subsequent edit to either file invalidates this approval and requires a fresh review pass.

## 1. Do plant categories map to distinct refactors? Does each plant within a category exercise a distinct sub-shape?

**Yes at both levels.** Each category exercises a structurally distinct language-level primitive:

| Cat | Primitive | Substrate signal |
|---|---|---|
| 1 | Lift duplicate to a shared package | `exact-duplicates`, `cross-package-shape-near-duplicates-any` |
| 2 | Lift shared protocol surface to a new parent | `subset-pairs`, `protocol-inheritance-candidates` |
| 3 | Move identical method body to a protocol default | `function-duplicates`, `default-impl-candidates` |
| 4 | Replace one type slot with an associated type | `pat-candidates`, `cross-package-shape-near-duplicates-any` |
| 5 | Replace one type slot with a generic parameter | `function-duplicates` or `generic-struct-candidates` plus the Cat-5 query family |

The Cat 4 PAT vs Cat 5 generic-struct distinction is sharp at the language level (protocol-with-associated-type vs concrete-generic-struct); the structural shapes the substrate surfaces overlap, but the *answers* diverge. Plant 4.1 acknowledges this by listing `generic-parameterization` as a high-weight (0.7) alternative.

**Per-plant distinctness within each category.** Each canonical plant within a category targets a distinct sub-shape — different source-type, n, real-vs-synthesized mix, or domain context — so the trial set does not redundantly score the same primitive four times. Spot-checked all 20 canonicals:

| Plant | Sub-shape that distinguishes it from siblings in the same category |
|---|---|
| 1.1 | SwiftUI.Image extension pair, **cross-layer** (app:WatchXYC ↔ app:iOS), n=2, real |
| 1.2 | AppIntent struct pair, **cross-layer** (Shared/Intents ↔ app:iOS), n=2, real |
| 1.3 | Notification-message 1-field cluster, **n=4 across 3 Shared packages**, real |
| 1.4 | Clock struct pair, same Shared layer, **naming-collision-with-stdlib** specific tolerance |
| 2.1 | Notification-message protocols, **real n=2**, MainActor/Async axis |
| 2.2 | Player protocols, real n=2, **3 moved members** (pause/play/rate) |
| 2.3 | AudioEngine player protocols, real n=2, **6 moved members** |
| 2.4 | AudioPlayer ↔ PlaybackController, real n=2, **7 moved members** (largest shared surface) |
| 3.1 | HSBColor cluster, **real n=3**, init-body identical, hits Swift's init-default-impl limitation |
| 3.2 | BlendMode enums, **real n=2 + 1 synthesized**, displayName-switch body |
| 3.3 | AudioProcessor conformers, real n=2 + 1 synthesized, **existing-protocol target** |
| 3.4 | PlaylistEntry conformers, real n=2 + 1 synthesized, **Decodable init** body |
| 4.1 | NowPlayingItem ↔ PlaycutSelection, **cross-layer**, **real**, Image/UIImage slot |
| 4.2 | TrackContainer ↔ ShowContainer, **fully synthesized**, simple Item slot |
| 4.3 | Repository protocols, fully synthesized, **triple-method shape** (parallels real DiscogsEntityResolver) |
| 4.4 | Loader protocols, fully synthesized, **carries async-throws effect specifiers** |
| 5.1 | HSBColor platformColor, **real n=2 on the same type**, UIColor/NSColor slot |
| 5.2 | fetchInt/fetchString, fully synthesized, **free-function generic** |
| 5.3 | NotificationMessageSequence pair, **real**, generic-struct with **protocol-bound differing** |
| 5.4 | IntCache/StringCache, fully synthesized, **Hashable-constrained generic-struct** |

No two canonicals in the same category collapse to the same sub-shape. Restraint plants (1R–5R) are covered in §3.

## 2. Are alternative answers defensible? Do weight values track real Swift idiomaticity?

**Yes.** The weight schedule clusters in a discrete band consistent with methodology §8's range for partial credit. The calibration heuristic underlying the assignments is:

- **0.7** — alternative is **primary-equivalent in idiomaticity** for the specific cluster shape; near-tie with the primary; an agent choosing this framing should not be penalized much.
- **0.5–0.6** — alternative is **valid Swift but loses one sub-signal** (the protocol-shape angle, the type-slot angle, or an init-default-impl caveat); meaningful partial credit.
- **0.3–0.4** — alternative is **defensible but misses the idiom** (extract-to-common when the protocol-default-impl or PAT shape is the more idiomatic read); low partial credit.

Granularity within the band (0.6 vs 0.7, 0.3 vs 0.4) tracks whether the alternative loses *one* idiomatic signal (the higher value) or *one signal plus a sub-signal* (the lower value). The band is intentionally coarse — finer granularity would over-specify a rubric whose judgment-heavy parts already route to the panel per §8 Case 5.

**Per-canonical alternative-weight defense (spot-checked all 20 canonicals; entries with no alternatives omitted):**

| Plant | Alternative | Weight | Defense |
|---|---|---|---|
| 1.1 | `extract-to-common` (existing package as target) | 0.7 | Same primitive, just a different target-package choice; primary-equivalent if upstream-direction is preserved. |
| 1.2 | `extract-to-common` (Shared/Intents) | 0.7 | Same primitive, simpler refactor than a new package; primary-equivalent. |
| 1.2 | `protocol-inheritance` | 0.4 | Misses that AppIntent is already the parent; defensible but reads the wrong axis. |
| 1.3 | `protocol-inheritance` | 0.7 | NotificationMessage parent protocol is arguably stronger than struct lift for 1-field surface; primary-equivalent. |
| 1.4 | `protocol-inheritance` | 0.6 | Idiomatic Swift for 1-field surface but structurally distinct from extract; loses the "single type per package" angle. |
| 2.1 | `extract-to-common` | 0.4 | Loses protocol shape, but the lifted shared surface still resolves the duplication. |
| 2.2 | `extract-to-common` | 0.4 | Same as 2.1 — protocol shape lost. |
| 2.3 | `extract-to-common` | 0.4 | Same as 2.1 — protocol shape lost. |
| 2.4 | `extract-to-common` | 0.4 | Same as 2.1 — protocol shape lost. |
| 3.1 | `composition` | 0.6 | Composing an HSBValues field correctly handles Swift's init-default-impl limitation; arguably more idiomatic than the protocol-default-impl primary, hence above 0.5. |
| 3.1 | `extract-to-common` | 0.4 | Extract-to-common of the init body without composition misses the language limitation; standard 0.4-for-extract floor. |
| 3.2 | `generic-parameterization` | 0.5 | Cat-5 angle is valid but loses the displayName-default-impl angle; mid-band because it's structurally a real alternative read. |
| 3.2 | `extract-to-common` | 0.3 | Helper extraction misses the protocol-default-impl idiom; below the 0.4 floor because there's no language constraint forcing the alternative. |
| 3.3 | `extract-to-common` | 0.3 | Helper extraction also ignores the existing AudioProcessor protocol — worse than 3.2's miss. |
| 3.4 | `extract-to-common` | 0.3 | Same as 3.3 — ignores existing PlaylistEntry protocol. |
| 4.1 | `generic-parameterization` | 0.7 | Struct pair: PAT and generic-struct are near-tied; PAT wins on the protocol-shaped read. |
| 4.1 | `extract-to-common` | 0.4 | Misses both PAT and generic angle. |
| 4.2 | `generic-parameterization` | 0.7 | Same as 4.1 — near-tie. |
| 4.2 | `extract-to-common` | 0.4 | Same as 4.1. |
| 4.3 | `generic-parameterization` | 0.6 | Triple-method shape leans more protocol-idiomatic than 4.1/4.2's struct pair, so PAT is a stronger primary; alternative drops one notch. |
| 4.4 | `generic-parameterization` | 0.6 | Same as 4.3 — effect-specifier preservation is the protocol-idiomatic angle. |
| 5.1 | `extract-to-common` | 0.4 | Typealias without generic function leaves two parallel methods; standard 0.4. |
| 5.2 | `extract-to-common` | 0.4 | Free helper misses generic idiom; standard 0.4. |
| 5.3 | `protocol-inheritance` | 0.5 | Lifting Plant 2.1's missing parent is a real prerequisite step toward the generic-struct collapse — half-credit because it's part-of-answer but doesn't itself collapse the structs. |
| 5.3 | `extract-to-common` | 0.3 | Shared 3-field extraction misses the type-slot parameterization. |
| 5.4 | `extract-to-common` | 0.4 | Extracting CacheEntry alone leaves outer Cache types parallel; standard 0.4. |

Cat 1 plants consistently list `subclass-lift` only in `wrong_answers` (with the "structs don't subclass in Swift" reason), and Cat 2/4 plants list it for protocols similarly. The language-level error class is enumerated as wrong, never as alternative — no miscalibrations identified.

## 3. Are restraint twins distinguishable from their canonicals only via context flags?

**Yes for every restraint, with the criterion read carefully.** The methodology §10 question is whether the *substrate-visible cluster the agent sees* requires the named context flag to discriminate the no-action answer from the action answer its category's canonical would produce. The criterion is **not** that the restraint's `source_files` share the canonical's field-level shape — that's neither feasible (1R↔1.1 are entirely different SwiftUI surfaces) nor what §10 asks (§10 says "distinguishable … *only* via context flags" referring to discrimination signal, not source-text identity). Methodology §13.2 confirms this read: it describes a good restraint as one where "the cluster shape is otherwise so strongly action-shaped that an agent without weighting discipline will recommend action anyway" — i.e., shape-look-alike *within the restraint's own cluster*, with the context flag as the sole discriminator from action.

Per-restraint check. For each, the **substrate-cluster shape** column shows what the agent sees as a candidate refactor; the **discriminator** column is the *only* signal that drives the no-action answer.

| Restraint | Pair | Substrate-cluster shape | Discriminator | Field-shape distinguishers from canonical? |
|---|---|---|---|---|
| 1R | 1.1 | Two identical `MetricRow` SwiftUI structs (DebugPanel ↔ WallpaperSampleApp) — exact-duplicate cluster | `is_sample_app=true` on the WallpaperSampleApp copy | None used to discriminate. The cluster shape (exact-duplicate, cross-package) matches what 1.1 surfaces; only `is_sample_app` says "don't lift". |
| 2R | 2.1 | `_Plant_MockNotificationMessage` clustered with at least one of 2.1's children via `subset-pairs` / `protocol-inheritance-candidates` | `is_test=true` (CoreTesting target) | None used to discriminate. By design (§6.3), the mock mirrors 2.1's parent shape; only the target-library context flag says "don't lift". |
| 3R | 3.1 | Three `.stub` cluster (Breakpoint, Talkset, synthesized PlaycutStub) under `function-duplicates` / `default-impl-candidates` — identical stub-init bodies | `is_mock=true` (PlaylistTesting target, stub suffix) | None used to discriminate. Within the restraint, the three bodies are identical — same signal shape as 3.1's three identical HSBColor inits. Only the target-library + naming context says "don't promote to protocol default". |
| 4R | 4.1 | `CPUSessionEvent` ↔ `CPUSessionEventProxy` 87% near-duplicate under `pat-candidates` / `cross-package-shape-near-duplicates-any` | `is_mock=true` (AnalyticsTesting target, Mock prefix) | None used to discriminate. Within the pair, the shape rhyme is the same near-duplicate signal 4.1 surfaces; only the target-library + naming context says "don't introduce a PAT". |
| 5R | 5.1 | Same cluster as 3R, scored under Cat-5 lens (generic-function over the two `.stub` bodies) | `is_mock=true` (PlaylistTesting target, stub suffix) — same as 3R | None used to discriminate. Same cluster, same context flag, different lens. |

In every restraint, the **intra-cluster shape match** (or near-match) is exact enough that any agent without the context-flag weighting will recommend the action answer — which is the §13.2 calibration target. **No restraint smuggles in a field-level shape-distinguisher** as a backup signal: removing the `is_*` context flag would (correctly) collapse the restraint into an action answer matching the canonical's category, demonstrating the flag is load-bearing. The methodology pattern is intact.

A specific note for 2R: it is the only restraint that's a single synthesized protocol file rather than a 2-file or 3-file cluster within its own restraint scope. The substrate must cluster it with 2.1's children for the restraint to *appear at all*. That's covered as F1 below.

## 4. Does any plant accidentally test two categories at once?

**No accidental cases.** Three cross-category overlaps exist in the manifest, all **deliberate** and acknowledged in the manifest's `# Cross-category overlap notes` footer (`plant-manifest.yaml` L1043–1051):

- **Plant 2.1 ↔ Plant 5.3** share the MainActor/Async notification substrate cluster. **This is intentional cross-lens coverage by design** — the two plants exercise different substrate queries (`subset-pairs` / `protocol-inheritance-candidates` for 2.1 vs `generic-struct-candidates` for 5.3); the agent sees different clusters even though the underlying source files overlap, and each is scored under its own category lens independently. Documented in `plant-source-candidates.md` Cross-checks. The pre-V7 PR-#21 draft had an additional Cat-5 function plant on the iterator init that was *removed* specifically to defuse the multi-lens-on-one-cluster concern, leaving exactly this one intentional 2.1↔5.3 overlap.
- **Plant 3.2 has a Cat-5 struct angle.** 3.2 scores Cat-3 only; the Cat-5 struct angle is covered by a separate synthesized plant (**5.4**, IntCache/StringCache). No double-scoring.
- **Plant 3R ↔ Plant 5R** share the PlaylistTesting stub cluster, scored under different category lenses (Cat-3 default-impl restraint vs Cat-5 generic-fn restraint). Both answer `no-action`. The test is whether the agent reaches no-action via `default-implementation`-restraint reasoning (3R) or `generic-parameterization`-restraint reasoning (5R), so the two restraints measure distinguishable competencies even though they share a source cluster.

In none of the three is a single plant scored twice for the same recommendation. The accidental two-category-test failure mode — where an agent's correct Cat-N answer happens to also Case-1 against a Cat-M plant's primary — does not occur in the current manifest.

## Flagged observations (non-blocking)

These don't gate approval but should be remembered when Phase C, D, and E run:

### F1. Plant 2R depends on §6.3 inheritance-edge resolution surfacing the cluster

**Observation.** 2R is a single synthesized protocol file. It surfaces in `subset-pairs` / `protocol-inheritance-candidates` only when the substrate clusters `_Plant_MockNotificationMessage` with at least one of 2.1's children (`MainActorNotificationMessage`, `AsyncNotificationMessage`).

**Why this matters.** Until §6.3 (protocol-inheritance edges + resolution) is fully wired and re-runs against the planted tree show 2R appearing in at least one expected query, the restraint isn't actually testing what it claims to test. Phase C's plant-recall sanity check (§4.4 in the plan) catches this — if 2R doesn't surface, mark `expected_substrate_gap: true` per the V6 precedent or refactor 2R to a pair.

**Action.** Re-run plant-recall sanity check (§4.4) once §6.3 lands and confirm 2R appears in ≥1 expected substrate signal. If it doesn't, fix in a follow-up before Phase D pre-flight. This is a downstream-phase verification step, not a manifest defect; approval is not conditional on the outcome — if Phase C surfaces the gap, the remediation is a small follow-up amendment, not a re-review.

### F2. `specifics_tolerance` flags are documented but not auto-scorer-enforced

**Observation.** Each canonical carries one or more `specifics_tolerance` flags (e.g., `target_package_must_be_upstream_of_all_consumers: true`, `acknowledging_init_cannot_default_impl_directly_acceptable: true`). These are human-readable annotations of the scoring nuance, but the auto-scorer's current MVP scope (per the scorer's documented limits and rubric §74–82) consumes only the closed-set schema; per-flag tolerance handling routes through the panel. A recommendation that names a downstream package as the extraction target on Plant 1.1 will Case-1 against the closed-set schema and only fail when a panel member catches the upstream-direction violation.

**Why this matters.** It's not a manifest defect — it's a calibrated scope choice — but the panel review (Phase E §7.2) needs to know to look for these violations because the auto-scorer won't flag them.

**Action.** Add to the panel-review checklist: when scoring a Case-1 (primary-match) recommendation, cross-check the recommendation's specifics against each canonical's `specifics_tolerance` keys and flag any violation. Tracking ticket: file as a follow-up issue if the panel finds this pattern fires more than ~2× across the trial set.

## Approval

Manifest and rubric **approved unconditionally** for Phase C plant-tree generation and Phase D trial execution at the hashes recorded above. F1 and F2 are tracked watch-items for Phase C and Phase E respectively; neither makes this approval provisional. No revisions required to `plant-manifest.yaml` or `rubric.yaml`.
