# V7 rubric modifications

A running log of post-hoc edits to the manifest, rubric, or scoring rules per methodology §10. Each entry: **Change**, **Why**, **Expected impact**, **Prior results affected**. Future rounds append entries in chronological order; do not modify earlier entries.

## Round 2 — symbol-level binding (2026-05-18)

**Change.** Added `expected_cluster_symbols` field per plant in `plant-manifest.yaml`. Non-empty list of literal substrings the cluster_id must contain for a binding to be valid. The validator (`validate-manifest.py` rule 9j) requires non-empty lists of non-empty strings. The binding rule (`score_all.py::bind_recs_to_plants`) adds a hard symbol gate between substring-match and signal-prefer.

**Why.** Round-1 closeout (PR #84) added a prefer-signal-match rule that cleaned 24 incidental false bindings but didn't fix two known gaps documented in [`results.md`](results.md) §4.2 and §8: the panel-routed Plant 3.1 / 5.1 co-binding on HSBColor (both plants share `function-duplicates` in signals AND `HSBColor.swift` in source_files), and Plant 1R's structural FPR (16 incidental `DebugMetricsProvider` clusters substring-match `DebugHUD.swift`). Both gaps converge on (path, query)-granularity ambiguity; symbol-level matching disambiguates.

**Expected vs actual impact.**

| Metric | Plan §3.4 projection | Actual |
|---|---|---|
| `panel_routed.size` | 12 → 6 | **12 → 6** ✓ |
| Plant 3.1 panel routings dropped | 6 → 0 | **6 → 0** ✓ |
| Plant 5.1 panel routings preserved | 6 → 6 | **6 → 6** ✓ |
| Plant 1R per-cell FPR | 1.0 → 0.0 in all 6 cells | **1.0 → 0.0 in all 6 cells** ✓ |
| Headline 1−FPR (S1, S2) | 0.800 → 1.000 | **0.800 → 1.000** ✓ |
| `canonical_recall` (S1, S2) | unchanged 0.270 / 0.615 | **unchanged 0.270 / 0.615** ✓ |
| Plant 1R binding count | 99 → ~2 | **99 → 30** ⚠ |
| Plant 1.4 binding count | stays 0 | **stays 0** ✓ |

The Plant 1R binding-count delta is the only deviation from the plan: 30 bindings instead of ~2. The plan's estimate assumed Plant 1R's symbol `"MetricRow"` would only match the two canonical MetricRow clusters. In practice the substring "MetricRow" appears in many DebugHUD.swift clusters (`MetricRow.body`, `MetricRow.init`, subset-pair clusters that mention MetricRow alongside other types, etc.) — all of which are legitimately about Plant 1R's planted shape. All 30 received `no-action` from the agent, so Plant 1R's FPR contribution is 0 across all cells. The methodological outcome holds; the cardinality just differs from the estimate. Tightening to `"MetricRow.body"` would drop the count but doesn't add methodological value because the broader symbol already produces the correct FPR. Plan §3.4's projection arithmetic stands corrected by this entry.

Symbol-enumeration audit (`plans/v7-round2-symbol-matching-plan.md` §5 step 7) ran clean: 0 WARN lines. INFO lines for Plant 1.4 (expected — 0 bindings) and for three plants with over-specified symbols that don't yet appear in any current cluster (Plant 1.2 `WhatsPlayingOnWXYC`, Plant 2R `_Plant_MockAsyncNotificationMessage`, Plant 3.4 `_Plant_Announcement.init`). These are defense-in-depth for future cluster shapes — acceptable.

**Prior results affected.** Round 1's panel scores in `panel-scores-reviewer-1.jsonl` no longer fully map to the new `panel-routing.jsonl` — the 6 Plant 3.1 rows become orphan tokens. `promote_panel_scores` silently skips them (no token match → `continue`; only successfully-promoted entries receive a panel-promotion note). Both `attach_panel_kappa` and `attach_collapsed_panel_kappa` filter orphan tokens against the in-memory `panel_routed` list and surface the orphan count in their respective notes (`score-summary.json::inter_rater.note` and `::inter_rater_collapsed.note`). Filtering matters because Fleiss κ requires every item to be rated by exactly m raters; counting orphans would leave them with only the round-1 reviewer's score (m=1) once round-2 reviewers land, silently mis-computing κ. The 6 Plant 5.1 panel scores still promote correctly. The headline canonical_recall is unchanged because Plant 5.1's panel-promoted scores still flow through.

The headline 1−FPR jump (0.800 → 1.000) is the methodologically biggest round-2 result. The result is real but should be interpreted as "binding-attribution correctness" rather than "agent behavior improvement" — the agent's behavior on Plant 1R's canonical MetricRow clusters was already correct under round 1's prompt; the round-1 closeout's A3 prompt edit (PR #84) is forward-looking methodology infrastructure whose measurable effect would only land if a future restraint plant produces clusters the symbol gate doesn't reach.

## Round 2 — value-aware specifics matching (2026-05-19)

**Change.** Added verbatim value comparison to the auto-scorer's primary-match path in `auto-scorer.py::score_recommendation()`. After `_specifics_keys_match` confirms all required keys are present, a new `_specifics_values_match` helper compares each required key's value against `plant.primary_answer.specifics[key]` (scalars by `==`; lists as multisets; dicts structurally). Value mismatches route to panel with the new match label `primary_match_specifics_outside_tolerance`. Missing required keys (previously auto-scored 0.5 as `primary_category_wrong_specifics`) now also route to panel as `primary_match_specifics_missing_keys` — methodology §8 lines 626–631 treats "specifics fall outside tolerance" as the panel-routing condition, and missing required keys are the most outside-tolerance case. A new `_tolerance_flag_notes(plant)` helper surfaces the plant's `specifics_tolerance` flags as `tolerance_flag: {key}={value}` notes in the panel-routing payload, so panel reviewers see the manifest's pre-registered tolerance guidance inline without cross-referencing.

**Why.** The auto-scorer's MVP key-only matching was an explicit deferral in the original PR #31 review (`auto-scorer.py` docstring §39–49 pre-this-change). Methodology §8's panel-routing rule (lines 626–631) is clear: "category matches `primary_answer.category` but specifics fall outside tolerance → panel-route." The previous scorer fired 1.0 (or 0.5-weak) on key-only matches, silently bypassing the §8 routing for value mismatches and over-crediting agents whose specifics aligned in shape but disagreed in content. After re-reading §8, the auto-scorer is not supposed to evaluate the 29 stringly-typed `specifics_tolerance` flags structurally — that's the panel's job. The scorer's role per §8 is binary tolerance detection (verbatim match vs not), with the flags as panel guidance. This sidesteps issue #35's open design questions about flag schema (option (a) per-flag handlers / option (b) structured rules) entirely.

**Expected vs actual impact.**

| Metric | Plan §3.3 projection | Actual |
|---|---|---|
| `(primary_match_full ∪ primary_match_weak_rationale)` pool size | 37 + 65 = 102 | 102 ✓ |
| Total flip rate from pool | 100% (every row has ≥1 mismatch) | 100% ✓ |
| Substantive mismatch share | ~95% | 95.1% (97/102) ✓ |
| Trivial mismatch share | ~5% (parenthetical commentary on Plant 3.4) | 4.9% (5/102) ✓ |
| Gate decision (trivial < 30%) | PROCEED | PROCEED ✓ |
| `panel_routed.size` | 6 → ~108 | 6 → 108 ✓ |
| `primary_match_full` count | 37 → 0 | 37 → 0 ✓ |
| `primary_match_weak_rationale` count | 65 → 0 | 65 → 0 ✓ |
| `headline.canonical_recall` S1 | 0.270 → ~0.05 | 0.270 → 0.070 ✓ |
| `headline.canonical_recall` S2 | 0.615 → ~0.10 | 0.615 → 0.110 ✓ |
| `headline.one_minus_fpr` (both conditions) | 1.000 → 1.000 (unchanged) | 1.000 → 1.000 ✓ |

The headline recall drop (S2 0.615 → 0.110, 5.6× smaller) is the methodologically biggest round-2 result on the recall side, paralleling round-2's biggest result on the precision side (1−FPR jump from PR #89 / symbol-level binding). Both are correction artifacts, not regressions: round 1's headline canonical_recall was inflated by key-only matching, the same way round 1's 1−FPR was deflated by binding-attribution ambiguity. The corrected numbers represent the auto-scorer's true precision-and-recall picture absent panel sitting. The panel-routed 108 rows are awaiting recruitment of 2 additional reviewers per [`#85`](https://github.com/jakebromberg/code-audit-pipeline/issues/85); once panel scores land, `promote_panel_scores` will route the rated rows back into the canonical-recall numerator, lifting the headline number into the auto-plus-panel range.

**Per-plant flip distribution (most-flipped first):**

| Plant | Pre-flip pool | Flipped | Mismatch class |
|---|---|---|---|
| 1.1 | 15 | 15 | substantive (target_package, type_name) |
| 3.4 | 15 | 15 | 10 substantive + 5 trivial (parenthetical) |
| 3.3 | 14 | 14 | substantive (agent invented `NormalizationModeConfigurable` instead of using `AudioProcessor`) |
| 3.2 | 12 | 12 | substantive (agent invented `BlendModeConvertible` instead of `BlendMode`) |
| 5.2 | 9 | 9 | substantive (agent left `type_params.constraint: null` where manifest expects `"Decodable"`) |
| 2.3, 2.4 | 6 each | 6 each | substantive |
| 2.1, 2.2, 4.2, 4.3, 4.4, 5.3, 5.4 | 3 each | 3 each | substantive |
| 3.1, 4.1 | 2 each | 2 each | substantive |

**Prior results affected.** Round-1 closeout (PR #84) and PR #89 reported canonical_recall S1=0.270 / S2=0.615; those numbers were correct under round-1's MVP key-only scoring but over-credited agents on value-level mismatches. This entry's `analyses/score-summary.json` regeneration carries the corrected numbers (S1=0.070, S2=0.110). The `results.md` writeup carries side-by-side comparison framed as "round-1 over-credit corrected via §8 routing operationalization." The pre-2026-05-19 `auto-scores.json` and `score-summary.json` snapshots committed in PR #89's merge are the round-2 binding-correctness checkpoint; this commit's snapshots are the round-2 scoring-correctness checkpoint. No future round needs to re-run the round-1 closeout to recover the legacy numbers — the rubric-modifications log here plus the `manifest_hash` / scorer-rev pinning in `reproducibility.yaml` makes the round-1 reconstruction reproducible.

The 102 panel-routed rows carry per-row `tolerance_flag:` notes corresponding to the manifest's `specifics_tolerance` entries for each bound plant. Plant 1.1's panel-routing rows, for example, surface `tolerance_flag: target_package_must_be_upstream_of_all_consumers=True` and `tolerance_flag: target_must_be_upstream_of_both_layers=True` — the panel reviewer reads these alongside the mismatch description (`key='target_package' manifest='Shared/UI or a new Shared/Branding (must be upstream of both app:WatchXYC and app:iOS)' rec='app:iOS'`) and rates whether the agent's chosen target satisfies the upstream-of property. The scorer does not evaluate the property; the panel does.
