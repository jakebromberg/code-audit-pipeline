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

**Prior results affected.** Round 1's panel scores in `panel-scores-reviewer-1.jsonl` no longer fully map to the new `panel-routing.jsonl` — the 6 Plant 3.1 rows become orphan tokens. `promote_panel_scores` silently skips them (no token match → `continue`; only successfully-promoted entries receive a panel-promotion note). `attach_collapsed_panel_kappa` separately tracks orphan tokens in its `note_parts` diagnostic so the orphan count surfaces in `score-summary.json::inter_rater_collapsed.note` when reviewers land. The 6 Plant 5.1 panel scores still promote correctly. The headline canonical_recall is unchanged because Plant 5.1's panel-promoted scores still flow through.

The headline 1−FPR jump (0.800 → 1.000) is the methodologically biggest round-2 result. The result is real but should be interpreted as "binding-attribution correctness" rather than "agent behavior improvement" — the agent's behavior on Plant 1R's canonical MetricRow clusters was already correct under round 1's prompt; the round-1 closeout's A3 prompt edit (PR #84) is forward-looking methodology infrastructure whose measurable effect would only land if a future restraint plant produces clusters the symbol gate doesn't reach.
