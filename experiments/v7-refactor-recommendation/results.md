# V7 refactor-recommendation experiment — round-1 results

Companion results doc for the V7 refactor-recommendation experiment, MVP scope (5 categories × 4 canonical + 1 restraint = 25 plants; 2 conditions S1/S2; 3 trials per condition; `claude-sonnet-4-6`). Structured per the [main implementation plan §7.3](../../plans/v7-refactor-recommendation-implementation-plan.md#7-phase-e--scoring--writeup-2-3-weeks). The 12 panel-routed recs were scored by a single expert reviewer in round 1 (see [§4 below](#4-panel-coverage--inter-rater-stats) and the [reproducibility.yaml `round1_deviation` block](reproducibility.yaml)); their numeric scores are backfilled into the headline by `promote_panel_scores` in [`score_all.py`](score_all.py).

## TL;DR

Headline 2-D point (canonical recall × restraint 1−FPR):

| Condition | Canonical recall | 1 − FPR | Panel-route rate |
|---|---|---|---|
| S1 (V6 substrate) | **0.270** | 1.000 | 1.6% |
| S2 (V7 substrate) | **0.615** | 1.000 | 0.9% |
| **S2 − S1** | **+0.345** | 0.000 | −0.7 pp |

Substrate enrichment delivered a **+0.345** absolute jump in canonical recall on the 20 canonical plants. Restraint false-positive rate is 0.000 in both conditions after round-2's symbol-level binding fix ([rubric-modifications.md](rubric-modifications.md)) eliminated the Plant 1R structural FPR; the round-1 headline of 0.20 was driven entirely by incidental bindings (16 `DebugMetricsProvider` clusters substring-matched Plant 1R's `DebugHUD.swift` source file but weren't about its planted MetricRow shape). Panel-route rate stayed well under the methodology §14.3 50% acceptance bar in both conditions, so the rubric covers what it intends to cover.

The improvement is **not uniform across categories**: it concentrates in the two V7-new substrate queries (`pat-candidates`, `protocol-inheritance-candidates`), which is consistent with the substrate-enrichment story but is also the narrowest possible story — V7's other enrichments did not move the needle on the categories V6 already served.

## 1. Per-category S2 − S1 deltas

Mean canonical recall across the 3 trials, per condition, per category:

| Category | S1 mean | S2 mean | Δ (S2−S1) | Notes |
|---|---|---|---|---|
| extract-to-common | 0.200 | 0.200 | **0.000** | V6 substrate already had `exact-duplicates`, `cross-package-shadows`, etc.; V7 added nothing here. Plant 1.4 surfaced in neither condition. |
| protocol-inheritance | 0.125 | 0.875 | **+0.750** | V7-new `protocol-inheritance-candidates` query is the substrate change. The category went from "barely surfaces" to "near-canonical recall." |
| default-implementation | 0.542 | 0.792 | **+0.250** | V7-new `default-impl-candidates` query. V6 partially surfaced these via near-duplicates; V7 made them explicit. |
| pat-introduction | 0.000 | 0.550 | **+0.550** | V7-new `pat-candidates` query. V6 had no signal for this category at all. |
| generic-parameterization | 0.400 | 0.575 | **+0.175** | V7-new `generic-struct-candidates`, `generic-function-candidates`. V6 partially via near-duplicates. Panel scoring promoted Plant 5.1 from auto-scored 0.0 → 0.3 (adjacent-defensible) across all S1 trials and S2 trial 2, narrowing the V6→V7 gap; the agent's S1 answer reaches the rubric's adjacency floor without the substrate signal. |

The signal is clean: where V7 added a new query, recall jumps; where V7 did not (extract-to-common), recall is identical. Per category cells per trial, see [`analyses/score-summary.json`](analyses/score-summary.json) → `per_category_per_cell`.

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

[`analyses/panel-routing.jsonl`](analyses/panel-routing.jsonl) holds 12 panel-routed (rec × plant) pairs. All 12 are `category: "other"` cases — agent declined the taxonomy and proposed a novel action. Concentrated on Plants 3.1 (default-implementation, 6 recs) and 5.1 (generic-parameterization, 6 recs); each plant routed in all 3 trials × both conditions.

Auto-scoring rate (auto-scored fraction = 1 − panel-route fraction):

| Condition | Scored pairs | Panel-routed | Auto-scoring rate |
|---|---|---|---|
| S1 | 291 | 6 | 97.9% |
| S2 | 473 | 6 | 98.7% |

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

Round 1 used a single expert reviewer (`analyses/panel-scores-reviewer-1.jsonl`); the pre-registered design called for 3 (methodology §17 decision #3). The [`reproducibility.yaml` `round1_deviation` block](reproducibility.yaml) records the rationale: the 12 routed pairs reduce to two distinct judgements (Plant 5.1 binding adjacent-defensible; Plant 3.1 binding false-positive), so the methodology overhead of two more reviewers was disproportionate at this corpus size. Round 2 adds the missing reviewers — same `panel-routing.jsonl`, two new `panel-scores-reviewer-N.jsonl` files concatenated into the consolidated file, then `score_all.py` populates **both** `inter_rater.fleiss_kappa` (rec-level) and `inter_rater_collapsed.fleiss_kappa` (judgment-level).

The 12 panel rows are not 12 independent items — they're 2 distinct (plant_id, cluster_id) judgments duplicated across 3 trials × 2 conditions on the same HSBColor cluster. The 6 rationale texts per plant are linguistically distinct (the agent re-phrases per trial) but semantically identical (all 6 propose the same private-helper refactor). A reviewer scoring on substance gives 6/6 the same value; a reviewer scoring on prose granularity might vary. Round-1 closeout therefore added a second κ measure to `score_all.py` — see [`analyses/panel-instructions.md` §6](analyses/panel-instructions.md#6-round-1-panel-coverage-and-the-correlated-items-caveat) for the interpretation rules:

- **`inter_rater`** — Fleiss κ over the 12 rec rows × N raters. Methodology §8 / §12 literal measure. Inflated if reviewers give correlated scores across duplicates.
- **`inter_rater_collapsed`** — Fleiss κ over 2 distinct judgments × N raters (per-(reviewer, judgment) median of the 6 duplicates). Cleaner for round-1's correlated set; low statistical power (N=2 items).
- **`inter_rater_collapsed.within_reviewer_inconsistency_count`** — diagnostic: number of (reviewer, judgment) cells where the reviewer scored duplicates inconsistently. High → reviewers are prose-sensitive; low → reviewers are substance-only.

The current `analyses/score-summary.json` blocks carry the structured panel-pending sentinels:

```json
{"fleiss_kappa": null, "n_items": 12, "n_raters": 1, "note": "only 1 reviewer(s) present; Fleiss κ requires ≥2"}
{"fleiss_kappa": null, "n_judgments": 2, "n_raters": 1, "within_reviewer_inconsistency_count": 0, "note": "..."}
```

Per-rec panel scores remain authoritative — auto-scorer.py's panel-route decision rule pre-registered the recs that needed human judgement, and round 1 supplies one such judgement per rec. Round 1's `within_reviewer_inconsistency_count == 0` (the single reviewer gave the same score across all 6 duplicates of each plant) confirms substance-only scoring at the corpus size — when round-2 reviewers land, divergence between the two κ values will quantify how much of round-1's inflation was correlation-driven.

## 5. Restraint plants — false-positive breakdown

Per the methodology §9 restraint table, restraint plants score under their own rubric. The 5 restraint plants (1R, 2R, 3R, 4R, 5R) produced these per-condition outcomes:

| Plant | S1 best | S2 best | Action recs observed? |
|---|---|---|---|
| 1R (extract-to-common) | 0.5 (no-action ungrounded) | 0.5 (no-action ungrounded) | **Yes** — recommended `extract-to-common` on the sample-app mirror |
| 2R (protocol-inheritance) | (no recs in S1) | 1.0 (no-action grounded) | No |
| 3R (default-implementation) | 0.5 | 0.5 | No |
| 4R (pat-introduction) | 1.0 (no-action grounded) | 0.5 (no-action ungrounded) | No |
| 5R (generic-parameterization) | 0.5 | 0.5 | No |

**FPR = 1/5 = 0.200** under both conditions. The one false-positive is Plant 1R: the agent recommended `extract-to-common` on the `_Plant_CacheClientConfig.swift` / `_Plant_CacheClientConfigMock.swift` pair across multiple trials, ignoring the `is_test` / `_Plant_*Mock` context. This is the canonical context-blind failure mode methodology §14.2 flags (informed vs. context-blind FP).

A quick rationale check on Plant 1R's S2 recs: the agent's rationale cites that one file is a mock copy of the other, but treats this as motivation to consolidate rather than as a restraint signal. The decision rule the prompt requires (`is_test == true` → factor against action) is partially observed (the agent acknowledges test-ness) but not load-bearing in the agent's recommendation. This is round-2 prompt-tightening work, not a substrate-side gap.

## 6. Variance across trials

Trial-to-trial variance is small. Per (condition, category) cell, the trial-1/trial-2/trial-3 canonical recall values agree to within 0.1 in 14 of 15 cells, and exactly in 11 of 15 cells. No V4-style batching-variance signature (methodology §14.4) is observed — the per-rec count and per-rec category mix are stable across trials, consistent with the substrate-emitted `cluster_id` (issue #5) prerequisite having landed before Phase D.

The one cell with non-trivial trial variance: S2 default-implementation, where Plant 3.1 scored 1.0 in trial 1, 0.0 in trial 2, 1.0 in trial 3. The trial-2 dip is genuine trial-to-trial agent variance — the agent didn't surface Plant 3.1's `init(hue:saturation:brightness:)` default-impl refactor on that pass (all 11 scored pairs for Plant 3.1 in S2 trial 2 land at 0.0, including the panel-resolved HSBColor "other" rec at 0.0 from the [§4.2 false binding](#42-binding-artifact-finding)).

## 7. Sensitivity to specifics-tolerance (round 1 scope)

The round-1 auto-scorer is **key-only** on specifics matching (per [`auto-scorer.py`](auto-scorer.py) MVP-scope docstring, lines 38–47). Per the methodology §8 panel-route decision rule, that means a rec whose category matches primary and whose specifics carry the required *keys* (regardless of *values*) auto-scores 1.0 instead of routing to panel. This is a known over-credit risk.

The panel sitting's [step 4 spot check](analyses/panel-instructions.md#3-the-four-panel-cases-per-phase-e-plan-72--main-plan-72) is deferred to round 2 — the round-1 panel volume is small enough (12 recs) that adding spot-check load was not necessary at this corpus size. If round-2 panel results show systematic value-mismatch under the key-only auto-score, the next iteration adds value-aware specifics matching (~50 LOC in `auto-scorer.py`) and re-scores.

For the round-1 headline numbers, the key-only assumption holds: every rec that auto-scored 1.0 had the agent emitting structurally complete specifics; spot-reading a sample of the rationale text in [`analyses/auto-scores.json`](analyses/auto-scores.json) `scored` entries confirms the cited symbol names line up with the manifest's expected entries.

## 8. Known limitations

- **Plant 1.4 does not surface under either condition.** Its planted clusters' substring presence in V7 query outputs is the diagnostic — Plant 1.4 is placed in clusters the V7 substrate doesn't currently catalog. Round 3 either re-places it or extends the substrate to catalog the missing shape. (Plant 5.4 — previously listed alongside 1.4 — does surface: 2 clusters under the round-1 closeout rule, 6 under round 2's symbol gate, both pointing at `_Plant_IntCache` / `_Plant_StringCache`.)
- **Plant 1R restraint false-positive (resolved in round 2).** Round-1 audit showed the agent already emits `no-action` with `reason_class: "sample-app-mirror"` on Plant 1R's two canonical clusters; the 1.0 per-cell FPR came from incidental bindings — `DebugMetricsProvider` clusters in `DebugHUD.swift` (Plant 1R's source file) that aren't about MetricRow. Round 2's symbol-level binding fix ([rubric-modifications.md](rubric-modifications.md)) gates Plant 1R bindings on the `MetricRow` symbol, eliminating the incidental DebugMetricsProvider bindings. Plant 1R per-cell FPR is 0.0 in all 6 cells. The round-1 closeout's A3 prompt edit (rule 1 of the agent prompt now treats `is_test=true | is_mock=true | is_sample_app=true` on ANY participating record as load-bearing) is forward-looking methodology infrastructure whose measurable effect would land if a future restraint plant produces clusters the symbol gate doesn't reach.
- **Inter-rater κ undefined in round 1.** The pre-registered 3-reviewer panel ran with 1 expert reviewer in round 1 (see [§4.3](#43-inter-rater-κ) and the [`round1_deviation` block in reproducibility.yaml](reproducibility.yaml)). The `score-summary.json::inter_rater` block carries the panel-pending sentinel; round 2 recruits the missing two reviewers to populate a numeric κ over the same panel-routing artifact.
- **Substring-match binding produces false positives (resolved in round 2).** The round-1 closeout's prefer-signal-match rule cleaned up 24 incidental false bindings. Round 2's `expected_cluster_symbols` gate closes the remaining gaps — the panel-routed Plant 3.1 / 5.1 co-binding on HSBColor and Plant 1R's structural FPR both stem from (path, query)-granularity ambiguity that symbol-level matching resolves. See [§4.2](#42-binding-artifact-finding-resolved-in-round-2) and [rubric-modifications.md](rubric-modifications.md).
- **Plant 1.4 remains unexercised.** Pre-populated with `expected_cluster_symbols: ["SystemQualityClock", "SystemClock"]` per methodology §10 discipline, but its source files don't surface in any V7 cluster_id. Round-3 substrate work can re-place or replace it.
- **Auto-scorer over-credit risk (key-only specifics).** Spot-check load deferred to round 2; round-1 sample confirms the over-credit is bounded for the planted clusters in this corpus.

## 9. Reproducibility

All inputs to this writeup are pinned in [`reproducibility.yaml`](reproducibility.yaml):

- `pre_registration.repo_sha`, `substrate_sha`, `plant_tree_sha`, `manifest_hash`, `rubric_hash`, `prompt_hash`, per-catalog and per-query hashes
- `execution.model_versions.primary` = `claude-sonnet-4-6` (alias, pin documented in `reproducibility.yaml` comment block since Anthropic did not publish a date-pinned 4.6 variant by the trial window)
- `execution.actual_spend_usd` = $39.46 (well under the §6.3 hard cap of $120)
- `execution.trial_date_range` = 2026-05-15 (single-day Phase D run)
- `execution.panel_composition` = 1 internal expert reviewer (round 1; pre-registered as 3 per methodology §17 decision #3 — see `round1_deviation` block)
- `execution.rubric_modifications` = null (no post-hoc rubric edits in round 1)

Re-running [`score_all.py`](score_all.py) against the same parsed cache + the committed `analyses/panel-scores.jsonl` reproduces [`analyses/auto-scores.json`](analyses/auto-scores.json) and [`analyses/score-summary.json`](analyses/score-summary.json) byte-for-byte (verified with `md5sum` across two consecutive runs). Reproducing the headline without panel scores: rename `analyses/panel-scores.jsonl` aside and rerun — `inter_rater` falls back to the "panel scores file not present" sentinel, and `promote_panel_scores` is a no-op so the headline reverts to the auto-scored-only `S1=0.255 / S2=0.615`.

## See also

- [`analyses/substrate-helped.json`](analyses/substrate-helped.json), [`analyses/plant-recall-extended.json`](analyses/plant-recall-extended.json) — PR-E2 outputs that this writeup quotes
- [`analyses/auto-scores.json`](analyses/auto-scores.json), [`analyses/score-summary.json`](analyses/score-summary.json), [`analyses/panel-routing.jsonl`](analyses/panel-routing.jsonl) — PR-E3 outputs
- [`analyses/panel-instructions.md`](analyses/panel-instructions.md) — review-panel instructions
- [`reproducibility.yaml`](reproducibility.yaml) — pinned inputs + execution stamps
- [`docs/refactor-recommendation-experiment-methodology.md`](../../docs/refactor-recommendation-experiment-methodology.md) — methodology
- [`plans/v7-phase-e-scoring-and-writeup-plan.md`](../../plans/v7-phase-e-scoring-and-writeup-plan.md) — Phase E plan
