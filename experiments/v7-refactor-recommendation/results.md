# V7 refactor-recommendation experiment — round-1 results

Companion results doc for the V7 refactor-recommendation experiment, MVP scope (5 categories × 4 [canonical](#glossary-canonical-plant) + 1 [restraint](#glossary-restraint-plant) = 25 plants; 2 conditions [S1](#glossary-s1) / [S2](#glossary-s2); 3 [trials](#glossary-trial) per condition; `claude-sonnet-4-6`). Structured per the [main implementation plan §7.3](../../plans/v7-refactor-recommendation-implementation-plan.md#7-phase-e--scoring--writeup-23-weeks). The 12 [panel-routed](#glossary-panel-route-rate) [recs](#glossary-rec) were scored by a single expert reviewer in [round 1](#glossary-round-1) (see [§4 below](#4-panel-coverage--inter-rater-stats) and the [reproducibility.yaml `round1_deviation` block](reproducibility.yaml)); their numeric scores are backfilled into the headline by [`promote_panel_scores`](#glossary-code-references) in [`score_all.py`](score_all.py). [Round-2](#glossary-round-2) corrections to the auto-scorer ([symbol-level binding](#glossary-binding) via [PR #89](https://github.com/jakebromberg/code-audit-pipeline/pull/89), then [value-aware specifics matching](#glossary-value-aware-matching) via the PR closing [`#35`](https://github.com/jakebromberg/code-audit-pipeline/issues/35)) shifted both halves of the 2-D headline; [`rubric-modifications.md`](rubric-modifications.md) walks the two round-2 entries with expected-vs-actual tables. A [glossary](#glossary) at the bottom of this doc defines the jargon used throughout.

## TL;DR

Headline 2-D point ([canonical_recall](#glossary-canonical-recall) × restraint [1−FPR](#glossary-1-fpr)), as of the [round-2](#glossary-round-2) value-aware-specifics correction:

| Condition | Canonical recall | 1 − FPR | Panel-route rate |
|---|---|---|---|
| [S1](#glossary-s1) ([V6](#glossary-substrate) substrate) | **0.070** | 1.000 | 13.5% |
| [S2](#glossary-s2) ([V7](#glossary-substrate) substrate) | **0.110** | 1.000 | 24.9% |
| **S2 − S1** | **+0.040** | 0.000 | +11.4 pp |

Comparison with round-2 binding-correctness baseline (after [PR #89](https://github.com/jakebromberg/code-audit-pipeline/pull/89) [symbol-level binding](#glossary-binding), before [value-aware specifics matching](#glossary-value-aware-matching)):

| Condition | Recall (binding-only baseline) | Recall (value-aware) | Δ |
|---|---|---|---|
| S1 | 0.270 | 0.070 | −0.200 |
| S2 | 0.615 | 0.110 | −0.505 |

The round-2 value-aware correction shifts the recall headline down by 0.200 (S1) / 0.505 (S2). This is a **methodological correction**, not a regression: the binding-only baseline was over-credit per [methodology §8](../../docs/refactor-recommendation-experiment-methodology.md#8-scoring-rubric) lines 626–631, which mandate panel-route on out-of-tolerance specifics rather than auto-1.0 on [key-only matches](#glossary-value-aware-matching). Of the 102 rows that previously fired [`primary_match_full`](#glossary-primary-match-full) or [`primary_match_weak_rationale`](#glossary-primary-match-weak-rationale), 100% had at least one mismatched required value; 95.1% were substantive (agent picked wrong identifier, wrong target package, or omitted a constraint) and 4.9% were trivial (parenthetical commentary in manifest values, all on [Plant 3.4](plant-manifest.yaml)). All 102 now route to panel awaiting [`#85`](https://github.com/jakebromberg/code-audit-pipeline/issues/85) reviewer recruitment; the headline canonical_recall would lift back into the auto-plus-panel range once panel scores land. See [`rubric-modifications.md`](rubric-modifications.md) round-2 value-aware-specifics entry for the per-plant flip distribution and worked examples.

Restraint [false-positive rate](#glossary-fpr) is 0.000 in both conditions after round-2's [symbol-level binding](#glossary-binding) fix ([PR #89](https://github.com/jakebromberg/code-audit-pipeline/pull/89)) eliminated the [Plant 1R](#glossary-plant-1r) structural FPR; the [round-1](#glossary-round-1) headline of 0.20 was driven entirely by incidental bindings (16 `DebugMetricsProvider` clusters substring-matched Plant 1R's [`DebugHUD.swift`](#glossary-debughud) source file but weren't about its planted `MetricRow` shape). [Panel-route rate](#glossary-panel-route-rate) jumped from <2% (round-1) to ~25% (S2) after value-aware specifics matching — still under the [methodology §14](../../docs/refactor-recommendation-experiment-methodology.md#14-pre-mortem-failure-modes-diagnostics-recovery) 50% [auto-scoring rate](#glossary-auto-scoring-rate) acceptance bar, but with a clear shift in load profile: most of the now-routed rows carry the manifest's pre-registered [`specifics_tolerance`](#glossary-specifics-tolerance) flags inline as panel guidance, so reviewers can evaluate the structural property the flag describes without cross-referencing.

The [substrate](#glossary-substrate) enrichment signal is **mostly absorbed into the panel-routed bucket** under value-aware scoring: agents identified the correct *category* on the [V7](#glossary-substrate)-new [clusters](#glossary-cluster) (so substrate exposure helped category-identification) but picked wrong specifics *values* on most of those clusters (so value-correctness now panel-routes). The [§1](#1-per-category-s2--s1-deltas) per-category breakdown below shows [protocol-inheritance](../../docs/refactor-recommendation-experiment-methodology.md#52-category-2--protocol-inheritance) and [default-implementation](../../docs/refactor-recommendation-experiment-methodology.md#53-category-3--default-implementation) deltas collapsing to ~0 once auto-scoring no longer over-credits key-only matches — the V6 → V7 substrate uplift on category-identification didn't translate to value-correctness uplift under the same setup. [PAT-introduction](../../docs/refactor-recommendation-experiment-methodology.md#54-category-4--pat-introduction) preserves a smaller positive delta (+0.325), [generic-parameterization](../../docs/refactor-recommendation-experiment-methodology.md#55-category-5--generic-parameterization-struct-or-function) flips sign (S2 slightly worse than S1 in pure auto-score terms — both modest, both within panel-route absorption). The substrate-helped story moves from the headline to the panel-routed cohort, where it's recoverable once #85 reviewers rate the 108 routed rows.

## 1. Per-category S2 − S1 deltas

Mean [canonical_recall](#glossary-canonical-recall) across the 3 [trials](#glossary-trial), per condition, per category. Both pre- and post-[value-aware](#glossary-value-aware-matching) columns shown; the post-column is the current headline.

| Category | S1 (pre / post) | S2 (pre / post) | Δ (S2−S1) post | Notes |
|---|---|---|---|---|
| [extract-to-common](../../docs/refactor-recommendation-experiment-methodology.md#51-category-1--extract-to-common) | 0.200 / 0.075 | 0.200 / 0.075 | **0.000** | V6 substrate already had `exact-duplicates`, `cross-package-shadows`, etc.; V7 added nothing here. [Plant 1.4](plant-manifest.yaml) surfaced in neither condition. Post-value-aware drop on both conditions reflects [Plant 1.1](plant-manifest.yaml)'s `target_package` mismatch (agent recs `app:iOS`, manifest expects `Shared/Branding`) — substantive mismatch routes to panel. |
| [protocol-inheritance](../../docs/refactor-recommendation-experiment-methodology.md#52-category-2--protocol-inheritance) | 0.125 / 0.125 | 0.875 / 0.125 | **0.000** | V7-new `protocol-inheritance-candidates` query is the substrate change. Round-1 reported "barely surfaces → near-canonical." Under value-aware scoring the substrate-helped category-identification holds, but agent-picked specifics values fail panel-route on Plants [2.1](plant-manifest.yaml)/[2.2](plant-manifest.yaml)/[2.3](plant-manifest.yaml)/[2.4](plant-manifest.yaml) (all 18 S2 primary-match rows flip to panel-route on member-set mismatch). Panel-recoverable. |
| [default-implementation](../../docs/refactor-recommendation-experiment-methodology.md#53-category-3--default-implementation) | 0.542 / 0.000 | 0.792 / 0.000 | **0.000** | V7-new `default-impl-candidates` query. Round-1 reported V6 partial → V7 explicit. Under value-aware scoring all Plants [3.1](plant-manifest.yaml)–[3.4](plant-manifest.yaml) panel-route — Plant 3.3 agent invented `NormalizationModeConfigurable` instead of using existing `AudioProcessor`; [Plant 3.2](plant-manifest.yaml) invented `BlendModeConvertible` instead of `BlendMode`. Both are exactly the [methodology §8](../../docs/refactor-recommendation-experiment-methodology.md#8-scoring-rubric) "wrong specifics" panel-route case. |
| [pat-introduction](../../docs/refactor-recommendation-experiment-methodology.md#54-category-4--pat-introduction) | 0.000 / 0.000 | 0.550 / 0.325 | **+0.325** | V7-new `pat-candidates` query. V6 had no signal for this category at all. Smaller post-value-aware delta (+0.325 vs round-1 +0.550) because 2 of the previous primary-match rows panel-route; this is the cleanest preserved substrate-helped signal. |
| [generic-parameterization](../../docs/refactor-recommendation-experiment-methodology.md#55-category-5--generic-parameterization-struct-or-function) | 0.400 / 0.150 | 0.575 / 0.025 | **−0.125** | V7-new `generic-struct-candidates`, `generic-function-candidates`. Post-value-aware S2 dips slightly below S1 — [Plant 5.2](plant-manifest.yaml) (S2-bound) has all 9 primary-match rows flip on `type_params.constraint: null` (agent), `"Decodable"` (manifest); [Plant 5.1](plant-manifest.yaml)'s [panel-scored](#glossary-panel-promoted) row preserves S1's 0.3 ([adjacent-defensible](#glossary-adjacent-wrong-category)) panel promotion. Both numbers are modest enough that the difference is within trial variance. |

Where round-1 read "substrate-enrichment delivers clear V6→V7 uplift on three categories," the value-aware-corrected read is more nuanced: substrate exposure helps the agent **identify the right category** (which is V7's structural claim), but **value-correctness on the resulting recommendations is the panel's job** under [methodology §8](../../docs/refactor-recommendation-experiment-methodology.md#8-scoring-rubric) routing. With 108 panel-routed rows awaiting [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) reviewer recruitment, the V7-vs-V6 question on value-correctness is open until panel scores land. Per category cells per trial, see [`analyses/score-summary.json`](analyses/score-summary.json) → `per_category_per_cell`.

## 2. §14.1 substrate-helped check (from [PR-E2](#glossary-pr-e2))

The [methodology §14](../../docs/refactor-recommendation-experiment-methodology.md#14-pre-mortem-failure-modes-diagnostics-recovery) pre-mortem signature (§14.1 sub-topic) is "S2 − S1 per-[rec](#glossary-rec) recall delta sits within ±5pp across all categories." [PR-E2's substrate-helped analyzer](analyses/substrate_helped.py) computed this on the parsed recs themselves (per-rec confidence + category-distribution distance per query, across the 7 shared queries — the queries that exist in both [S1](#glossary-s1) and [S2](#glossary-s2)). Output: [`analyses/substrate-helped.json`](analyses/substrate-helped.json).

Result: **1 of 7 shared queries passes the per-rec ±5pp threshold** (`cross-package-shape-near-duplicates-any`). The aggregate `signature_pass: false` — the §14.1 stop-the-line signature fires *for the shared corpus*.

The §14.1 result and the [§1 per-category result above](#1-per-category-s2--s1-deltas) are **not in tension** — they measure complementary things:

- §14.1 asks whether the *same [cluster](#glossary-cluster) row* produces meaningfully different per-rec output under S2 vs S1 (confidence shift, category-distribution shift). Answer: mostly no.
- §1 asks whether the *category recall on planted refactors* is higher under S2. Answer: yes, dramatically, in the categories where [V7](#glossary-substrate) added new substrate queries.

The reconciliation: V7's [substrate](#glossary-substrate) enrichments did not change the model's per-rec evaluation behavior on the shared cluster rows; V7 *added new cluster rows* (the V7-only queries: `pat-candidates`, `protocol-inheritance-candidates`, `default-impl-candidates`, `generic-struct-candidates`, `generic-function-candidates`; full catalog in [methodology §6.8](../../docs/refactor-recommendation-experiment-methodology.md#68-new-queries-that-consume-the-new-substrate)). Those new cluster rows are where the recall improvement lives. The cold-condition agent did not have access to those clusters; the warm-condition agent did, and used them to find planted refactors [V6](#glossary-substrate) had no signal for.

This is the substrate-fanout-not-substrate-reasoning story: V7's value is *what it surfaces*, not *how it characterizes what was already surfaced*. Worth a [round-2](#glossary-round-2) design note — if V7 enrichments to existing queries (context flags, conformance edges feeding cluster shape) were expected to move the model's reasoning on shared clusters too, they did not.

## 3. Plant-recall confirm — Plant 5.3 outcome (from [PR-E2](#glossary-pr-e2))

PR-E2's plant-recall-extended analyzer ([`analyses/plant-recall-extended.json`](analyses/plant-recall-extended.json)) tracked which plants surfaced via parsed categories. Aggregate:

| Condition | Plants surfaced by category | Plants surfaced (none) |
|---|---|---|
| [S1](#glossary-s1) | 9 / 25 | 16 |
| [S2](#glossary-s2) | 21 / 25 | 4 (1.2, 1.3, 1.4, 5.1) |

[Plant 5.3](plant-manifest.yaml) (which Phase C flagged because its [`expected_substrate_signals`](#glossary-expected-substrate-signals) did not fire in the cluster outputs): **surfaces under S2 via category recall**. The [Phase E plan](../../plans/v7-phase-e-scoring-and-writeup-plan.md) §6 decision #4 escalation path (file a substrate-recall follow-up issue) does not trigger. The plant-manifest declaration of expected signals stays the [round-1](#glossary-round-1) truth; no follow-up substrate-recall issue is filed.

The 4 plants missing in S2 ([1.2](plant-manifest.yaml), [1.3](plant-manifest.yaml), [1.4](plant-manifest.yaml), [5.1](plant-manifest.yaml)) are a separate finding: their planted clusters either don't appear in any V7 cluster_id, or the parsed category never matches the manifest's primary. [Round 2](#glossary-round-2) can revisit plant placement for those four.

## 4. Panel coverage + inter-rater stats

After [round-2](#glossary-round-2)'s [symbol-level binding](#glossary-binding) fix ([§4.2](#42-binding-artifact-finding-resolved-in-round-2)) and [value-aware specifics matching](#glossary-value-aware-matching) ([§7](#7-sensitivity-to-specifics-tolerance-resolved-in-round-2)), [`analyses/panel-routing.jsonl`](analyses/panel-routing.jsonl) holds **108** [panel-routed](#glossary-panel-route-rate) ([rec](#glossary-rec) × plant) rows — 6 [`other_routes_to_panel`](#glossary-other-routes-to-panel) cases (agent declined the taxonomy and proposed a novel action, all 6 on the [round-1](#glossary-round-1) [Plant 5.1](plant-manifest.yaml) [HSBColor](#glossary-hsbcolor) cluster preserved through both round-2 corrections) plus 102 [`primary_match_specifics_outside_tolerance`](#glossary-primary-match-specifics-outside-tolerance) cases new under value-aware scoring (agent identified the category correctly but emitted specifics values that disagreed verbatim with the manifest's `primary_answer.specifics`). The 108 rows span 17 plants and **29 distinct `(plant_id, cluster_id)` judgments**.

[Auto-scoring rate](#glossary-auto-scoring-rate) (auto-scored fraction = 1 − [panel-route fraction](#glossary-panel-route-rate)), computed against the post-round-2 `scored` + `panel_routed` artifacts (denominator is `scored.size` per condition; numerator is `scored.size` − `panel_routed` count, consistent with the [TL;DR's](#tldr) panel-route rate column):

| Condition | Scored | Panel-routed | Auto-scoring rate |
|---|---|---|---|
| [S1](#glossary-s1) | 192 | 26 | 86.5% |
| [S2](#glossary-s2) | 329 | 82 | 75.1% |

[Methodology §14](../../docs/refactor-recommendation-experiment-methodology.md#14-pre-mortem-failure-modes-diagnostics-recovery) (§14.3 sub-topic) sets the acceptance bar at "auto-scored fraction ≥ 50%" (equivalently panel-route ≤ 50%). Both conditions pass; S2 carries the heavier panel load — value-aware specifics matching shifted most of the round-1 substrate-enrichment signal into the panel-routed bucket on the V7-only queries (per the [TL;DR](#tldr) and [§7](#7-sensitivity-to-specifics-tolerance-resolved-in-round-2)). The round-1 "two orders of magnitude of headroom" framing no longer applies — the headroom over the §14.3 threshold is now ~37 pp (S1) / ~25 pp (S2), respectable but no longer enormous.

### 4.1 Round-1 panel-sitting outcome (historical — do not update)

Preserved for reproducibility-stack continuity per the same convention as [`analyses/panel-instructions.md`](analyses/panel-instructions.md) §6.1. The [round-1](#glossary-round-1) panel-routing artifact (12 rows, pre-symbol-gate) was scored under the [`reproducibility.yaml` `round1_deviation` block](reproducibility.yaml)'s single-reviewer regime; the scores below remain the round-1 truth for that artifact. [Round-2](#glossary-round-2) corrections rebuilt `panel-routing.jsonl` from the regenerated `scored`/`panel_routed` artifacts (see [§4](#4-panel-coverage--inter-rater-stats) preamble and [§4.3](#43-inter-rater-κ--two-granularities)); this subsection is not a description of the current panel-routing.jsonl.

All 12 round-1 routed [recs](#glossary-rec) concentrated on a single [cluster](#glossary-cluster): the `HSBColor.uiColor` ↔ `HSBColor.nsColor` near-duplicate (Jaccard 0.71) inside `Shared/ColorPalette/Sources/ColorPalette/HSBColor.swift` (see [HSBColor glossary entry](#glossary-hsbcolor)). The agent's recommendation across all (condition, [trial](#glossary-trial)) combinations was the same in substance — extract a private HSB-to-color helper, or use `#if canImport(UIKit)/#if canImport(AppKit)` conditional compilation, and decline the named taxonomy categories on the grounds that `UIColor` and `NSColor` are unrelated nominal types.

Panel scoring assigned each routed pair one of two values:

| Bound plant | Plant intent | Panel score | Rationale |
|---|---|---|---|
| [Plant 5.1](plant-manifest.yaml) ([generic-parameterization](../../docs/refactor-recommendation-experiment-methodology.md#55-category-5--generic-parameterization-struct-or-function)) | `platformColor<Color: PlatformColor>` generic function unifying `uiColor` / `nsColor` | **0.3** ([adjacent_wrong_category](#glossary-adjacent-wrong-category) — "wrong category but adjacent and defensible") | Agent saw the right cluster, cited the right symbols (`HSBColor`, `uiColor`, `nsColor`, `UIColor`, `NSColor` — matches `rationale_must_cite`), but dismissed the generic abstraction without considering a `PlatformColor` typealias/protocol bridge. Closest taxonomy fit is `extract-to-common`, rubric-adjacent to `generic-parameterization`. |
| [Plant 3.1](plant-manifest.yaml) ([default-implementation](../../docs/refactor-recommendation-experiment-methodology.md#53-category-3--default-implementation)) | `HSBStorage` protocol with a default `init(hue:saturation:brightness:)` across HSBColor / AccentColor / HSBOffset | **0.0** (false binding) | The HSBColor uiColor/nsColor cluster is Plant 5.1's signal, not Plant 3.1's. The bind happened because `HSBColor.swift` appears in `Plant 3.1.source_files` (HSBColor is one of the three conformers), but the panel-routed cluster doesn't surface Plant 3.1's init-pattern signal. Agent's helper recommendation does not engage with Plant 3.1's refactor. |

[`promote_panel_scores`](#glossary-code-references) (new in this writeup; [`score_all.py`](score_all.py)) backfills these scores into `auto-scores.json::scored` before aggregation. Effect on the headline: Plant 5.1's best-across-trials moves from `max(0.0, 0.0, 0.0) = 0.0` to `max(0.3, 0.3, 0.3) = 0.3` in S1 (+0.015 to the 20-plant mean), and is unchanged in S2 (panel 0.3 ties existing auto-scored 0.3 cells). Plant 3.1's headline is unchanged in either condition — the 0.0 panel score doesn't promote anything.

### 4.2 Binding-artifact finding (resolved in round 2)

The [HSBColor](#glossary-hsbcolor) cluster binding to both [Plant 3.1](plant-manifest.yaml) and [Plant 5.1](plant-manifest.yaml) surfaces a [substring-match limitation](#glossary-binding) in [`bind_recs_to_plants`](#glossary-code-references) ([`score_all.py`](score_all.py)): a cluster touching one of a plant's `source_files` binds to that plant even when the cluster doesn't surface the plant's pre-registered signal shape. [Round 1](#glossary-round-1) lived with this — 6 false bindings concentrated on one cluster don't move the headline since the panel scores those as 0.0.

The [round-1 closeout](#glossary-round-1-closeout) ([plan](../../plans/v7-phase-e-round1-closeout-plan.md)) shipped a *prefer-signal-match resolution rule* in `bind_recs_to_plants`: when a cluster substring-matches multiple plants, bind only to those whose [`expected_substrate_signals`](#glossary-expected-substrate-signals) include the rec's `query`. This cleaned up 24 incidental false bindings across the corpus (Plant 3.1 −3, [Plant 3R](#glossary-restraint-plant) −9, Plant 5.1 −3, [Plant 5.3](plant-manifest.yaml) −9) — none of which were in the panel-routed set, so the headline was unchanged. But the rule did NOT fix the Plant 3.1 ↔ 5.1 panel-routed co-binding for HSBColor: both plants legitimately list `function-duplicates` in their signals AND both have HSBColor.swift in their source_files, so the resolution is ambiguous at the (path, query) granularity.

**[Round 2](#glossary-round-2) ([rubric-modifications.md](rubric-modifications.md), 2026-05-18)** added a per-plant [`expected_cluster_symbols`](#glossary-expected-cluster-symbols) manifest field gating bindings on planted-symbol substring membership in cluster_id. Plant 3.1's symbols (`HSBColor.init(...)`, `AccentColor.init`, `HSBOffset.init`) don't appear in the panel-routed `function-duplicates-near:HSBColor.uiColor+HSBColor.nsColor` cluster; Plant 5.1's symbols do. The 6 Plant 3.1 false-binding panel routings drop out; the 6 Plant 5.1 panel routings persist as the legitimate binding. `panel_routed.size` goes 12 → 6.

### 4.3 Inter-rater κ — two granularities

[Round 1](#glossary-round-1) used a single expert reviewer (`analyses/panel-scores-reviewer-1.jsonl`); the pre-registered design called for 3 ([methodology §17](../../docs/refactor-recommendation-experiment-methodology.md#17-decisions-outstanding-before-kickoff) decision #3). The [`reproducibility.yaml` `round1_deviation` block](reproducibility.yaml) records the rationale: the 12 round-1 routed pairs reduced to two distinct judgements ([Plant 5.1](plant-manifest.yaml) binding [adjacent-defensible](#glossary-adjacent-wrong-category); [Plant 3.1](plant-manifest.yaml) binding false-positive), so the methodology overhead of two more reviewers was disproportionate at the round-1 corpus size. [Round 2](#glossary-round-2)'s two corrections changed the picture meaningfully: the symbol gate (§4.2) dropped the Plant 3.1 panel rows, and [value-aware specifics matching](#glossary-value-aware-matching) (§7) routed 102 new [`primary_match_specifics_outside_tolerance`](#glossary-primary-match-specifics-outside-tolerance) rows to panel — growing the backlog from 6 surviving rows / 1 distinct judgment to **108 rows / 29 distinct `(plant_id, cluster_id)` judgments**. Round 2 adds the missing reviewers — same regenerated `panel-routing.jsonl`, two new `panel-scores-reviewer-N.jsonl` files concatenated into the consolidated file, then [`score_all.py`](score_all.py) populates **both** `inter_rater.fleiss_kappa` ([rec](#glossary-rec)-level) and `inter_rater_collapsed.fleiss_kappa` (judgment-level). Both functions filter orphan rec_tokens identically and surface the orphan count in the structured note (see [`score_all.py::attach_panel_kappa`](#glossary-code-references) and [`::attach_collapsed_panel_kappa`](#glossary-code-references)).

The 108 panel rows are not 108 independent items — they reduce to 29 distinct (plant_id, cluster_id) judgments. Within most judgments the rows are duplicates: the same cluster surfaced under multiple [trials](#glossary-trial) × conditions, and the agent re-phrases the rationale per trial but lands at the same substantive recommendation. A reviewer scoring on substance gives all duplicates of one judgment the same value; a reviewer scoring on prose granularity might vary. [Round-1 closeout](#glossary-round-1-closeout) added a second [κ measure](#glossary-fleiss-kappa) to `score_all.py` for exactly this case — see [`analyses/panel-instructions.md` §6](analyses/panel-instructions.md#6-round-2-panel-coverage-and-the-correlated-items-caveat) for the interpretation rules:

- **`inter_rater`** — Fleiss κ over the surviving rec rows × N raters. Methodology §8 / §12 literal measure. Inflated if reviewers give correlated scores across duplicates.
- **`inter_rater_collapsed`** — Fleiss κ over distinct (plant_id, cluster_id) judgments × N raters (per-(reviewer, judgment) median of the duplicates). The intended primary measure for round 2: with **N=29 distinct judgments** post-#90 (vs round 1's degenerate N=1), the collapsed κ has real statistical power and is the actionable signal once the missing reviewers land.
- **`inter_rater_collapsed.within_reviewer_inconsistency_count`** — diagnostic: number of (reviewer, judgment) cells where the reviewer scored duplicates inconsistently. High → reviewers are prose-sensitive; low → reviewers are substance-only.

#### Round-2 final state (placeholders — fill in when [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94) lands)

`analyses/score-summary.json` still carries the round-1 sentinels — `score_all.py` computes κ over the *already-scored* panel rows, and the 102 new `primary_match_specifics_outside_tolerance` rows surfaced by #90 are awaiting [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) reviewer recruitment. When all three reviewers have scored the regenerated `panel-routing.jsonl`, `attach_panel_kappa` / `attach_collapsed_panel_kappa` repopulate the blocks against N=108 rows / N=29 judgments × 3 raters:

```json
{"fleiss_kappa": <TBD>, "n_items": 108, "n_raters": 3, "note": null}
{"fleiss_kappa": <TBD>, "n_judgments": 29, "n_raters": 3, "within_reviewer_inconsistency_count": <TBD>, "note": null}
```

For reference, the current (pending) sentinels (note text shortened for readability):

```json
{"fleiss_kappa": null, "n_items": 6, "n_raters": 1, "note": "only 1 reviewer(s) present; Fleiss κ requires ≥2"}
{"fleiss_kappa": null, "n_judgments": 1, "n_raters": 1, "within_reviewer_inconsistency_count": 0, "note": "only 1 reviewer(s) present; Fleiss κ requires ≥2"}
```

The current sentinel's `n_items: 6 / n_judgments: 1` reflects only the round-1 HSBColor judgment that the single reviewer scored — `score_all.py::attach_*_kappa` count over the SCORED subset of `panel-routing.jsonl`, not the full backlog. Once reviewer-1 extends to the remaining 28 judgments (29 distinct total − the 1 round-1 HSBColor judgment already scored) and reviewer-2/3 contribute, the sentinels promote to numeric κ over the full 29-judgment population. Round 1's `within_reviewer_inconsistency_count == 0` (single reviewer, scored all 6 duplicates of Plant 5.1's HSBColor judgment identically) confirms substance-only scoring at the round-1 corpus size; whether that holds at N=29 is one of the round-2 finalization's main signals.

## 5. Restraint plants — false-positive breakdown

Per the [methodology §9](../../docs/refactor-recommendation-experiment-methodology.md#9-restraint-and-false-positive-measurement) restraint table, [restraint plants](#glossary-restraint-plant) score under their own rubric. The 5 restraint plants (1R, 2R, 3R, 4R, 5R) produced these per-condition outcomes under the [round-2](#glossary-round-2) symbol gate:

| Plant | [S1](#glossary-s1) best | [S2](#glossary-s2) best | Action recs observed? |
|---|---|---|---|
| [1R](#glossary-plant-1r) ([extract-to-common](../../docs/refactor-recommendation-experiment-methodology.md#51-category-1--extract-to-common)) | 0.5 ([no_action_ungrounded](#glossary-no-action-ungrounded)) | 0.5 (no_action_ungrounded) | No (after round-2 symbol gate) |
| [2R](plant-manifest.yaml) ([protocol-inheritance](../../docs/refactor-recommendation-experiment-methodology.md#52-category-2--protocol-inheritance)) | (no recs in S1) | 1.0 ([no_action_grounded](#glossary-no-action-grounded)) | No |
| [3R](plant-manifest.yaml) ([default-implementation](../../docs/refactor-recommendation-experiment-methodology.md#53-category-3--default-implementation)) | 0.5 | 0.5 | No |
| [4R](plant-manifest.yaml) ([pat-introduction](../../docs/refactor-recommendation-experiment-methodology.md#54-category-4--pat-introduction)) | 1.0 (no_action_grounded) | 0.5 (no_action_ungrounded) | No |
| [5R](plant-manifest.yaml) ([generic-parameterization](../../docs/refactor-recommendation-experiment-methodology.md#55-category-5--generic-parameterization-struct-or-function)) | 0.5 | 0.5 | No |

**[FPR](#glossary-fpr) = 0/5 = 0.000** under both conditions after [round 2](#glossary-round-2) (see [§4.2](#42-binding-artifact-finding-resolved-in-round-2) and [rubric-modifications.md](rubric-modifications.md)). The [round-1](#glossary-round-1) headline of 0.200 came entirely from [Plant 1R](#glossary-plant-1r)'s incidental `DebugMetricsProvider` bindings on [`DebugHUD.swift`](#glossary-debughud) — clusters that substring-matched Plant 1R's source file but did NOT surface its planted `MetricRow` symbol. The [symbol gate](#glossary-binding) ([`expected_cluster_symbols`](#glossary-expected-cluster-symbols)`: ["MetricRow"]`) blocks those bindings; the 30 remaining Plant 1R bindings all receive `no-action` from the agent, so the restraint's per-cell FPR is 0.0 in all 6 (condition, [trial](#glossary-trial)) cells.

The agent's behavior on Plant 1R's canonical `MetricRow` clusters was already correct in round 1 (no-action, `reason_class: "sample-app-mirror"`); the [round-1 closeout's A3 prompt edit](#glossary-a3-prompt-edit) (`is_test=true | is_mock=true | is_sample_app=true` on ANY participating record now treated as load-bearing) is forward-looking methodology infrastructure whose measurable effect would land if a future restraint plant produces clusters the symbol gate doesn't reach.

## 6. Variance across trials

[Trial](#glossary-trial)-to-trial variance is small. Per (condition, category) cell, the trial-1/trial-2/trial-3 [canonical_recall](#glossary-canonical-recall) values agree to within 0.1 in 14 of 15 cells, and exactly in 11 of 15 cells. No V4-style batching-variance signature ([methodology §14](../../docs/refactor-recommendation-experiment-methodology.md#14-pre-mortem-failure-modes-diagnostics-recovery), §14.4 sub-topic) is observed — the per-[rec](#glossary-rec) count and per-rec category mix are stable across trials, consistent with the substrate-emitted `cluster_id` ([#5](https://github.com/jakebromberg/code-audit-pipeline/issues/5)) prerequisite having landed before [Phase D](#glossary-phase-d).

The one cell with non-trivial trial variance: [S2](#glossary-s2) [default-implementation](../../docs/refactor-recommendation-experiment-methodology.md#53-category-3--default-implementation), where [Plant 3.1](plant-manifest.yaml) scored 1.0 in trial 1, 0.0 in trial 2, 1.0 in trial 3. The trial-2 dip is genuine trial-to-trial agent variance — the agent didn't surface Plant 3.1's `init(hue:saturation:brightness:)` default-impl refactor on that pass (both of Plant 3.1's S2-trial-2 scored pairs land at 0.0 under the [round-2 symbol gate](#glossary-binding); the [round-1](#glossary-round-1) panel-resolved [HSBColor](#glossary-hsbcolor) [`other_routes_to_panel`](#glossary-other-routes-to-panel) rec that previously contributed to this cell was a false binding now dropped by the gate per [§4.2](#42-binding-artifact-finding-resolved-in-round-2)).

## 7. Sensitivity to specifics-tolerance (resolved in round 2)

The [round-1](#glossary-round-1) auto-scorer was **[key-only](#glossary-value-aware-matching)** on specifics matching; [round 2](#glossary-round-2) added verbatim value comparison per [methodology §8](../../docs/refactor-recommendation-experiment-methodology.md#8-scoring-rubric) lines 626–631. The round-2 PR ([PR #90](https://github.com/jakebromberg/code-audit-pipeline/pull/90), closing [`#35`](https://github.com/jakebromberg/code-audit-pipeline/issues/35)) is the operationalization of "specifics fall outside tolerance → panel-route." See the [`rubric-modifications.md`](rubric-modifications.md) round-2 [value-aware-specifics entry](#glossary-value-aware-matching) for the design rationale, projection data, and per-plant flip distribution.

Sensitivity-to-tolerance per the round-2 measurement: of the 102 rows that fired [`primary_match_full`](#glossary-primary-match-full) (37) or [`primary_match_weak_rationale`](#glossary-primary-match-weak-rationale) (65) under round-1's key-only scoring, **100% flipped** under value-aware comparison — every row had at least one mismatched required value. Mismatch classification: 95.1% substantive (different identifier, different target package, missing required constraint value), 4.9% trivial (manifest-side parenthetical commentary that the agent didn't reproduce, all on [Plant 3.4](plant-manifest.yaml)). The plan §3.3 decision gate (trivial ≤ 30% to merge) passed comfortably.

Where round-1 said "key-only over-credit is bounded for the planted clusters in this corpus" — that read does not hold under value-aware scoring. The over-credit was substantial: the headline [`canonical_recall`](#glossary-canonical-recall) shifts from S1=0.270 / S2=0.615 (key-only) to S1=0.070 / S2=0.110 (value-aware), with 108 rows routed to panel awaiting [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) reviewer recruitment. Panel scores against the routed cohort will determine the auto-plus-panel headline. The follow-up [§10 round-3 prompt-sensitivity sub-experiment](#10-prompt-sensitivity-sub-experiment-round-3--h0a-supported) tested whether the resulting panel-route load is driven by prompt vagueness ([H1](#101-hypotheses-tested)) or model-capability ceiling ([H0a](#101-hypotheses-tested)); outcome: H0a.

## 8. Known limitations

- **[Plant 1.4](plant-manifest.yaml) does not surface under either condition.** Pre-populated with [`expected_cluster_symbols`](#glossary-expected-cluster-symbols)`: ["SystemQualityClock", "SystemClock"]` per [methodology §10](../../docs/refactor-recommendation-experiment-methodology.md#10-pre-registration-discipline) discipline, but its source files don't surface in any [V7](#glossary-substrate) cluster_id — the V7 substrate doesn't currently catalog the planted shape. [Round-3](#glossary-round-3) substrate work can re-place or replace it. ([Plant 5.4](plant-manifest.yaml) — previously listed alongside 1.4 — does surface: 2 clusters under the [round-1-closeout rule](#glossary-round-1-closeout), 6 under [round 2](#glossary-round-2)'s [symbol gate](#glossary-binding), both pointing at `_Plant_IntCache` / `_Plant_StringCache`.)
- **[Plant 1R](#glossary-plant-1r) restraint false-positive (resolved in round 2).** [Round-1](#glossary-round-1) audit showed the agent already emits `no-action` with `reason_class: "sample-app-mirror"` on Plant 1R's two canonical clusters; the 1.0 per-cell [FPR](#glossary-fpr) came from incidental bindings — `DebugMetricsProvider` clusters in [`DebugHUD.swift`](#glossary-debughud) (Plant 1R's source file) that aren't about `MetricRow`. Round 2's [symbol-level binding](#glossary-binding) fix ([rubric-modifications.md](rubric-modifications.md)) gates Plant 1R bindings on the `MetricRow` symbol, eliminating the incidental `DebugMetricsProvider` bindings. Plant 1R per-cell FPR is 0.0 in all 6 cells. The [round-1 closeout's A3 prompt edit](#glossary-a3-prompt-edit) (rule 1 of the agent prompt now treats `is_test=true | is_mock=true | is_sample_app=true` on ANY participating record as load-bearing) is forward-looking methodology infrastructure whose measurable effect would land if a future restraint plant produces clusters the symbol gate doesn't reach.
- **[Inter-rater κ](#glossary-fleiss-kappa) undefined in round 1.** The pre-registered 3-reviewer panel ran with 1 expert reviewer in round 1 (see [§4.3](#43-inter-rater-κ--two-granularities) and the [`round1_deviation` block in reproducibility.yaml](reproducibility.yaml)). The `score-summary.json::inter_rater` block carries the panel-pending sentinel; round 2 recruits the missing two reviewers to populate a numeric κ over the same panel-routing artifact.
- **Substring-match binding produces false positives (resolved in round 2).** The [round-1-closeout](#glossary-round-1-closeout) prefer-signal-match rule cleaned up 24 incidental false bindings. Round 2's [`expected_cluster_symbols`](#glossary-expected-cluster-symbols) gate closes the remaining gaps — the panel-routed Plant 3.1 / [5.1](plant-manifest.yaml) co-binding on [HSBColor](#glossary-hsbcolor) and Plant 1R's structural FPR both stem from (path, query)-granularity ambiguity that symbol-level matching resolves. See [§4.2](#42-binding-artifact-finding-resolved-in-round-2) and [rubric-modifications.md](rubric-modifications.md).
- **Auto-scorer over-credit risk (resolved in round 2).** Round 2's [value-aware specifics matching](#glossary-value-aware-matching) ([`rubric-modifications.md`](rubric-modifications.md), resolves [`#35`](https://github.com/jakebromberg/code-audit-pipeline/issues/35)) replaces [key-only matching](#glossary-value-aware-matching) with verbatim value comparison; out-of-tolerance specifics route to panel per [methodology §8](../../docs/refactor-recommendation-experiment-methodology.md#8-scoring-rubric) lines 626–631 instead of auto-scoring 1.0. The corrected headline [`canonical_recall`](#glossary-canonical-recall) (S1=0.070, S2=0.110) is substantially below the round-1 over-credit number (S1=0.270, S2=0.615); the gap routes through the 108 panel-routed rows pending [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) reviewer recruitment.

## 9. Reproducibility

All inputs to this writeup are pinned in [`reproducibility.yaml`](reproducibility.yaml):

- `pre_registration.repo_sha`, `substrate_sha`, `plant_tree_sha`, `manifest_hash`, `rubric_hash`, `prompt_hash`, per-catalog and per-query hashes
- `execution.model_versions.primary` = `claude-sonnet-4-6` (alias, pin documented in `reproducibility.yaml` comment block since Anthropic did not publish a date-pinned 4.6 variant by the trial window — see [#66](https://github.com/jakebromberg/code-audit-pipeline/issues/66))
- `execution.actual_spend_usd` = $39.46 (well under the [methodology §6](../../docs/refactor-recommendation-experiment-methodology.md#6-substrate-enrichments-v7-needs) §6.3 sub-topic hard cap of $120)
- `execution.trial_date_range` = 2026-05-15 (single-day [Phase D](#glossary-phase-d) run)
- `execution.panel_composition` = 1 internal expert reviewer ([round 1](#glossary-round-1); pre-registered as 3 per [methodology §17](../../docs/refactor-recommendation-experiment-methodology.md#17-decisions-outstanding-before-kickoff) decision #3 — see `round1_deviation` block); `panel_composition.round2_methodology_update` records the [round-2](#glossary-round-2) symbol-gate addition (see [rubric-modifications.md](rubric-modifications.md))
- `execution.rubric_modifications` = [`experiments/v7-refactor-recommendation/rubric-modifications.md`](rubric-modifications.md) (round 2 added [`expected_cluster_symbols`](#glossary-expected-cluster-symbols) ([PR #89](https://github.com/jakebromberg/code-audit-pipeline/pull/89)) and [value-aware specifics matching](#glossary-value-aware-matching) ([PR #90](https://github.com/jakebromberg/code-audit-pipeline/pull/90), resolves [#35](https://github.com/jakebromberg/code-audit-pipeline/issues/35)); round 1 carried no post-hoc edits)

Re-running [`score_all.py`](score_all.py) against the same parsed cache + the committed `analyses/panel-scores.jsonl` reproduces [`analyses/auto-scores.json`](analyses/auto-scores.json) and [`analyses/score-summary.json`](analyses/score-summary.json) byte-for-byte (verified with `md5sum` across two consecutive runs). Reproducing the headline without panel scores: rename `analyses/panel-scores.jsonl` aside and rerun — `inter_rater` falls back to the "panel scores file not present" sentinel, and [`promote_panel_scores`](#glossary-code-references) is a no-op so the headline reverts to the auto-scored-only `S1=0.070 / S2=0.110` (the corrected post-value-aware numbers; the round-1 pre-correction numbers were `S1=0.270 / S2=0.615`, recoverable from the `rubric-modifications.md` round-2 value-aware-specifics entry).

## 10. Prompt-sensitivity sub-experiment (round 3) — H0a supported

Round-3 sub-experiment per [`plans/v7-round2-prompt-sensitivity-plan.md`](../../plans/v7-round2-prompt-sensitivity-plan.md), pre-registered in the [`rubric-modifications.md` round-3 entry](rubric-modifications.md#round-3--prompt-sensitivity-sub-experiment-2026-05-20), tests prompt-vagueness ([H1](#101-hypotheses-tested)) vs model-capability-ceiling ([H0a](#101-hypotheses-tested)) explanations for [round-2's panel-route load (§7)](#7-sensitivity-to-specifics-tolerance-resolved-in-round-2). The experimental arm holds the rubric, manifest, model alias, and harness telemetry fixed and varies only the prompt: v2 tightens the §2 specifics schemas for all five action categories with structural-constraint language ("the `protocol` field must name a type that already exists in the cluster's source files," etc.) and adds one synthetic non-corpus worked example per category at §2.1. Full design rationale, decision tree, and budget envelope live in the plan; the pre-registered acceptance threshold per [plan §3.4](../../plans/v7-round2-prompt-sensitivity-plan.md#34-pre-registered-analysis) is **overall panel-route rate drops by ≥ 50% (relative)** for H1; otherwise H0a per the decision tree. The pre-registration discipline this entry follows is [methodology §10](../../docs/refactor-recommendation-experiment-methodology.md#10-pre-registration-discipline); the sub-experiment budget envelope is [methodology §16](../../docs/refactor-recommendation-experiment-methodology.md#16-minimum-viable-round).

### 10.1 Hypotheses tested

Full definitions in [plan §1](../../plans/v7-round2-prompt-sensitivity-plan.md#1-context-and-motivation); summarized here so the rest of §10 reads cold:

- **H1 — prompt vagueness.** The v1 [`§2` specifics schemas](../../docs/refactor-recommendation-experiment-agent-prompt.md) are general enough that the agent emits reasonable-but-different values. Sharpening (more structural constraints + per-category worked examples) should let the agent hit tolerance directly, dropping the panel-route rate.
- **H0a — model capability ceiling.** The agent can't reason about these tolerances regardless of prompt sharpness. Sharpening produces no change.
- **H0b — rubric over-strictness.** The auto-scorer's verbatim-match check is too strict; values like `BlendMode` vs `BlendModeConvertible` are structurally equivalent but lexically different. Out of scope for this sub-experiment; a separate sub-experiment would test it if H1 fails and the headline finding still needs interpretation (see [§10.7](#107-follow-up-h0b-sub-experiment-recommendation)).

### 10.2 Drift-check

[PR #100](https://github.com/jakebromberg/code-audit-pipeline/pull/100), [`analyses-v2/drift-check.json`](analyses-v2/drift-check.json). 30 recs stratified across 5 plant categories × balanced S1/S2 conditions, sampled at `seed=20260520`, scored against the round-2 corpus at the v1 prompt. All three pre-registered tolerances (per [plan §3.2](../../plans/v7-round2-prompt-sensitivity-plan.md#32-drift-check-protocol)) pass: category disagreement 1/30 = 3.3% (threshold ≤ 20%), specifics-key drift 3.3% average (threshold ≤ 30%), panel-route rate delta +3.33pp (threshold ±10pp). Captured response model `claude-sonnet-4-6` for all 30 calls (per [#66](https://github.com/jakebromberg/code-audit-pipeline/issues/66)'s alias-stability concern). Decision: proceed.

### 10.3 Substrate divergence remediation

The regenerated substrate used at drift-check time differed from `pre_registration.plant_tree_sha` by 1 swift file in 485 (0.2%). Cluster rows are looked up by `cluster_id` (not row_index), so the drift-check sample resolved cleanly under the regenerated catalogs; the headline metrics were unaffected. To preclude conflating prompt sensitivity with substrate noise in [PR #102](https://github.com/jakebromberg/code-audit-pipeline/pull/102), the v1 control was *re-controlled* against the same regenerated substrate ([plan §3.2 halt-recovery option (a)](../../plans/v7-round2-prompt-sensitivity-plan.md#32-drift-check-protocol)), producing [`analyses-v1-clean/`](analyses-v1-clean/). The round-2 [`analyses/`](analyses/) and [`trial-logs/`](trial-logs/) artifacts are preserved untouched as the historical v1-against-original-substrate snapshot. The v1-clean re-control cost $41.77 (2901 v1 recs at the regenerated substrate, 2026-05-20T15:25–16:43); the v2 main run cost $51.59 (2901 v2 recs, 2026-05-20T16:29–18:12). Both arms are 522 scored pairs.

### 10.4 Headline panel-route delta

`v2 − v1-clean`, from [`analyses-v2/prompt-sensitivity.json`](analyses-v2/prompt-sensitivity.json):

| Condition | v1-clean panel-route rate | v2 panel-route rate | Absolute Δ | Relative Δ |
|---|---|---|---|---|
| S1 | 14.58% (28/192) | 11.98% (23/192) | −2.60pp | −17.86% |
| S2 | 27.58% (91/330) | 25.76% (85/330) | −1.82pp | −6.59% |
| **Overall** | **22.80%** (119/522) | **20.69%** (108/522) | **−2.11pp** | **−9.24%** |

The 9.24% overall relative drop is far below the pre-registered 50% threshold. Per the [plan §3.4](../../plans/v7-round2-prompt-sensitivity-plan.md#34-pre-registered-analysis) decision tree, drift-check pass × acceptance fail → **[H0a](#101-hypotheses-tested) supported (model capability ceiling)**: the v2 prompt's structural-constraint language and non-corpus worked examples do not measurably bound the agent into hitting the manifest's `primary_answer.specifics` values. The headline panel-route load is not primarily driven by prompt vagueness.

### 10.5 Per-category panel-route delta

S1+S2 combined; denominators are *scored pairs* per category × condition × trial:

| Category | v1-clean | v2 | Absolute Δ | Relative Δ |
|---|---|---|---|---|
| default-implementation | 30.07% (46/153) | 24.84% (38/153) | −5.23pp | **−17.39%** |
| protocol-inheritance | 18.92% (21/111) | 15.32% (17/111) | −3.60pp | **−19.05%** |
| generic-parameterization | 38.33% (23/60) | 33.33% (20/60) | −5.00pp | **−13.04%** |
| extract-to-common | 18.52% (15/81) | 18.52% (15/81) | 0.00pp | 0.00% |
| pat-introduction | 11.97% (14/117) | 15.38% (18/117) | +3.42pp | **+28.57%** |

The category-level response is **heterogeneous**, not uniform. Three categories (default-implementation, protocol-inheritance, generic-parameterization) show modest reductions in the 13–19% relative range — consistent with the v2 worked examples and structural-constraint language *partially* steering the agent toward grounded answers, but not nearly enough to clear the 50% bar. Extract-to-common is exactly flat: the v2 structural constraints ("the `target_package` MUST name a package that exists in the source tree and is upstream of all consumer packages") did not change the agent's behavior — agent recommendations on [Plant 1.1](plant-manifest.yaml) still pick `app:iOS` instead of the manifest-expected `Shared/Branding` (the "upstream of all consumers" constraint is descriptive, but the agent does not reason about upstream-of relationships from the v2 prompt alone). Pat-introduction *increased* its panel-route rate by 28.6% relative — the v2 worked example for PATs (the synthetic `RetryPolicy` template applied across three unrelated consumers) appears to encourage the agent to *attempt* PAT recommendations on more clusters, but those attempts still miss the manifest's `pat_name` / `applies_to` specifics. The heterogeneity rejects a simple [H1](#101-hypotheses-tested) ("sharpening uniformly helps") but it is also informative: H1 contributes a non-zero but small effect on three categories. The dominant explanation remains [H0a](#101-hypotheses-tested), with a measurable H1 floor at ≈ −15% relative on the three categories where structural constraints engaged.

### 10.6 Headline canonical-recall delta

Auto-scored only; panel-pending — see caveat below:

| Condition | v1-clean canonical_recall | v2 canonical_recall | Absolute Δ |
|---|---|---|---|
| S1 | 0.070 | 0.055 | −0.015 |
| S2 | 0.110 | 0.105 | −0.005 |

Both deltas are within the noise floor for a 4-trial × 5-category corpus; the v2 numbers should not be interpreted as a real recall regression. The [H0a](#101-hypotheses-tested) decision rests on panel-route rate, not on canonical_recall, per [plan §3.4](../../plans/v7-round2-prompt-sensitivity-plan.md#34-pre-registered-analysis)'s baseline-invariance argument: panel-route rate is determined purely by the auto-scorer's match-label classification and is invariant under panel-scoring completion ([#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85), [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94)). Once #94 finalizes, the canonical_recall numbers in this table update via `promote_panel_scores`; the headline outcome (H0a) does not change.

### 10.7 Follow-up: H0b sub-experiment recommendation

[Plan §1](../../plans/v7-round2-prompt-sensitivity-plan.md#1-context-and-motivation) pre-registered [H0b](#101-hypotheses-tested) (rubric over-strictness) as the next sub-experiment to run "if H1 fails and the headline finding still needs interpretation." It does: [round-2's panel-route load (§7)](#7-sensitivity-to-specifics-tolerance-resolved-in-round-2) is real, the v2 prompt did not move it, and the per-category breakdown ([§10.5](#105-per-category-panel-route-delta)) — default-implementation [Plant 3.2](plant-manifest.yaml) "BlendMode" vs "BlendModeConvertible," [Plant 3.3](plant-manifest.yaml) "AudioProcessor" vs "NormalizationModeConfigurable" — suggests several mismatches that route to panel are *structurally equivalent but lexically different*, exactly the H0b symptom. A recommended next sub-experiment would test whether a *rubric loosening* (e.g., naming-equivalence relaxation, semantic-substring match for known-equivalent identifiers) drops the panel-route rate without changing the agent's behavior. That is a separate pre-registration. This sub-experiment closes the H1 vs H0a question with H0a supported and the H1 floor at ≈ 15% relative on a subset of categories.

### 10.8 Reproducibility

The v2 prompt is pinned at SHA-256 `22f53bfa1f5c8b27671c1b26c052c5e138a923905ae7349f07677757a29ea19d`; the plan at `0853d4465961696adc647ee3ca86b470b44a04b599b849cf004e0e46a9fd8715`; the overlap-check script at `305aba5e0eab4a5b291d48edeac4ccf0fd84fce7add76ba565af7577088b880f`. Drift-check parameters and acceptance threshold were frozen by [PR #99](https://github.com/jakebromberg/code-audit-pipeline/pull/99) merge (per [`rubric-modifications.md` round-3 entry](rubric-modifications.md#round-3--prompt-sensitivity-sub-experiment-2026-05-20)) before any rerun executed. Re-running [`score_all.py`](score_all.py) against either trial-logs directory regenerates the corresponding `analyses-*/` outputs byte-for-byte. The full per-condition × per-category delta matrix lives in [`analyses-v2/prompt-sensitivity.json`](analyses-v2/prompt-sensitivity.json); the round-3 [`rubric-modifications.md` entry](rubric-modifications.md#round-3--prompt-sensitivity-sub-experiment-2026-05-20) carries the matched outcome record. The sub-experiment outcome lands in [`reproducibility.yaml`](reproducibility.yaml) at `execution.prompt_sensitivity_sub_experiment.sub_experiment_outcome = "H0a supported"`.

## Glossary

A short reference for the doc's jargon. Terms that have a canonical defining source elsewhere link to it rather than redefining; entries below define the cross-cutting concepts that don't have a single home doc.

### Conditions and substrate

- <a name="glossary-s1"></a>**S1.** "Cold" condition: agent runs against the V6 substrate. Pre-V7 query set; no `pat-candidates`, `protocol-inheritance-candidates`, `default-impl-candidates`, `generic-struct-candidates`, or `generic-function-candidates`. See [methodology §11](../../docs/refactor-recommendation-experiment-methodology.md#11-conditions-to-compare).
- <a name="glossary-s2"></a>**S2.** "Warm" condition: agent runs against the V7 substrate (V6 plus the five new queries above). The full V7 substrate is detailed in [methodology §6.8](../../docs/refactor-recommendation-experiment-methodology.md#68-new-queries-that-consume-the-new-substrate).
- <a name="glossary-substrate"></a>**Substrate.** The structured catalog of "shape signals" the agent reads: pairs and clusters emitted by static-analysis queries over the source tree. V6 is the round-1 baseline; V7 is the current generation. The substrate is **not** the source files themselves; it's the queries' output.
- <a name="glossary-cluster"></a>**Cluster.** A single row emitted by one substrate query. Each `cluster_id` encodes the query name + the participating source records (file paths, types, function names). Clusters are what the agent reads; recommendations are produced one-per-cluster.
- <a name="glossary-rec"></a>**Rec.** A single agent recommendation: one `(category, rationale, specifics, evidence)` tuple per cluster. Parsed from the agent's JSON output.
- <a name="glossary-trial"></a>**Trial.** A single agent run over the full corpus under one condition. Round 1, round 2, and round 3 each use 3 trials per condition (S1, S2) for variance estimation.

### Plants

Full manifest in [`plant-manifest.yaml`](plant-manifest.yaml). 25 plants total; 20 canonical + 5 restraint.

- <a name="glossary-canonical-plant"></a>**Canonical plant.** A planted refactor opportunity the agent SHOULD identify. Contributes to [canonical_recall](#glossary-canonical-recall). Carries IDs like Plant 1.1, 3.2, 5.4. Categories 1–5 correspond to the methodology's [extract-to-common](../../docs/refactor-recommendation-experiment-methodology.md#51-category-1--extract-to-common), [protocol-inheritance](../../docs/refactor-recommendation-experiment-methodology.md#52-category-2--protocol-inheritance), [default-implementation](../../docs/refactor-recommendation-experiment-methodology.md#53-category-3--default-implementation), [PAT-introduction](../../docs/refactor-recommendation-experiment-methodology.md#54-category-4--pat-introduction), and [generic-parameterization](../../docs/refactor-recommendation-experiment-methodology.md#55-category-5--generic-parameterization-struct-or-function) categories respectively.
- <a name="glossary-restraint-plant"></a>**Restraint plant.** A planted *non*-refactor — code that looks like a refactor opportunity but isn't (test mocks, sample-app patterns, etc.) where the agent SHOULD output `no-action`. Carry IDs Plant 1R, 2R, 3R, 4R, 5R (one per category). Contribute to [FPR](#glossary-fpr) / [1−FPR](#glossary-1-fpr). Defined in [methodology §9](../../docs/refactor-recommendation-experiment-methodology.md#9-restraint-and-false-positive-measurement).
- <a name="glossary-plant-1r"></a>**Plant 1R.** Extract-to-common restraint. Source files include `DebugHUD.swift`; planted shape is `MetricRow`-style debug UI on the WatchXYC sample app. Agent should decline with `reason_class: "sample-app-mirror"`. Round-1 carried a structural FPR (16 unrelated `DebugMetricsProvider` clusters in `DebugHUD.swift` incidentally bound to Plant 1R via substring-match) that round-2's `expected_cluster_symbols: ["MetricRow"]` gate eliminated. See [§4.2](#42-binding-artifact-finding-resolved-in-round-2), [§5](#5-restraint-plants--false-positive-breakdown), [`rubric-modifications.md` round-2 symbol-level-binding entry](rubric-modifications.md).
- <a name="glossary-debughud"></a>**DebugHUD.swift.** Plant 1R's source file. Several unrelated clusters from this file (e.g., the `DebugMetricsProvider` cluster) substring-match Plant 1R but don't surface its planted `MetricRow` symbol; the round-2 symbol gate blocks the incidental bindings.
- <a name="glossary-hsbcolor"></a>**HSBColor.** Type defined in `Shared/ColorPalette/Sources/ColorPalette/HSBColor.swift`. Round-1 panel-routed cluster (`function-duplicates-near:HSBColor.uiColor+HSBColor.nsColor`) bound to both Plant 5.1 (generic-parameterization, legitimately) and Plant 3.1 (default-implementation, incidentally). Round-2's symbol gate resolved the co-binding. See [§4.1](#41-round-1-panel-sitting-outcome-historical--do-not-update), [§4.2](#42-binding-artifact-finding-resolved-in-round-2).

### Metrics

- <a name="glossary-canonical-recall"></a>**`canonical_recall`.** Per-condition headline metric: mean across canonical plants of `max` over trials of the plant's best scored (rec × plant) pair. Defined in [methodology §8](../../docs/refactor-recommendation-experiment-methodology.md#8-scoring-rubric). Computed by [`score_all.py`](score_all.py).
- <a name="glossary-fpr"></a>**FPR (restraint false-positive rate).** Fraction of restraint plants for which any agent recommendation in a (condition, trial) cell was non-`no-action`. Defined in [methodology §9](../../docs/refactor-recommendation-experiment-methodology.md#9-restraint-and-false-positive-measurement).
- <a name="glossary-1-fpr"></a>**1−FPR.** Restraint precision complement; the per-condition headline metric on restraint plants.
- <a name="glossary-panel-route-rate"></a>**Panel-route rate.** Per condition: `panel_routed[...].count / scored[...].count`. The auto-scorer's "punt rate" — fraction of scored pairs the auto-scorer cannot definitively grade because (a) specifics fell outside the manifest's tolerance, (b) required specifics keys are missing, or (c) the agent declined the taxonomy with a novel proposal. [Methodology §8 lines 626–631](../../docs/refactor-recommendation-experiment-methodology.md#8-scoring-rubric) is the panel-routing rule.
- <a name="glossary-auto-scoring-rate"></a>**Auto-scoring rate.** `1 − panel-route rate`. [Methodology §14](../../docs/refactor-recommendation-experiment-methodology.md#14-pre-mortem-failure-modes-diagnostics-recovery) sets the acceptance bar at ≥ 50%.
- <a name="glossary-fleiss-kappa"></a>**Fleiss κ.** Inter-rater reliability statistic over N items × M raters. Appears in two granularities — [`inter_rater`](#43-inter-rater-κ--two-granularities) (rec-level, inflated by duplicates) and `inter_rater_collapsed` (judgment-level, the actionable signal). Computed by [`score_all.py::attach_panel_kappa`](score_all.py) and [`::attach_collapsed_panel_kappa`](score_all.py).

### Binding and specifics

- <a name="glossary-binding"></a>**Binding.** The process of associating each (rec × cluster) pair with a candidate plant for scoring. Implemented by [`score_all.py::bind_recs_to_plants`](score_all.py). Three rule eras:
  1. **Round-1 substring-match binding.** Loose: cluster touching one of a plant's `source_files` binds to that plant. Allowed incidental false bindings (HSBColor / Plant 3.1, DebugHUD / Plant 1R).
  2. **Round-1 closeout prefer-signal-match rule** ([PR #84](https://github.com/jakebromberg/code-audit-pipeline/pull/84)). Medium: when a cluster matches multiple plants, prefer those whose `expected_substrate_signals` include the rec's `query`. Cleaned 24 incidentals but did not resolve same-signal ambiguities.
  3. **Round-2 symbol-level binding** ([PR #89](https://github.com/jakebromberg/code-audit-pipeline/pull/89)). Tight: requires the cluster_id to contain at least one of the plant's `expected_cluster_symbols`. Closed remaining ambiguities.
- <a name="glossary-expected-cluster-symbols"></a>**`expected_cluster_symbols`.** Per-plant manifest field added in round 2. A non-empty list of literal substrings the cluster_id must contain for the binding to stand. See [`rubric-modifications.md` round-2 symbol-level-binding entry](rubric-modifications.md).
- <a name="glossary-expected-substrate-signals"></a>**`expected_substrate_signals`.** Per-plant manifest field. The pre-registered query names whose cluster outputs should surface the plant's planted shape. Used by the round-1-closeout prefer-signal-match rule.
- <a name="glossary-specifics-tolerance"></a>**`specifics_tolerance`.** Per-plant manifest field documenting *structural* properties the agent's specifics values must satisfy (e.g., `target_package_must_be_upstream_of_all_consumers=True`). The auto-scorer does NOT evaluate these flags directly per [methodology §8](../../docs/refactor-recommendation-experiment-methodology.md#8-scoring-rubric); they surface as `tolerance_flag:` notes in panel-routing payloads as guidance to human reviewers.
- <a name="glossary-value-aware-matching"></a>**Value-aware specifics matching.** Round-2 scorer change ([PR #90](https://github.com/jakebromberg/code-audit-pipeline/pull/90), closes [#35](https://github.com/jakebromberg/code-audit-pipeline/issues/35)): after key-presence check, compare each required key's value against `plant.primary_answer.specifics[key]` verbatim. Mismatches route to panel. Replaced round 1's **key-only matching** (which over-credited agents whose specifics keys aligned in shape but disagreed in content). See [§7](#7-sensitivity-to-specifics-tolerance-resolved-in-round-2), [`rubric-modifications.md` round-2 value-aware-specifics entry](rubric-modifications.md).

### Match labels (auto-scorer verdicts on each rec × plant pair)

The auto-scorer attaches one match label per scored pair, then maps to a numeric score (or `panel_route`). Labels live in [`auto-scorer.py`](auto-scorer.py) and [`score_all.py`](score_all.py).

- <a name="glossary-primary-match-full"></a>**`primary_match_full`.** All required specifics keys present + values matched verbatim. Round-1-only outcome; superseded by `primary_match_specifics_outside_tolerance` under [value-aware matching](#glossary-value-aware-matching).
- <a name="glossary-primary-match-weak-rationale"></a>**`primary_match_weak_rationale`.** Specifics matched but rationale weak. Round-1-only.
- <a name="glossary-primary-match-specifics-outside-tolerance"></a>**`primary_match_specifics_outside_tolerance`.** Category matches; specifics keys present but at least one value mismatches manifest. **Routes to panel.** The dominant round-2 / round-3 match label.
- <a name="glossary-primary-match-specifics-missing-keys"></a>**`primary_match_specifics_missing_keys`.** Required specifics key absent. **Routes to panel.**
- <a name="glossary-alternative-match"></a>**`alternative_match`.** Agent's recommendation matches one of `plant.alternative_answers` rather than `primary_answer`.
- <a name="glossary-wrong-category-enumerated"></a>**`wrong_category_enumerated`.** Agent picked a different category from the manifest's primary; that category is in the enumerated set (still scores 0.0).
- <a name="glossary-wrong-category-not-enumerated"></a>**`wrong_category_not_enumerated`.** Agent picked a category not in the enumerated set.
- <a name="glossary-adjacent-wrong-category"></a>**`adjacent_wrong_category`.** Wrong category but rubric-adjacent (e.g., extract-to-common vs generic-parameterization).
- <a name="glossary-no-action-grounded"></a>**`no_action_grounded`.** Agent declined to act with a grounded rationale (e.g., `reason_class: "sample-app-mirror"`). Scores 1.0 for restraint plants.
- <a name="glossary-no-action-ungrounded"></a>**`no_action_ungrounded`.** Agent declined with no clear rationale. Scores 0.5 for restraint plants.
- <a name="glossary-breaking-action"></a>**`breaking_action`.** Agent recommended a refactor that would break behavior. Scores −0.5.
- <a name="glossary-other-routes-to-panel"></a>**`other_routes_to_panel`.** Agent declined the taxonomy and proposed a novel action. **Routes to panel.**
- <a name="glossary-panel-promoted"></a>**`panel_promoted`.** Panel scored the row; the panel's numeric score backfilled into the headline via [`promote_panel_scores`](score_all.py).

### Rounds and phases

- <a name="glossary-round-1"></a>**Round 1.** Original Phase D + E run, 2026-04. Single-reviewer panel (3 pre-registered per [methodology §17](../../docs/refactor-recommendation-experiment-methodology.md#17-decisions-outstanding-before-kickoff)). Headline canonical_recall S1=0.270 / S2=0.615 under key-only scoring.
- <a name="glossary-round-1-closeout"></a>**Round-1 closeout.** Mid-life round-1 patch landing the prefer-signal-match binding rule and the A3 prompt edit. [`plans/v7-phase-e-round1-closeout-plan.md`](../../plans/v7-phase-e-round1-closeout-plan.md), [PR #84](https://github.com/jakebromberg/code-audit-pipeline/pull/84).
- <a name="glossary-round-2"></a>**Round 2.** 2026-05-18 / 2026-05-19. Symbol-level binding ([PR #89](https://github.com/jakebromberg/code-audit-pipeline/pull/89)), value-aware specifics matching ([PR #90](https://github.com/jakebromberg/code-audit-pipeline/pull/90)), and explicit `cluster_lens` schema field (3 entries in [`rubric-modifications.md`](rubric-modifications.md)). Headline shifted to S1=0.070 / S2=0.110.
- <a name="glossary-round-3"></a>**Round 3.** 2026-05-20. [Prompt-sensitivity sub-experiment (§10)](#10-prompt-sensitivity-sub-experiment-round-3--h0a-supported). Outcome: H0a supported.
- <a name="glossary-phase-d"></a>**Phase D.** The agent-call phase: harness runs trials against the substrate and collects parsed recs.
- <a name="glossary-phase-e"></a>**Phase E.** Scoring + writeup phase: this doc.
- <a name="glossary-pr-e2"></a>**PR-E2.** Phase-E sub-PR 2: analyses (substrate-helped check + plant-recall-extended). Referenced in [§2](#2-141-substrate-helped-check-from-pr-e2) and [§3](#3-plant-recall-confirm--plant-53-outcome-from-pr-e2).
- <a name="glossary-pr-e3"></a>**PR-E3.** Phase-E sub-PR 3: scoring + auto-scorer ([`auto-scorer.py`](auto-scorer.py), [`score_all.py`](score_all.py)).
- <a name="glossary-a3-prompt-edit"></a>**A3 prompt edit.** Round-1 closeout edit to rule 1 of the agent prompt: treats `is_test=true | is_mock=true | is_sample_app=true` on ANY participating record as load-bearing (the agent should not recommend extracting test/mock/sample-app code into shared modules). Forward-looking infrastructure; round 2's symbol gate is what actually eliminated Plant 1R's structural FPR. See [§5](#5-restraint-plants--false-positive-breakdown), [§8](#8-known-limitations).

<a name="glossary-code-references"></a>
### Code references

- [`score_all.py::bind_recs_to_plants`](score_all.py) — Maps each parsed rec to its candidate plants per the [binding](#glossary-binding) rules.
- [`score_all.py::promote_panel_scores`](score_all.py) — After panel scoring, lifts panel numeric scores back into auto-scored rows so the headline canonical_recall reflects the full auto+panel picture.
- [`score_all.py::attach_panel_kappa`](score_all.py), [`::attach_collapsed_panel_kappa`](score_all.py) — Compute [Fleiss κ](#glossary-fleiss-kappa) at rec-level and judgment-level granularity.
- [`score_all.py::score_recommendations`](score_all.py) — Drives the auto-scorer over all parsed recs, producing the `scored` and `panel_routed` arrays.
- [`auto-scorer.py`](auto-scorer.py) — Compares each rec to its bound plants and emits a [match label](#match-labels-auto-scorer-verdicts-on-each-rec--plant-pair) per pair.

### Issue and PR references

- [#5](https://github.com/jakebromberg/code-audit-pipeline/issues/5) — substrate-emitted cluster_id requirement (prerequisite for Phase D variance stability).
- [#28](https://github.com/jakebromberg/code-audit-pipeline/issues/28) — cross-lens cluster sharing; closed by round-2 `cluster_lens` schema.
- [#33](https://github.com/jakebromberg/code-audit-pipeline/issues/33) — `cluster_lens` schema field; closed by round-2.
- [#35](https://github.com/jakebromberg/code-audit-pipeline/issues/35) — auto-scorer key-only matching deferral; closed by round-2 [value-aware specifics matching](#glossary-value-aware-matching).
- [#66](https://github.com/jakebromberg/code-audit-pipeline/issues/66) — Sonnet 4.6 alias not date-pinned; motivates [round-3's drift-check (§10.2)](#102-drift-check).
- [#77](https://github.com/jakebromberg/code-audit-pipeline/issues/77) — Phase E sub-experiments tracker; round-3 closed trigger #2.
- [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) — round-2 reviewer recruitment (open).
- [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94) — round-2 finalization (open).
- [PR #84](https://github.com/jakebromberg/code-audit-pipeline/pull/84) — round-1 closeout.
- [PR #89](https://github.com/jakebromberg/code-audit-pipeline/pull/89) — round-2 symbol-level binding.
- [PR #90](https://github.com/jakebromberg/code-audit-pipeline/pull/90) — round-2 value-aware specifics matching.
- [PR #99](https://github.com/jakebromberg/code-audit-pipeline/pull/99), [#100](https://github.com/jakebromberg/code-audit-pipeline/pull/100), [#102](https://github.com/jakebromberg/code-audit-pipeline/pull/102), [#103](https://github.com/jakebromberg/code-audit-pipeline/pull/103) — round-3 PRs 1–4.

## See also

- [`analyses/substrate-helped.json`](analyses/substrate-helped.json), [`analyses/plant-recall-extended.json`](analyses/plant-recall-extended.json) — PR-E2 outputs that this writeup quotes
- [`analyses/auto-scores.json`](analyses/auto-scores.json), [`analyses/score-summary.json`](analyses/score-summary.json), [`analyses/panel-routing.jsonl`](analyses/panel-routing.jsonl) — PR-E3 outputs
- [`analyses-v1-clean/`](analyses-v1-clean/) — round-3 v1 re-control arm against the regenerated substrate ([PR #102](https://github.com/jakebromberg/code-audit-pipeline/pull/102))
- [`analyses-v2/`](analyses-v2/) — round-3 v2 experimental arm; `prompt-sensitivity.json` carries the formal v1-vs-v2 delta matrix; `drift-check.json` carries the pre-rerun alias-stability sample ([PR #100](https://github.com/jakebromberg/code-audit-pipeline/pull/100) + [PR #102](https://github.com/jakebromberg/code-audit-pipeline/pull/102))
- [`analyses/panel-instructions.md`](analyses/panel-instructions.md) — review-panel instructions
- [`reproducibility.yaml`](reproducibility.yaml) — pinned inputs + execution stamps
- [`docs/refactor-recommendation-experiment-methodology.md`](../../docs/refactor-recommendation-experiment-methodology.md) — methodology
- [`plans/v7-phase-e-scoring-and-writeup-plan.md`](../../plans/v7-phase-e-scoring-and-writeup-plan.md) — Phase E plan
- [`plans/v7-round2-prompt-sensitivity-plan.md`](../../plans/v7-round2-prompt-sensitivity-plan.md) — round-3 prompt-sensitivity sub-experiment plan
