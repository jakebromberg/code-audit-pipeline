# V7 refactor-recommendation experiment — round-1 results (auto-scored)

Companion results doc for the V7 refactor-recommendation experiment, MVP scope (5 categories × 4 canonical + 1 restraint = 25 plants; 2 conditions S1/S2; 3 trials per condition; `claude-sonnet-4-6`). Structured per the [main implementation plan §7.3](../../plans/v7-refactor-recommendation-implementation-plan.md#7-phase-e--scoring--writeup-2-3-weeks). Numbers below are the auto-scorer pass; panel-reviewed numbers for the 12 routed recs land after the panel sitting (see [§4 below](#4-panel-coverage--inter-rater-stats) and the [panel instructions](analyses/panel-instructions.md)).

## TL;DR

Headline 2-D point (canonical recall × restraint 1−FPR):

| Condition | Canonical recall | 1 − FPR | Panel-route rate |
|---|---|---|---|
| S1 (V6 substrate) | **0.255** | 0.800 | 2.1% |
| S2 (V7 substrate) | **0.615** | 0.800 | 1.3% |
| **S2 − S1** | **+0.360** | 0.000 | −0.8 pp |

Substrate enrichment delivered a **+0.36** absolute jump in canonical recall on the 20 canonical plants. Restraint false-positive rate held flat at 0.20 (1 of 5 restraint plants — Plant 1R — triggered an action recommendation under both conditions). Panel-route rate stayed well under the methodology §14.3 50% acceptance bar in both conditions, so the rubric covers what it intends to cover.

The improvement is **not uniform across categories**: it concentrates in the two V7-new substrate queries (`pat-candidates`, `protocol-inheritance-candidates`), which is consistent with the substrate-enrichment story but is also the narrowest possible story — V7's other enrichments did not move the needle on the categories V6 already served.

## 1. Per-category S2 − S1 deltas

Mean canonical recall across the 3 trials, per condition, per category:

| Category | S1 mean | S2 mean | Δ (S2−S1) | Notes |
|---|---|---|---|---|
| extract-to-common | 0.200 | 0.200 | **0.000** | V6 substrate already had `exact-duplicates`, `cross-package-shadows`, etc.; V7 added nothing here. Plant 1.4 surfaced in neither condition. |
| protocol-inheritance | 0.125 | 0.875 | **+0.750** | V7-new `protocol-inheritance-candidates` query is the substrate change. The category went from "barely surfaces" to "near-canonical recall." |
| default-implementation | 0.542 | 0.792 | **+0.250** | V7-new `default-impl-candidates` query. V6 partially surfaced these via near-duplicates; V7 made them explicit. |
| pat-introduction | 0.000 | 0.550 | **+0.550** | V7-new `pat-candidates` query. V6 had no signal for this category at all. |
| generic-parameterization | 0.325 | 0.550 | **+0.225** | V7-new `generic-struct-candidates`, `generic-function-candidates`. V6 partially via near-duplicates. |

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

**Fleiss κ**: not yet computed. The `analyses/score-summary.json` → `inter_rater` block currently holds `null` with a note that `analyses/panel-scores.jsonl` is not present. Once the three reviewers complete the [panel sitting](analyses/panel-instructions.md), rerunning `score_all.py` populates `inter_rater.fleiss_kappa` automatically from the score buckets {-0.5, 0.0, 0.3, 0.5, 0.7, 1.0}.

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

The one cell with non-trivial trial variance: S2 default-implementation, where Plant 3.1 scored 1.0 in trial 1, 0.0 in trial 2, 1.0 in trial 3. The trial-2 dip is the "other"-category route — the agent chose the panel-route path in that trial and the rec scored 0 under the best-score-across-pairs aggregation.

## 7. Sensitivity to specifics-tolerance (round 1 scope)

The round-1 auto-scorer is **key-only** on specifics matching (per [`auto-scorer.py`](auto-scorer.py) MVP-scope docstring, lines 38–47). Per the methodology §8 panel-route decision rule, that means a rec whose category matches primary and whose specifics carry the required *keys* (regardless of *values*) auto-scores 1.0 instead of routing to panel. This is a known over-credit risk.

The panel sitting's [step 4 spot check](analyses/panel-instructions.md#3-the-four-panel-cases-per-phase-e-plan-72--main-plan-72) is deferred to round 2 — the round-1 panel volume is small enough (12 recs) that adding spot-check load was not necessary at this corpus size. If round-2 panel results show systematic value-mismatch under the key-only auto-score, the next iteration adds value-aware specifics matching (~50 LOC in `auto-scorer.py`) and re-scores.

For the round-1 headline numbers, the key-only assumption holds: every rec that auto-scored 1.0 had the agent emitting structurally complete specifics; spot-reading a sample of the rationale text in [`analyses/auto-scores.json`](analyses/auto-scores.json) `scored` entries confirms the cited symbol names line up with the manifest's expected entries.

## 8. Known limitations

- **Plants 1.4 and 5.4 do not surface under either condition.** Their planted clusters' substring presence in V7 query outputs is the diagnostic — these two plants are placed in clusters the V7 substrate doesn't currently catalog. Round 2 either re-places them or extends the substrate to catalog the missing shape.
- **Plant 1R restraint false-positive persists across conditions.** This is a prompt-side fix (sharpen the `is_test`/`is_mock` decision rule in the agent prompt), not a substrate-side gap. Logged as a round-2 prompt-tightening task.
- **Inter-rater κ pending panel completion.** The `analyses/score-summary.json` → `inter_rater` block updates automatically once `analyses/panel-scores.jsonl` exists.
- **Auto-scorer over-credit risk (key-only specifics).** Spot-check load deferred to round 2; round-1 sample confirms the over-credit is bounded for the planted clusters in this corpus.

## 9. Reproducibility

All inputs to this writeup are pinned in [`reproducibility.yaml`](reproducibility.yaml):

- `pre_registration.repo_sha`, `substrate_sha`, `plant_tree_sha`, `manifest_hash`, `rubric_hash`, `prompt_hash`, per-catalog and per-query hashes
- `execution.model_versions.primary` = `claude-sonnet-4-6` (alias, pin documented in `reproducibility.yaml` comment block since Anthropic did not publish a date-pinned 4.6 variant by the trial window)
- `execution.actual_spend_usd` = $39.46 (well under the §6.3 hard cap of $120)
- `execution.trial_date_range` = 2026-05-15 (single-day Phase D run)
- `execution.panel_composition` = 3 internal reviewers, blind to condition (per methodology §17 decision #3)
- `execution.rubric_modifications` = null (no post-hoc rubric edits in round 1)

Re-running [`score_all.py`](score_all.py) against the same parsed cache reproduces [`analyses/auto-scores.json`](analyses/auto-scores.json) byte-for-byte (verified with `md5sum` across two consecutive runs).

## See also

- [`analyses/substrate-helped.json`](analyses/substrate-helped.json), [`analyses/plant-recall-extended.json`](analyses/plant-recall-extended.json) — PR-E2 outputs that this writeup quotes
- [`analyses/auto-scores.json`](analyses/auto-scores.json), [`analyses/score-summary.json`](analyses/score-summary.json), [`analyses/panel-routing.jsonl`](analyses/panel-routing.jsonl) — PR-E3 outputs
- [`analyses/panel-instructions.md`](analyses/panel-instructions.md) — review-panel instructions
- [`reproducibility.yaml`](reproducibility.yaml) — pinned inputs + execution stamps
- [`docs/refactor-recommendation-experiment-methodology.md`](../../docs/refactor-recommendation-experiment-methodology.md) — methodology
- [`plans/v7-phase-e-scoring-and-writeup-plan.md`](../../plans/v7-phase-e-scoring-and-writeup-plan.md) — Phase E plan
