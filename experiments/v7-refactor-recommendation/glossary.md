# V7 refactor-recommendation experiment — glossary

Cross-cutting reference for the V7 refactor-recommendation experiment's vocabulary. Linked from [`results.md`](results.md), [`rubric-modifications.md`](rubric-modifications.md), [`analyses/panel-instructions.md`](analyses/panel-instructions.md), and the [methodology](../../docs/refactor-recommendation-experiment-methodology.md). Terms that have a canonical defining source elsewhere link to it rather than redefining; entries below define the cross-cutting concepts that don't have a single home doc.

Anchor convention: every entry has an explicit `<a name="glossary-X"></a>` anchor; link to a specific term with `glossary.md#glossary-canonical-recall` etc.

## Conditions and substrate

- <a name="glossary-s1"></a>**S1.** "Cold" condition: agent runs against the V6 substrate. Pre-V7 query set; no `pat-candidates`, `protocol-inheritance-candidates`, `default-impl-candidates`, `generic-struct-candidates`, or `generic-function-candidates`. See [methodology §11](../../docs/refactor-recommendation-experiment-methodology.md#11-conditions-to-compare).
- <a name="glossary-s2"></a>**S2.** "Warm" condition: agent runs against the V7 substrate (V6 plus the five new queries above). The full V7 substrate is detailed in [methodology §6.8](../../docs/refactor-recommendation-experiment-methodology.md#68-new-queries-that-consume-the-new-substrate).
- <a name="glossary-substrate"></a>**Substrate.** The structured catalog of "shape signals" the agent reads: pairs and clusters emitted by static-analysis queries over the source tree. V6 is the round-1 baseline; V7 is the current generation. The substrate is **not** the source files themselves; it's the queries' output.
- <a name="glossary-cluster"></a>**Cluster.** A single row emitted by one substrate query. Each `cluster_id` encodes the query name + the participating source records (file paths, types, function names). Clusters are what the agent reads; recommendations are produced one-per-cluster.
- <a name="glossary-rec"></a>**Rec.** A single agent recommendation: one `(category, rationale, specifics, evidence)` tuple per cluster. Parsed from the agent's JSON output.
- <a name="glossary-trial"></a>**Trial.** A single agent run over the full corpus under one condition. Round 1, round 2, and round 3 each use 3 trials per condition (S1, S2) for variance estimation.

## Plants

Full manifest in [`plant-manifest.yaml`](plant-manifest.yaml). 25 plants total; 20 canonical + 5 restraint.

- <a name="glossary-canonical-plant"></a>**Canonical plant.** A planted refactor opportunity the agent SHOULD identify. Contributes to [canonical_recall](#glossary-canonical-recall). Carries IDs like Plant 1.1, 3.2, 5.4. Categories 1–5 correspond to the methodology's [extract-to-common](../../docs/refactor-recommendation-experiment-methodology.md#51-category-1--extract-to-common), [protocol-inheritance](../../docs/refactor-recommendation-experiment-methodology.md#52-category-2--protocol-inheritance), [default-implementation](../../docs/refactor-recommendation-experiment-methodology.md#53-category-3--default-implementation), [PAT-introduction](../../docs/refactor-recommendation-experiment-methodology.md#54-category-4--pat-introduction), and [generic-parameterization](../../docs/refactor-recommendation-experiment-methodology.md#55-category-5--generic-parameterization-struct-or-function) categories respectively.
- <a name="glossary-restraint-plant"></a>**Restraint plant.** A planted *non*-refactor — code that looks like a refactor opportunity but isn't (test mocks, sample-app patterns, etc.) where the agent SHOULD output `no-action`. Carry IDs Plant 1R, 2R, 3R, 4R, 5R (one per category). Contribute to [FPR](#glossary-fpr) / [1−FPR](#glossary-1-fpr). Defined in [methodology §9](../../docs/refactor-recommendation-experiment-methodology.md#9-restraint-and-false-positive-measurement).
- <a name="glossary-plant-1r"></a>**Plant 1R.** Extract-to-common restraint. Source files include `DebugHUD.swift`; planted shape is `MetricRow`-style debug UI on the WatchXYC sample app. Agent should decline with `reason_class: "sample-app-mirror"`. Round-1 carried a structural FPR (16 unrelated `DebugMetricsProvider` clusters in `DebugHUD.swift` incidentally bound to Plant 1R via substring-match) that round-2's `expected_cluster_symbols: ["MetricRow"]` gate eliminated. See [results.md §4.2](results.md#42-binding-artifact-finding-resolved-in-round-2), [results.md §5](results.md#5-restraint-plants--false-positive-breakdown), [`rubric-modifications.md` round-2 symbol-level-binding entry](rubric-modifications.md).
- <a name="glossary-debughud"></a>**DebugHUD.swift.** Plant 1R's source file. Several unrelated clusters from this file (e.g., the `DebugMetricsProvider` cluster) substring-match Plant 1R but don't surface its planted `MetricRow` symbol; the round-2 symbol gate blocks the incidental bindings.
- <a name="glossary-hsbcolor"></a>**HSBColor.** Type defined in `Shared/ColorPalette/Sources/ColorPalette/HSBColor.swift`. Round-1 panel-routed cluster (`function-duplicates-near:HSBColor.uiColor+HSBColor.nsColor`) bound to both Plant 5.1 (generic-parameterization, legitimately) and Plant 3.1 (default-implementation, incidentally). Round-2's symbol gate resolved the co-binding. See [results.md §4.1](results.md#41-round-1-panel-sitting-outcome-historical--do-not-update), [results.md §4.2](results.md#42-binding-artifact-finding-resolved-in-round-2).

## Metrics

- <a name="glossary-canonical-recall"></a>**`canonical_recall`.** Per-condition headline metric: mean across canonical plants of `max` over trials of the plant's best scored (rec × plant) pair. Defined in [methodology §8](../../docs/refactor-recommendation-experiment-methodology.md#8-scoring-rubric). Computed by [`score_all.py`](score_all.py).
- <a name="glossary-fpr"></a>**FPR (restraint false-positive rate).** Fraction of restraint plants for which any agent recommendation in a (condition, trial) cell was non-`no-action`. Defined in [methodology §9](../../docs/refactor-recommendation-experiment-methodology.md#9-restraint-and-false-positive-measurement).
- <a name="glossary-1-fpr"></a>**1−FPR.** Restraint precision complement; the per-condition headline metric on restraint plants.
- <a name="glossary-panel-route-rate"></a>**Panel-route rate.** Per condition: `panel_routed[...].count / scored[...].count`. The auto-scorer's "punt rate" — fraction of scored pairs the auto-scorer cannot definitively grade because (a) specifics fell outside the manifest's tolerance, (b) required specifics keys are missing, or (c) the agent declined the taxonomy with a novel proposal. [Methodology §8 lines 626–631](../../docs/refactor-recommendation-experiment-methodology.md#8-scoring-rubric) is the panel-routing rule.
- <a name="glossary-auto-scoring-rate"></a>**Auto-scoring rate.** `1 − panel-route rate`. [Methodology §14](../../docs/refactor-recommendation-experiment-methodology.md#14-pre-mortem-failure-modes-diagnostics-recovery) sets the acceptance bar at ≥ 50%.
- <a name="glossary-fleiss-kappa"></a>**Fleiss κ.** Inter-rater reliability statistic over N items × M raters. Appears in two granularities — [`inter_rater`](results.md#43-inter-rater-κ--two-granularities) (rec-level, inflated by duplicates) and `inter_rater_collapsed` (judgment-level, the actionable signal). Computed by [`score_all.py::attach_panel_kappa`](score_all.py) and [`::attach_collapsed_panel_kappa`](score_all.py).

## Binding and specifics

- <a name="glossary-binding"></a>**Binding.** The process of associating each (rec × cluster) pair with a candidate plant for scoring. Implemented by [`score_all.py::bind_recs_to_plants`](score_all.py). Three rule eras:
  1. **Round-1 substring-match binding.** Loose: cluster touching one of a plant's `source_files` binds to that plant. Allowed incidental false bindings (HSBColor / Plant 3.1, DebugHUD / Plant 1R).
  2. **Round-1 closeout prefer-signal-match rule** ([PR #84](https://github.com/jakebromberg/code-audit-pipeline/pull/84)). Medium: when a cluster matches multiple plants, prefer those whose `expected_substrate_signals` include the rec's `query`. Cleaned 24 incidentals but did not resolve same-signal ambiguities.
  3. **Round-2 symbol-level binding** ([PR #89](https://github.com/jakebromberg/code-audit-pipeline/pull/89)). Tight: requires the cluster_id to contain at least one of the plant's `expected_cluster_symbols`. Closed remaining ambiguities.
- <a name="glossary-expected-cluster-symbols"></a>**`expected_cluster_symbols`.** Per-plant manifest field added in round 2. A non-empty list of literal substrings the cluster_id must contain for the binding to stand. See [`rubric-modifications.md` round-2 symbol-level-binding entry](rubric-modifications.md).
- <a name="glossary-expected-substrate-signals"></a>**`expected_substrate_signals`.** Per-plant manifest field. The pre-registered query names whose cluster outputs should surface the plant's planted shape. Used by the round-1-closeout prefer-signal-match rule.
- <a name="glossary-specifics-tolerance"></a>**`specifics_tolerance`.** Per-plant manifest field documenting *structural* properties the agent's specifics values must satisfy (e.g., `target_package_must_be_upstream_of_all_consumers=True`). The auto-scorer does NOT evaluate these flags directly per [methodology §8](../../docs/refactor-recommendation-experiment-methodology.md#8-scoring-rubric); they surface as `tolerance_flag:` notes in panel-routing payloads as guidance to human reviewers.
- <a name="glossary-value-aware-matching"></a>**Value-aware specifics matching.** Round-2 scorer change ([PR #90](https://github.com/jakebromberg/code-audit-pipeline/pull/90), closes [#35](https://github.com/jakebromberg/code-audit-pipeline/issues/35)): after key-presence check, compare each required key's value against `plant.primary_answer.specifics[key]` verbatim. Mismatches route to panel. Replaced round 1's **key-only matching** (which over-credited agents whose specifics keys aligned in shape but disagreed in content). See [results.md §7](results.md#7-sensitivity-to-specifics-tolerance-resolved-in-round-2), [`rubric-modifications.md` round-2 value-aware-specifics entry](rubric-modifications.md).

## Match labels (auto-scorer verdicts on each rec × plant pair)

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

## Rounds and phases

- <a name="glossary-round-1"></a>**Round 1.** Original Phase D + E run, 2026-04. Single-reviewer panel (3 pre-registered per [methodology §17](../../docs/refactor-recommendation-experiment-methodology.md#17-decisions-outstanding-before-kickoff)). Headline canonical_recall S1=0.270 / S2=0.615 under key-only scoring.
- <a name="glossary-round-1-closeout"></a>**Round-1 closeout.** Mid-life round-1 patch landing the prefer-signal-match binding rule and the A3 prompt edit. [`plans/v7-phase-e-round1-closeout-plan.md`](../../plans/v7-phase-e-round1-closeout-plan.md), [PR #84](https://github.com/jakebromberg/code-audit-pipeline/pull/84).
- <a name="glossary-round-2"></a>**Round 2.** 2026-05-18 / 2026-05-19. Symbol-level binding ([PR #89](https://github.com/jakebromberg/code-audit-pipeline/pull/89)), value-aware specifics matching ([PR #90](https://github.com/jakebromberg/code-audit-pipeline/pull/90)), and explicit `cluster_lens` schema field (3 entries in [`rubric-modifications.md`](rubric-modifications.md)). Headline shifted to S1=0.070 / S2=0.110.
- <a name="glossary-round-3"></a>**Round 3.** 2026-05-20. [Prompt-sensitivity sub-experiment (results.md §10)](results.md#10-prompt-sensitivity-sub-experiment-round-3--h0a-supported). Outcome: H0a supported.
- <a name="glossary-phase-d"></a>**Phase D.** The agent-call phase: harness runs trials against the substrate and collects parsed recs.
- <a name="glossary-phase-e"></a>**Phase E.** Scoring + writeup phase; output lives in [`results.md`](results.md).
- <a name="glossary-pr-e2"></a>**PR-E2.** Phase-E sub-PR 2: analyses (substrate-helped check + plant-recall-extended). Referenced in [results.md §2](results.md#2-141-substrate-helped-check-from-pr-e2) and [results.md §3](results.md#3-plant-recall-confirm--plant-53-outcome-from-pr-e2).
- <a name="glossary-pr-e3"></a>**PR-E3.** Phase-E sub-PR 3: scoring + auto-scorer ([`auto-scorer.py`](auto-scorer.py), [`score_all.py`](score_all.py)).
- <a name="glossary-a3-prompt-edit"></a>**A3 prompt edit.** Round-1 closeout edit to rule 1 of the agent prompt: treats `is_test=true | is_mock=true | is_sample_app=true` on ANY participating record as load-bearing (the agent should not recommend extracting test/mock/sample-app code into shared modules). Forward-looking infrastructure; round 2's symbol gate is what actually eliminated Plant 1R's structural FPR. See [results.md §5](results.md#5-restraint-plants--false-positive-breakdown), [results.md §8](results.md#8-known-limitations).

<a name="glossary-code-references"></a>
## Code references

- [`score_all.py::bind_recs_to_plants`](score_all.py) — Maps each parsed rec to its candidate plants per the [binding](#glossary-binding) rules.
- [`score_all.py::promote_panel_scores`](score_all.py) — After panel scoring, lifts panel numeric scores back into auto-scored rows so the headline canonical_recall reflects the full auto+panel picture.
- [`score_all.py::attach_panel_kappa`](score_all.py), [`::attach_collapsed_panel_kappa`](score_all.py) — Compute [Fleiss κ](#glossary-fleiss-kappa) at rec-level and judgment-level granularity.
- [`score_all.py::score_recommendations`](score_all.py) — Drives the auto-scorer over all parsed recs, producing the `scored` and `panel_routed` arrays.
- [`auto-scorer.py`](auto-scorer.py) — Compares each rec to its bound plants and emits a [match label](#match-labels-auto-scorer-verdicts-on-each-rec--plant-pair) per pair.

## Issue and PR references

- [#5](https://github.com/jakebromberg/code-audit-pipeline/issues/5) — substrate-emitted cluster_id requirement (prerequisite for Phase D variance stability).
- [#28](https://github.com/jakebromberg/code-audit-pipeline/issues/28) — cross-lens cluster sharing; closed by round-2 `cluster_lens` schema.
- [#33](https://github.com/jakebromberg/code-audit-pipeline/issues/33) — `cluster_lens` schema field; closed by round-2.
- [#35](https://github.com/jakebromberg/code-audit-pipeline/issues/35) — auto-scorer key-only matching deferral; closed by round-2 [value-aware specifics matching](#glossary-value-aware-matching).
- [#66](https://github.com/jakebromberg/code-audit-pipeline/issues/66) — Sonnet 4.6 alias not date-pinned; motivates [round-3's drift-check (results.md §10.2)](results.md#102-drift-check).
- [#77](https://github.com/jakebromberg/code-audit-pipeline/issues/77) — Phase E sub-experiments tracker; round-3 closed trigger #2.
- [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) — round-2 reviewer recruitment (open).
- [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94) — round-2 finalization (open).
- [PR #84](https://github.com/jakebromberg/code-audit-pipeline/pull/84) — round-1 closeout.
- [PR #89](https://github.com/jakebromberg/code-audit-pipeline/pull/89) — round-2 symbol-level binding.
- [PR #90](https://github.com/jakebromberg/code-audit-pipeline/pull/90) — round-2 value-aware specifics matching.
- [PR #99](https://github.com/jakebromberg/code-audit-pipeline/pull/99), [#100](https://github.com/jakebromberg/code-audit-pipeline/pull/100), [#102](https://github.com/jakebromberg/code-audit-pipeline/pull/102), [#103](https://github.com/jakebromberg/code-audit-pipeline/pull/103) — round-3 PRs 1–4.

## See also

- [`results.md`](results.md) — the experiment writeup that consumes these terms (round-1 results + round-2/3 corrections).
- [`rubric-modifications.md`](rubric-modifications.md) — chronological log of rubric / manifest / scorer changes per [methodology §10](../../docs/refactor-recommendation-experiment-methodology.md#10-pre-registration-discipline).
- [`analyses/panel-instructions.md`](analyses/panel-instructions.md) — review-panel instructions.
- [`docs/refactor-recommendation-experiment-methodology.md`](../../docs/refactor-recommendation-experiment-methodology.md) — methodology (canonical definitions for `canonical_recall`, restraint plants, scoring rubric, categories).
- [`plant-manifest.yaml`](plant-manifest.yaml) — full plant catalog with `expected_cluster_symbols`, `expected_substrate_signals`, `specifics_tolerance`.
