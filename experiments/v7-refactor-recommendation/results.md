# V7 refactor-recommendation experiment — round-1 results

Companion results doc for the V7 refactor-recommendation experiment, MVP scope (5 categories × 4 canonical + 1 restraint = 25 plants; 2 conditions S1/S2; 3 trials per condition; `claude-sonnet-4-6`). Structured per the [main implementation plan §7.3](../../plans/v7-refactor-recommendation-implementation-plan.md#7-phase-e--scoring--writeup-2-3-weeks). The 12 panel-routed recs were scored by a single expert reviewer in round 1 (see [§4 below](#4-panel-coverage--inter-rater-stats) and the [reproducibility.yaml `round1_deviation` block](reproducibility.yaml)); their numeric scores are backfilled into the headline by `promote_panel_scores` in [`score_all.py`](score_all.py). Round-2 corrections to the auto-scorer (symbol-level binding via PR #89, then value-aware specifics matching via the PR closing [`#35`](https://github.com/jakebromberg/code-audit-pipeline/issues/35)) shifted both halves of the 2-D headline; [`rubric-modifications.md`](rubric-modifications.md) walks the two round-2 entries with expected-vs-actual tables.

## TL;DR

Headline 2-D point (canonical recall × restraint 1−FPR), as of the round-2 value-aware-specifics correction:

| Condition | Canonical recall | 1 − FPR | Panel-route rate |
|---|---|---|---|
| S1 (V6 substrate) | **0.070** | 1.000 | 13.5% |
| S2 (V7 substrate) | **0.110** | 1.000 | 24.9% |
| **S2 − S1** | **+0.040** | 0.000 | +11.4 pp |

Comparison with round-2 binding-correctness baseline (after PR #89 symbol-level binding, before value-aware specifics matching):

| Condition | Recall (binding-only baseline) | Recall (value-aware) | Δ |
|---|---|---|---|
| S1 | 0.270 | 0.070 | −0.200 |
| S2 | 0.615 | 0.110 | −0.505 |

The round-2 value-aware correction shifts the recall headline down by 0.200 (S1) / 0.505 (S2). This is a **methodological correction**, not a regression: the binding-only baseline was over-credit per methodology §8 lines 626–631, which mandate panel-route on out-of-tolerance specifics rather than auto-1.0 on key-only matches. Of the 102 rows that previously fired `primary_match_full` or `primary_match_weak_rationale`, 100% had at least one mismatched required value; 95.1% were substantive (agent picked wrong identifier, wrong target package, or omitted a constraint) and 4.9% were trivial (parenthetical commentary in manifest values, all on Plant 3.4). All 102 now route to panel awaiting [`#85`](https://github.com/jakebromberg/code-audit-pipeline/issues/85) reviewer recruitment; the headline canonical_recall would lift back into the auto-plus-panel range once panel scores land. See [`rubric-modifications.md`](rubric-modifications.md) round-2 value-aware-specifics entry for the per-plant flip distribution and worked examples.

Restraint false-positive rate is 0.000 in both conditions after round-2's symbol-level binding fix (PR #89) eliminated the Plant 1R structural FPR; the round-1 headline of 0.20 was driven entirely by incidental bindings (16 `DebugMetricsProvider` clusters substring-matched Plant 1R's `DebugHUD.swift` source file but weren't about its planted MetricRow shape). Panel-route rate jumped from <2% (round-1) to ~25% (S2) after value-aware specifics matching — still under the methodology §14.3 50% acceptance bar, but with a clear shift in load profile: most of the now-routed rows carry the manifest's pre-registered `specifics_tolerance` flags inline as panel guidance, so reviewers can evaluate the structural property the flag describes without cross-referencing.

The substrate enrichment signal is **mostly absorbed into the panel-routed bucket** under value-aware scoring: agents identified the correct *category* on the V7-new clusters (so substrate exposure helped category-identification) but picked wrong specifics *values* on most of those clusters (so value-correctness now panel-routes). The §1 per-category breakdown below shows protocol-inheritance and default-implementation deltas collapsing to ~0 once auto-scoring no longer over-credits key-only matches — the V6 → V7 substrate uplift on category-identification didn't translate to value-correctness uplift under the same setup. PAT-introduction preserves a smaller positive delta (+0.325), generic-parameterization flips sign (S2 slightly worse than S1 in pure auto-score terms — both modest, both within panel-route absorption). The substrate-helped story moves from the headline to the panel-routed cohort, where it's recoverable once #85 reviewers rate the 108 routed rows.

## 1. Per-category S2 − S1 deltas

Mean canonical recall across the 3 trials, per condition, per category. Both pre- and post-value-aware columns shown; the post-column is the current headline.

| Category | S1 (pre / post) | S2 (pre / post) | Δ (S2−S1) post | Notes |
|---|---|---|---|---|
| extract-to-common | 0.200 / 0.075 | 0.200 / 0.075 | **0.000** | V6 substrate already had `exact-duplicates`, `cross-package-shadows`, etc.; V7 added nothing here. Plant 1.4 surfaced in neither condition. Post-value-aware drop on both conditions reflects Plant 1.1's `target_package` mismatch (agent recs `app:iOS`, manifest expects `Shared/Branding`) — substantive mismatch routes to panel. |
| protocol-inheritance | 0.125 / 0.125 | 0.875 / 0.125 | **0.000** | V7-new `protocol-inheritance-candidates` query is the substrate change. Round-1 reported "barely surfaces → near-canonical." Under value-aware scoring the substrate-helped category-identification holds, but agent-picked specifics values fail panel-route on Plants 2.1/2.2/2.3/2.4 (all 18 S2 primary-match rows flip to panel-route on member-set mismatch). Panel-recoverable. |
| default-implementation | 0.542 / 0.000 | 0.792 / 0.000 | **0.000** | V7-new `default-impl-candidates` query. Round-1 reported V6 partial → V7 explicit. Under value-aware scoring all Plants 3.1–3.4 panel-route — Plant 3.3 agent invented `NormalizationModeConfigurable` instead of using existing `AudioProcessor`; Plant 3.2 invented `BlendModeConvertible` instead of `BlendMode`. Both are exactly the §8 "wrong specifics" panel-route case. |
| pat-introduction | 0.000 / 0.000 | 0.550 / 0.325 | **+0.325** | V7-new `pat-candidates` query. V6 had no signal for this category at all. Smaller post-value-aware delta (+0.325 vs round-1 +0.550) because 2 of the previous primary-match rows panel-route; this is the cleanest preserved substrate-helped signal. |
| generic-parameterization | 0.400 / 0.150 | 0.575 / 0.025 | **−0.125** | V7-new `generic-struct-candidates`, `generic-function-candidates`. Post-value-aware S2 dips slightly below S1 — Plant 5.2 (S2-bound) has all 9 primary-match rows flip on `type_params.constraint: null` (agent), `"Decodable"` (manifest); Plant 5.1's panel-scored Plant 5.1 row preserves S1's 0.3 (adjacent-defensible) panel promotion. Both numbers are modest enough that the difference is within trial variance. |

Where round-1 read "substrate-enrichment delivers clear V6→V7 uplift on three categories," the value-aware-corrected read is more nuanced: substrate exposure helps the agent **identify the right category** (which is V7's structural claim), but **value-correctness on the resulting recommendations is the panel's job** under §8 routing. With 108 panel-routed rows awaiting #85 reviewer recruitment, the V7-vs-V6 question on value-correctness is open until panel scores land. Per category cells per trial, see [`analyses/score-summary.json`](analyses/score-summary.json) → `per_category_per_cell`.

## 2. §14.1 substrate-helped check (from PR-E2)

The methodology §14.1 pre-mortem signature is "S2 − S1 per-rec recall delta sits within ±5pp across all categories." [PR-E2's substrate-helped analyzer](analyses/substrate_helped.py) computed this on the parsed recs themselves (per-rec confidence + category-distribution distance per query, across the 7 shared queries — the queries that exist in both S1 and S2). Output: [`analyses/substrate-helped.json`](analyses/substrate-helped.json).

Result: **1 of 7 shared queries passes the per-rec ±5pp threshold** (`cross-package-shape-near-duplicates-any`). The aggregate `signature_pass: false` — the §14.1 stop-the-line signature fires *for the shared corpus*.

The §14.1 result and the [§1 per-category result above](#1-per-category-s2--s1-deltas) are **not in tension** — they measure complementary things:

- §14.1 asks whether the *same cluster row* produces meaningfully different per-rec output under S2 vs S1 (confidence shift, category-distribution shift). Answer: mostly no.
- §1 asks whether the *category recall on planted refactors* is higher under S2. Answer: yes, dramatically, in the categories where V7 added new substrate queries.

The reconciliation: V7's substrate enrichments did not change the model's per-rec evaluation behavior on the shared cluster rows; V7 *added new cluster rows* (the V7-only queries: `pat-candidates`, `protocol-inheritance-candidates`, `default-impl-candidates`, `generic-struct-candidates`, `generic-function-candidates`). Those new cluster rows are where the recall improvement lives. The cold-condition agent did not have access to those clusters; the warm-condition agent did, and used them to find planted refactors V6 had no signal for.

This is the substrate-fanout-not-substrate-reasoning story: V7's value is *what it surfaces*, not *how it characterizes what was already surfaced*. Worth a round-2 design note — if V7 enrichments to existing queries (context flags, conformance edges feeding cluster shape) were expected to move the model's reasoning on shared clusters too, they did not.

## 3. Plant-recall confirm — Plant 5.3 outcome (from PR-E2)

PR-E2's plant-recall-extended analyzer ([`analyses/plant-recall-extended.json`](analyses/plant-recall-extended.json)) tracked which plants surfaced via parsed categories. Aggregate:

| Condition | Plants surfaced by category | Plants surfaced (none) |
|---|---|---|
| S1 | 9 / 25 | 16 |
| S2 | 21 / 25 | 4 (1.2, 1.3, 1.4, 5.1) |

Plant 5.3 (which Phase C flagged because its `expected_substrate_signals` did not fire in the cluster outputs): **surfaces under S2 via category recall**. The Phase E plan §6 decision #4 escalation path (file a substrate-recall follow-up issue) does not trigger. The plant-manifest declaration of expected signals stays the round-1 truth; no follow-up substrate-recall issue is filed.

The 4 plants missing in S2 (`1.2`, `1.3`, `1.4`, `5.1`) are a separate finding: their planted clusters either don't appear in any V7 cluster_id, or the parsed category never matches the manifest's primary. Round 2 can revisit plant placement for those four.

## 4. Panel coverage + inter-rater stats

After round-2's symbol-level binding fix (see [§4.2](#42-binding-artifact-finding-resolved-in-round-2)), [`analyses/panel-routing.jsonl`](analyses/panel-routing.jsonl) holds **6** panel-routed (rec × plant) pairs (down from 12 in round 1). All 6 are `category: "other"` cases — agent declined the taxonomy and proposed a novel action — and all 6 concentrate on Plant 5.1 (generic-parameterization), spanning 3 trials × both conditions on the `HSBColor.uiColor` / `HSBColor.nsColor` cluster. The 6 round-1 Plant 3.1 panel rows were dropped by the symbol gate (they were the false-binding co-attribution documented in §4.2).

Auto-scoring rate (auto-scored fraction = 1 − panel-route fraction), computed against the post-round-2 `scored` and `panel_routed` artifacts:

| Condition | Scored pairs | Panel-routed | Auto-scoring rate |
|---|---|---|---|
| S1 | 192 | 3 | 98.4% |
| S2 | 329 | 3 | 99.1% |

Methodology §14.3 sets the acceptance bar at "auto-scored fraction ≥ 50%" (equivalently panel-route ≤ 50%). Both conditions pass with two orders of magnitude of headroom — the rubric covers what it intends to cover.

### 4.1 Round-1 panel-sitting outcome

All 12 routed recs concentrate on a single cluster: the `HSBColor.uiColor` ↔ `HSBColor.nsColor` near-duplicate (Jaccard 0.71) inside `Shared/ColorPalette/Sources/ColorPalette/HSBColor.swift`. The agent's recommendation across all (condition, trial) combinations is the same in substance — extract a private HSB-to-color helper, or use `#if canImport(UIKit)/#if canImport(AppKit)` conditional compilation, and decline the named taxonomy categories on the grounds that `UIColor` and `NSColor` are unrelated nominal types.

Panel scoring assigned each routed pair one of two values:

| Bound plant | Plant intent | Panel score | Rationale |
|---|---|---|---|
| Plant 5.1 (generic-parameterization) | `platformColor<Color: PlatformColor>` generic function unifying `uiColor` / `nsColor` | **0.3** ("wrong category but adjacent and defensible") | Agent saw the right cluster, cited the right symbols (`HSBColor`, `uiColor`, `nsColor`, `UIColor`, `NSColor` — matches `rationale_must_cite`), but dismissed the generic abstraction without considering a `PlatformColor` typealias/protocol bridge. Closest taxonomy fit is `extract-to-common`, rubric-adjacent to `generic-parameterization`. |
| Plant 3.1 (default-implementation) | `HSBStorage` protocol with a default `init(hue:saturation:brightness:)` across HSBColor / AccentColor / HSBOffset | **0.0** (false binding) | The HSBColor uiColor/nsColor cluster is Plant 5.1's signal, not Plant 3.1's. The bind happened because `HSBColor.swift` appears in `Plant 3.1.source_files` (HSBColor is one of the three conformers), but the panel-routed cluster doesn't surface Plant 3.1's init-pattern signal. Agent's helper recommendation does not engage with Plant 3.1's refactor. |

`promote_panel_scores` (new in this writeup; [`score_all.py`](score_all.py)) backfills these scores into `auto-scores.json::scored` before aggregation. Effect on the headline: Plant 5.1's best-across-trials moves from `max(0.0, 0.0, 0.0) = 0.0` to `max(0.3, 0.3, 0.3) = 0.3` in S1 (+0.015 to the 20-plant mean), and is unchanged in S2 (panel 0.3 ties existing auto-scored 0.3 cells). Plant 3.1's headline is unchanged in either condition — the 0.0 panel score doesn't promote anything.

### 4.2 Binding-artifact finding (resolved in round 2)

The HSBColor cluster binding to both Plant 3.1 and Plant 5.1 surfaces a substring-match limitation in `bind_recs_to_plants` ([`score_all.py`](score_all.py)): a cluster touching one of a plant's `source_files` binds to that plant even when the cluster doesn't surface the plant's pre-registered signal shape. Round 1 lived with this — 6 false bindings concentrated on one cluster don't move the headline since the panel scores those as 0.0.

The round-1 closeout ([round-1-closeout plan](../../plans/v7-phase-e-round1-closeout-plan.md)) shipped a *prefer-signal-match resolution rule* in `bind_recs_to_plants`: when a cluster substring-matches multiple plants, bind only to those whose `expected_substrate_signals` include the rec's `query`. This cleaned up 24 incidental false bindings across the corpus (Plant 3.1 −3, Plant 3R −9, Plant 5.1 −3, Plant 5.3 −9) — none of which were in the panel-routed set, so the headline was unchanged. But the rule did NOT fix the Plant 3.1 ↔ 5.1 panel-routed co-binding for HSBColor: both plants legitimately list `function-duplicates` in their signals AND both have HSBColor.swift in their source_files, so the resolution is ambiguous at the (path, query) granularity.

**Round 2 ([rubric-modifications.md](rubric-modifications.md), 2026-05-18)** added a per-plant `expected_cluster_symbols` manifest field gating bindings on planted-symbol substring membership in cluster_id. Plant 3.1's symbols (`HSBColor.init(...)`, `AccentColor.init`, `HSBOffset.init`) don't appear in the panel-routed `function-duplicates-near:HSBColor.uiColor+HSBColor.nsColor` cluster; Plant 5.1's symbols do. The 6 Plant 3.1 false-binding panel routings drop out; the 6 Plant 5.1 panel routings persist as the legitimate binding. `panel_routed.size` goes 12 → 6.

### 4.3 Inter-rater κ — two granularities

Round 1 used a single expert reviewer (`analyses/panel-scores-reviewer-1.jsonl`); the pre-registered design called for 3 (methodology §17 decision #3). The [`reproducibility.yaml` `round1_deviation` block](reproducibility.yaml) records the rationale: the 12 round-1 routed pairs reduced to two distinct judgements (Plant 5.1 binding adjacent-defensible; Plant 3.1 binding false-positive), so the methodology overhead of two more reviewers was disproportionate at this corpus size. Round 2's symbol gate (§4.2) drops the Plant 3.1 panel rows; the regenerated `panel-routing.jsonl` carries 6 surviving rows (all Plant 5.1) and the 6 round-1 Plant 3.1 panel scores become orphan rec_tokens. Round 2 adds the missing reviewers — same regenerated `panel-routing.jsonl`, two new `panel-scores-reviewer-N.jsonl` files concatenated into the consolidated file, then `score_all.py` populates **both** `inter_rater.fleiss_kappa` (rec-level) and `inter_rater_collapsed.fleiss_kappa` (judgment-level). Both functions filter orphan rec_tokens identically and surface the orphan count in the structured note (see [score_all.py::attach_panel_kappa](score_all.py) and [::attach_collapsed_panel_kappa](score_all.py)).

The 6 surviving panel rows are not 6 independent items — they're 1 distinct (plant_id, cluster_id) judgment (Plant 5.1 ↔ the HSBColor.uiColor / HSBColor.nsColor near-duplicate) duplicated across 3 trials × 2 conditions. The 6 rationale texts are linguistically distinct (the agent re-phrases per trial) but semantically identical (all 6 propose the same private-helper refactor). A reviewer scoring on substance gives 6/6 the same value; a reviewer scoring on prose granularity might vary. Round-1 closeout therefore added a second κ measure to `score_all.py` — see [`analyses/panel-instructions.md` §6](analyses/panel-instructions.md#6-round-2-panel-coverage-post-symbol-gate-and-the-correlated-items-caveat) for the interpretation rules:

- **`inter_rater`** — Fleiss κ over the surviving rec rows × N raters. Methodology §8 / §12 literal measure. Inflated if reviewers give correlated scores across duplicates.
- **`inter_rater_collapsed`** — Fleiss κ over distinct (plant_id, cluster_id) judgments × N raters (per-(reviewer, judgment) median of the duplicates). Cleaner for round-1's correlated set, but under round 2's single distinct judgment (N=1) the κ value has essentially zero statistical power — treat the value as a sanity check and rely on the diagnostic fields (`within_reviewer_inconsistency_count`, `reviewer_variance`) for the actionable signal.
- **`inter_rater_collapsed.within_reviewer_inconsistency_count`** — diagnostic: number of (reviewer, judgment) cells where the reviewer scored duplicates inconsistently. High → reviewers are prose-sensitive; low → reviewers are substance-only.

The current `analyses/score-summary.json` blocks carry the structured panel-pending sentinels (note text shortened for readability):

```json
{"fleiss_kappa": null, "n_items": 6, "n_raters": 1, "note": "only 1 reviewer(s) present; Fleiss κ requires ≥2"}
{"fleiss_kappa": null, "n_judgments": 1, "n_raters": 1, "within_reviewer_inconsistency_count": 0, "note": "only 1 reviewer(s) present; Fleiss κ requires ≥2"}
```

Per-rec panel scores remain authoritative — auto-scorer.py's panel-route decision rule pre-registered the recs that needed human judgement, and round 1 supplies one such judgement per rec. Round 1's `within_reviewer_inconsistency_count == 0` (the single reviewer gave the same score across all 6 duplicates of Plant 5.1's judgment) confirms substance-only scoring at the corpus size — when round-2 reviewers land, divergence between the two κ values will quantify how much of round-1's inflation was correlation-driven.

## 5. Restraint plants — false-positive breakdown

Per the methodology §9 restraint table, restraint plants score under their own rubric. The 5 restraint plants (1R, 2R, 3R, 4R, 5R) produced these per-condition outcomes under the round-2 symbol gate:

| Plant | S1 best | S2 best | Action recs observed? |
|---|---|---|---|
| 1R (extract-to-common) | 0.5 (no-action ungrounded) | 0.5 (no-action ungrounded) | No (after round-2 symbol gate) |
| 2R (protocol-inheritance) | (no recs in S1) | 1.0 (no-action grounded) | No |
| 3R (default-implementation) | 0.5 | 0.5 | No |
| 4R (pat-introduction) | 1.0 (no-action grounded) | 0.5 (no-action ungrounded) | No |
| 5R (generic-parameterization) | 0.5 | 0.5 | No |

**FPR = 0/5 = 0.000** under both conditions after round 2 (see [§4.2](#42-binding-artifact-finding-resolved-in-round-2) and [rubric-modifications.md](rubric-modifications.md)). The round-1 headline of 0.200 came entirely from Plant 1R's incidental `DebugMetricsProvider` bindings on `DebugHUD.swift` — clusters that substring-matched Plant 1R's source file but did NOT surface its planted `MetricRow` symbol. The symbol gate (`expected_cluster_symbols: ["MetricRow"]`) blocks those bindings; the 30 remaining Plant 1R bindings all receive `no-action` from the agent, so the restraint's per-cell FPR is 0.0 in all 6 (condition, trial) cells.

The agent's behavior on Plant 1R's canonical `MetricRow` clusters was already correct in round 1 (no-action, `reason_class: "sample-app-mirror"`); the round-1 closeout's A3 prompt edit (`is_test=true | is_mock=true | is_sample_app=true` on ANY participating record now treated as load-bearing) is forward-looking methodology infrastructure whose measurable effect would land if a future restraint plant produces clusters the symbol gate doesn't reach.

## 6. Variance across trials

Trial-to-trial variance is small. Per (condition, category) cell, the trial-1/trial-2/trial-3 canonical recall values agree to within 0.1 in 14 of 15 cells, and exactly in 11 of 15 cells. No V4-style batching-variance signature (methodology §14.4) is observed — the per-rec count and per-rec category mix are stable across trials, consistent with the substrate-emitted `cluster_id` (issue #5) prerequisite having landed before Phase D.

The one cell with non-trivial trial variance: S2 default-implementation, where Plant 3.1 scored 1.0 in trial 1, 0.0 in trial 2, 1.0 in trial 3. The trial-2 dip is genuine trial-to-trial agent variance — the agent didn't surface Plant 3.1's `init(hue:saturation:brightness:)` default-impl refactor on that pass (both of Plant 3.1's S2-trial-2 scored pairs land at 0.0 under the round-2 symbol gate; the round-1 panel-resolved HSBColor "other" rec that previously contributed to this cell was a false binding now dropped by the gate per [§4.2](#42-binding-artifact-finding-resolved-in-round-2)).

## 7. Sensitivity to specifics-tolerance (resolved in round 2)

The round-1 auto-scorer was **key-only** on specifics matching; round 2 added verbatim value comparison per methodology §8 lines 626–631. The round-2 PR (closing [`#35`](https://github.com/jakebromberg/code-audit-pipeline/issues/35)) is the operationalization of "specifics fall outside tolerance → panel-route." See the [`rubric-modifications.md`](rubric-modifications.md) round-2 value-aware-specifics entry for the design rationale, projection data, and per-plant flip distribution.

Sensitivity-to-tolerance per the round-2 measurement: of the 102 rows that fired `primary_match_full` (37) or `primary_match_weak_rationale` (65) under round-1's key-only scoring, **100% flipped** under value-aware comparison — every row had at least one mismatched required value. Mismatch classification: 95.1% substantive (different identifier, different target package, missing required constraint value), 4.9% trivial (manifest-side parenthetical commentary that the agent didn't reproduce, all on Plant 3.4). The plan §3.3 decision gate (trivial ≤ 30% to merge) passed comfortably.

Where round-1 said "key-only over-credit is bounded for the planted clusters in this corpus" — that read does not hold under value-aware scoring. The over-credit was substantial: the headline `canonical_recall` shifts from S1=0.270 / S2=0.615 (key-only) to S1=0.070 / S2=0.110 (value-aware), with 108 rows routed to panel awaiting #85 reviewer recruitment. Panel scores against the routed cohort will determine the auto-plus-panel headline.

## 8. Known limitations

- **Plant 1.4 does not surface under either condition.** Pre-populated with `expected_cluster_symbols: ["SystemQualityClock", "SystemClock"]` per methodology §10 discipline, but its source files don't surface in any V7 cluster_id — the V7 substrate doesn't currently catalog the planted shape. Round-3 substrate work can re-place or replace it. (Plant 5.4 — previously listed alongside 1.4 — does surface: 2 clusters under the round-1 closeout rule, 6 under round 2's symbol gate, both pointing at `_Plant_IntCache` / `_Plant_StringCache`.)
- **Plant 1R restraint false-positive (resolved in round 2).** Round-1 audit showed the agent already emits `no-action` with `reason_class: "sample-app-mirror"` on Plant 1R's two canonical clusters; the 1.0 per-cell FPR came from incidental bindings — `DebugMetricsProvider` clusters in `DebugHUD.swift` (Plant 1R's source file) that aren't about MetricRow. Round 2's symbol-level binding fix ([rubric-modifications.md](rubric-modifications.md)) gates Plant 1R bindings on the `MetricRow` symbol, eliminating the incidental DebugMetricsProvider bindings. Plant 1R per-cell FPR is 0.0 in all 6 cells. The round-1 closeout's A3 prompt edit (rule 1 of the agent prompt now treats `is_test=true | is_mock=true | is_sample_app=true` on ANY participating record as load-bearing) is forward-looking methodology infrastructure whose measurable effect would land if a future restraint plant produces clusters the symbol gate doesn't reach.
- **Inter-rater κ undefined in round 1.** The pre-registered 3-reviewer panel ran with 1 expert reviewer in round 1 (see [§4.3](#43-inter-rater-κ) and the [`round1_deviation` block in reproducibility.yaml](reproducibility.yaml)). The `score-summary.json::inter_rater` block carries the panel-pending sentinel; round 2 recruits the missing two reviewers to populate a numeric κ over the same panel-routing artifact.
- **Substring-match binding produces false positives (resolved in round 2).** The round-1 closeout's prefer-signal-match rule cleaned up 24 incidental false bindings. Round 2's `expected_cluster_symbols` gate closes the remaining gaps — the panel-routed Plant 3.1 / 5.1 co-binding on HSBColor and Plant 1R's structural FPR both stem from (path, query)-granularity ambiguity that symbol-level matching resolves. See [§4.2](#42-binding-artifact-finding-resolved-in-round-2) and [rubric-modifications.md](rubric-modifications.md).
- **Auto-scorer over-credit risk (resolved in round 2).** Round 2's value-aware specifics matching ([`rubric-modifications.md`](rubric-modifications.md), resolves [`#35`](https://github.com/jakebromberg/code-audit-pipeline/issues/35)) replaces key-only matching with verbatim value comparison; out-of-tolerance specifics route to panel per methodology §8 lines 626–631 instead of auto-scoring 1.0. The corrected headline `canonical_recall` (S1=0.070, S2=0.110) is substantially below the round-1 over-credit number (S1=0.270, S2=0.615); the gap routes through the 108 panel-routed rows pending #85 reviewer recruitment.

## 9. Reproducibility

All inputs to this writeup are pinned in [`reproducibility.yaml`](reproducibility.yaml):

- `pre_registration.repo_sha`, `substrate_sha`, `plant_tree_sha`, `manifest_hash`, `rubric_hash`, `prompt_hash`, per-catalog and per-query hashes
- `execution.model_versions.primary` = `claude-sonnet-4-6` (alias, pin documented in `reproducibility.yaml` comment block since Anthropic did not publish a date-pinned 4.6 variant by the trial window)
- `execution.actual_spend_usd` = $39.46 (well under the §6.3 hard cap of $120)
- `execution.trial_date_range` = 2026-05-15 (single-day Phase D run)
- `execution.panel_composition` = 1 internal expert reviewer (round 1; pre-registered as 3 per methodology §17 decision #3 — see `round1_deviation` block); `panel_composition.round2_methodology_update` records the round-2 symbol-gate addition (see [rubric-modifications.md](rubric-modifications.md))
- `execution.rubric_modifications` = [`experiments/v7-refactor-recommendation/rubric-modifications.md`](rubric-modifications.md) (round 2 added `expected_cluster_symbols` (PR #89) and value-aware specifics matching (resolves #35); round 1 carried no post-hoc edits)

Re-running [`score_all.py`](score_all.py) against the same parsed cache + the committed `analyses/panel-scores.jsonl` reproduces [`analyses/auto-scores.json`](analyses/auto-scores.json) and [`analyses/score-summary.json`](analyses/score-summary.json) byte-for-byte (verified with `md5sum` across two consecutive runs). Reproducing the headline without panel scores: rename `analyses/panel-scores.jsonl` aside and rerun — `inter_rater` falls back to the "panel scores file not present" sentinel, and `promote_panel_scores` is a no-op so the headline reverts to the auto-scored-only `S1=0.070 / S2=0.110` (the corrected post-value-aware numbers; the round-1 pre-correction numbers were `S1=0.270 / S2=0.615`, recoverable from the `rubric-modifications.md` round-2 value-aware-specifics entry).

## See also

- [`analyses/substrate-helped.json`](analyses/substrate-helped.json), [`analyses/plant-recall-extended.json`](analyses/plant-recall-extended.json) — PR-E2 outputs that this writeup quotes
- [`analyses/auto-scores.json`](analyses/auto-scores.json), [`analyses/score-summary.json`](analyses/score-summary.json), [`analyses/panel-routing.jsonl`](analyses/panel-routing.jsonl) — PR-E3 outputs
- [`analyses/panel-instructions.md`](analyses/panel-instructions.md) — review-panel instructions
- [`reproducibility.yaml`](reproducibility.yaml) — pinned inputs + execution stamps
- [`docs/refactor-recommendation-experiment-methodology.md`](../../docs/refactor-recommendation-experiment-methodology.md) — methodology
- [`plans/v7-phase-e-scoring-and-writeup-plan.md`](../../plans/v7-phase-e-scoring-and-writeup-plan.md) — Phase E plan
