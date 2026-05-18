# V7 Phase E — Round-1 Closeout (A2 + A3) Plan

> Successor to [`v7-phase-e-scoring-and-writeup-plan.md`](v7-phase-e-scoring-and-writeup-plan.md). That plan delivered [PR #82](https://github.com/jakebromberg/code-audit-pipeline/pull/82) (auto-scorer + panel-promotion + results.md). This plan closes the round-1 gaps surfaced by the panel sitting and the results-doc review: false bindings from cluster-id substring matching (A2), and Plant 1R's false positive from a not-quite-load-bearing restraint rule in the agent prompt (A3). A1 (recruit 2 more reviewers) ships as a tracking issue rather than code in this plan.

## 1. Context and motivation

Round 1 [results.md](../experiments/v7-refactor-recommendation/results.md) §4 surfaced two issues the panel sitting made concrete:

- **§4.2 binding-artifact finding.** Of the 12 panel-routed pairs, 6 were Plant 3.1 ↔ clusters whose `query` field was not in Plant 3.1's `expected_substrate_signals` list. The substring match on `source_files` in `bind_recs_to_plants` happily binds a Plant 3.1 source path (`HSBColor.swift`) to any cluster_id containing that substring — including clusters surfaced by queries (e.g., `pat-candidates`) that aren't in Plant 3.1's signal list. These are false bindings: the rec wasn't *about* Plant 3.1's shape, it just happened to mention a file Plant 3.1 owns. Plant 5.1 was the true binding for those clusters.
- **§4.1 Plant 1R FPR = 0.20 in both conditions.** Plant 1R is the restraint twin for Category 1 (extract-to-common), distinguished by `restraint_signal: "is_sample_app=true on the WallpaperSampleApp copy"`. In every Phase D trial the agent recommended `extract-to-common` on the Plant 1R pair, citing `is_sample_app=true` in its rationale but not letting the flag block the action. Single source of round-1 FPR across both S1 and S2.

Both have small fixes (~tens of lines plus a targeted prompt edit). Bundling them in one PR is appropriate because both are corrections to round-1 artifacts that get re-exercised by the round-2 Phase D re-run together; splitting yields two near-trivial PRs with the same review surface.

**Out of scope here:** A1 (recruit 2 more panel reviewers) is a human-time task; it ships as a tracking GitHub issue this plan creates after merge. B-series and C-series items (issue #35 value-aware specifics, plants 1.4/5.4 placement, E4 sub-experiments per issue #77) are round-2 scope and not addressed here.

## 2. Scope

In one PR against `experiment/swift-substrate`:

- **A2.** Add a signal-list gate to `bind_recs_to_plants` in [`score_all.py`](../experiments/v7-refactor-recommendation/score_all.py): a rec only binds to a plant if both (a) one of the plant's `source_files` is a substring of the rec's `cluster_id` (status quo), AND (b) the rec's `query` is in the plant's `expected_substrate_signals` list.
- **A3.** Tighten rule 1 of the agent prompt at [`docs/refactor-recommendation-experiment-agent-prompt.md`](../docs/refactor-recommendation-experiment-agent-prompt.md) §1 so a `is_test=true | is_mock=true | is_sample_app=true` flag on *any* participating record is a load-bearing no-action signal — not contingent on *all* participating records carrying the flag.
- **Regenerate analyses/ artifacts** with the tightened harness so the round-1 numbers in `results.md` reflect the corrected bindings. (Plant 1R's prompt change does not get a full Phase D re-run in this PR — only a small targeted re-run against Plant 1R's two clusters, gated under §5.3 below.)
- **Update `results.md` §4 and §8** to record the corrected numbers and remove the binding-artifact caveat from §8 known limitations.
- **Update `reproducibility.yaml`** to bump `prompt_hash` (the manifest is unchanged, the catalogs are unchanged — only the prompt is). Add a `round1_correction` block under `execution.panel_composition` mirroring the existing `round1_deviation` block. Template:

```yaml
panel_composition:
  # ... existing fields, unchanged ...
  round1_deviation:
    # ... existing block, unchanged ...
  round1_correction:
    description: |
      After PR #82 merged, two round-1 artifacts were corrected in a
      follow-up PR: (A2) `bind_recs_to_plants` was tightened to gate on
      `expected_substrate_signals`, eliminating 6 false Plant 3.1 ↔ HSBColor
      bindings; (A3) the agent prompt's restraint rule was tightened so a
      `is_sample_app=true` flag on any participating record is a load-bearing
      no-action signal, eliminating Plant 1R's 1/5 FPR across both conditions.
    consequence: |
      `analyses/scored.json`, `analyses/scored-aggregate.json`,
      `analyses/panel-routing.jsonl`, and `analyses/panel-unblind.json` were
      regenerated against the tightened harness. The headline numbers in
      `results.md` reflect the corrected bindings + Plant 1R re-run results;
      raw round-1 trial responses for non-Plant-1R clusters are unchanged
      (the existing `prompt_hash` for those is preserved alongside the new
      `prompt_hash` covering the round-1 correction prompt).
    targeted_rerun:
      plant_id: "1R"
      n_invocations: 10        # 5 trial-condition cells × 2 cluster rows
      cost_usd: ~2.00
      logs_at: trial-logs/round1-correction-plant-1R/
```

The `prompt_hash` field at the file top-level gets updated; consider whether to also record the pre-correction `prompt_hash` as `prompt_hash_pre_correction` so the original round-1 trial logs remain hash-pinned to their authentic prompt.

Separately, after merge, file a GitHub issue tracking A1 (recruit 2 more reviewers) per §6.

## 3. A2 design — binding-artifact filter

### 3.1 The current bug

[`score_all.py:120-141`](../experiments/v7-refactor-recommendation/score_all.py):

```python
def bind_recs_to_plants(parsed_records, plants):
    for rec in parsed_records:
        cluster_id = rec.get("cluster_id") or ""
        matched = []
        for plant in plants:
            for path in plant.get("source_files") or []:
                if path and path in cluster_id:
                    matched.append(plant["plant_id"])
                    break
        bindings.append((rec, sorted(matched)))
```

A `cluster_id` like `pat-candidates::Shared/Color/Sources/Color/HSBColor.swift::42` will bind to Plant 3.1 because Plant 3.1's source_files include `HSBColor.swift`. But the `pat-candidates` query is not in Plant 3.1's `expected_substrate_signals` list (`function-duplicates`, `default-impl-candidates`) — it's in Plant 5.1's. The rec is from a Plant-5.1-shaped cluster that happens to overlap on a file path with Plant 3.1.

### 3.2 The fix

Add `expected_substrate_signals` membership as a second gate:

```python
def bind_recs_to_plants(parsed_records, plants):
    for rec in parsed_records:
        cluster_id = rec.get("cluster_id") or ""
        rec_query = rec.get("query") or ""
        matched = []
        for plant in plants:
            signals = set(plant.get("expected_substrate_signals") or [])
            if rec_query and rec_query not in signals:
                continue  # cluster's query isn't in this plant's signal list — skip
            for path in plant.get("source_files") or []:
                if path and path in cluster_id:
                    matched.append(plant["plant_id"])
                    break
        bindings.append((rec, sorted(matched)))
```

Two safety properties:
1. **If `rec["query"]` is missing** (empty string after `or ""`), the signal gate is skipped — the legacy substring-only behavior remains. The `parsed-records.json` shape in round 1 always carries `query`, so this is a defense-in-depth fallback, not an expected path.
2. **If a plant has an empty `expected_substrate_signals` list,** the rec can never bind. The manifest validator already requires the list to be non-empty (manifest comment line 35), so this is also a defense-in-depth check.

### 3.3 Expected effect on round-1 numbers

The 6 false Plant 3.1 ↔ HSBColor bindings (`pat-candidates` query) drop out of `panel_routed` and reduce Plant 3.1's pair count. Plant 3.1's best-across-trials in S2 is already 1.0 from its real `function-duplicates` and `default-impl-candidates` signals, so the headline `canonical_recall` shouldn't move. What moves:

- `panel_routed.size` shrinks by 6 (12 → 6).
- `panel_route_rate` per condition drops by ~½ in whichever condition the 6 were concentrated.
- `unmatched.size` grows by 6 (those recs now have no plant binding).

Round-2 panel sitting will face 6 panel routed pairs instead of 12, all of them legitimate. The "panel review fatigue" cost halves.

### 3.4 Pre-implementation caller audit

A grep of the experiment dir (`grep -rn 'bind_recs_to_plants\|expected_substrate_signals' experiments/v7-refactor-recommendation/`) identifies every site affected by the new gate:

| File | Lines | What changes |
|---|---|---|
| `test_score_all.py::BindRecsToPlantsTests` | 93–119 (4 tests) | All use `_plant(..., source_files=[...])` with no `expected_substrate_signals` field. The shared `_rec` helper defaults `query="exact-duplicates"` (line 63). Under the new gate these tests bind to empty signal lists and return no matches, breaking three of the four. **Fix**: extend the `_plant` helper to accept `expected_substrate_signals` with a default of `["exact-duplicates"]` matching the `_rec` default, so existing call sites keep their current semantics. |
| `test_score_all.py::CLISmokeTests.test_runs_on_synthetic_corpus` | 786–798 | Synthetic plant fixture written into the tempdir's `plant-manifest.yaml` carries no `expected_substrate_signals`. **Fix**: add `expected_substrate_signals: [exact-duplicates]` to the inline YAML so the corpus run still produces `len(doc["scored"]) == 2`. |
| `test_analyses.py` | 317, 411, 420 | Existing plant fixtures already declare `expected_substrate_signals`. **No change required**. |
| `test_validator.py` | 235–236, 439–441 | These tests exercise the manifest validator's `expected_substrate_signals must be non-empty` rule. Independent of `bind_recs_to_plants`. **No change required**. |
| `validate-manifest.py` | 91, 218–222 | The validator already requires `expected_substrate_signals` to be a non-empty list per plant. **No change required**. |
| `score_all.py::score_recommendations` | 212 | Only caller in production code. The new gate is internal to `bind_recs_to_plants`; the call signature does not change. **No change required**. |

The public function signature of `bind_recs_to_plants` (`(parsed_records, plants) -> list[tuple[dict, list[str]]]`) is preserved. The behavior change is fully encapsulated. The plan does not consider this a breaking change for downstream callers because every caller already passes plants whose schema is governed by the manifest validator (which mandates `expected_substrate_signals`).

### 3.5 TDD steps

1. Add new tests to `test_score_all.py::BindRecsToPlantsTests` (sequence: failing test → implementation → green):
   - `test_signal_gate_blocks_cross_query_binding` — rec with `query="pat-candidates"` and `cluster_id` containing a Plant 3.1 source path, plant with `expected_substrate_signals=["function-duplicates", "default-impl-candidates"]` → empty bindings.
   - `test_signal_gate_admits_in_signal_binding` — same rec with `query="function-duplicates"` (in the plant's signal list) → binds normally.
   - `test_missing_rec_query_falls_back_to_legacy_behavior` — parameterized over three input shapes:
     - rec where `query` key is missing entirely from the dict
     - rec with `query=None`
     - rec with `query=""`
     Each case binds by substring alone (matches the pre-gate behavior). The `or ""` normalization is the intentional fallback and the test validates byte-for-byte consistency.
   - `test_signal_gate_skipped_for_empty_signal_list` — plant with `expected_substrate_signals=[]` and rec with valid query → no bindings (defense-in-depth: an empty signal list is treated as "no signals match", not "any signal matches"). The manifest validator rejects empty lists at runtime, so this case is unreachable in production — the test pins the safe-by-default behavior anyway.
2. Update the `_plant` helper to accept `expected_substrate_signals: list[str] | None = None` with the default applied as `expected_substrate_signals or ["exact-duplicates"]`. Document in a one-line comment that the default aligns with `_rec`'s default `query`.
3. Update the CLI smoke-test YAML fixture per §3.4 row 2.
4. Implement the gate in `bind_recs_to_plants` per §3.2.
5. Run `pytest experiments/v7-refactor-recommendation/test_score_all.py test_analyses.py test_validator.py`. Confirm all pass.

Note on regeneration of `analyses/` artifacts: this happens later in the sequence (step 8.5 in §8), after A3's targeted re-run produces the new Plant 1R parsed responses. Regenerating only after A2 (and not also A3) would freeze a snapshot that the next commit immediately invalidates.

## 4. A3 design — Plant 1R prompt tightening

### 4.1 The current bug

Agent prompt §1 rule 1 sub-bullets (lines 44–46):

```
- All participating records have is_test=true → reason_class: "test-fixture".
- All participating records have is_codegen=true → reason_class: "codegen".
- All records sit under Examples/ or SampleApp/ → reason_class: "sample-app-mirror".
```

"All participating records" is the bug for restraint plants. By design, a restraint cluster has *one* record carrying the restraint marker (test, mock, or sample-app) and at least one production record. The "all" framing never fires for these clusters, so the agent's other rules (mainly rule 5 "specifics precision") take over and recommend an action.

Methodology §9 ([line 643](../docs/refactor-recommendation-experiment-methodology.md#L643)) says: *"The agent's job is to weigh those flags against the action signal. A recommendation that acts on a cluster where every member has `is_test: true` is a clear false positive."* But the methodology doesn't address the mixed case explicitly — that's the gap.

### 4.2 The fix

Replace the three "All participating records have X" bullets with a single load-bearing rule:

> **Restraint markers dominate action signals.** If any participating record carries `is_test=true`, `is_mock=true`, or `is_sample_app=true` (or sits under `Examples/` / `SampleApp/`), default to `no-action` with the corresponding `reason_class` — `test-fixture`, `mock-fixture`, or `sample-app-mirror`. The action signal must clear a higher bar to override: the rationale must explicitly argue why the marked record is removable (e.g., it's a leftover prototype that should be deleted, not a deliberate fixture). Mixed marker/no-marker clusters are restraints by default, not lift candidates.

The `is_codegen=true` case stays as "all participating records" because codegen clusters are typically homogeneous (the whole cluster is auto-generated) and don't have the mixed-record restraint shape.

### 4.3 Expected effect on Plant 1R

Plant 1R has two records: `DebugPanel/DebugHUD.swift` (production) and `Wallpaper/Examples/WallpaperSampleApp/Sources/DebugHUD.swift` (sample app, `is_sample_app=true`). Under the tightened rule, the sample-app marker is load-bearing — the agent should recommend `no-action` with `reason_class: "sample-app-mirror"` instead of `extract-to-common`. FPR for Plant 1R drops from 0.20 (1/5) to 0.0 (0/5) across the 5 trials.

### 4.4 No full Phase D re-run, but a targeted Plant 1R re-run

A full Phase D re-run with the new prompt would re-run 60 trial-cluster recommendations (2 conditions × 3 trials × ~10 clusters per trial), at ~$40 cost. The targeted re-run is just Plant 1R's two clusters across the 5 trial-condition cells — 10 invocations at ~$2. Procedure:

1. Pull the two Plant 1R cluster rows from each trial's input file.
2. Re-invoke the agent with the new prompt against just those rows.
3. Parse the responses with `parse_responses.py`.
4. Confirm `no-action` for all 10 invocations.

The full re-run is out of scope here — that's round 2's job. The targeted re-run validates the prompt edit landed correctly without committing to a full re-execute.

### 4.5 Manifest already declares the expected restraint answer

Plant 1R's manifest entry (lines 209–239 of `plant-manifest.yaml`) already encodes the expected restraint answer:

```yaml
- plant_id: "1R"
  category: extract-to-common
  restraint: true
  restraint_pair: "1.1"
  restraint_signal: "is_sample_app=true on the WallpaperSampleApp copy"
  primary_answer:
    category: no-action
    specifics:
      reason_class: "sample-app-mirror"
    rationale_must_cite: ["MetricRow", "WallpaperSampleApp", "Examples/", "is_sample_app"]
  specifics_tolerance:
    reason_class_must_be_sample_app_mirror: true
```

`reason_class` is in `primary_answer.specifics.reason_class`, not `primary_answer.reason_class`. **No manifest change is required for A3** — only the agent prompt needs editing. The targeted re-run validates the agent emits the answer the manifest already expects.

### 4.6 TDD steps

The prompt is plain text — no code-level TDD. Validation steps:

1. Read the existing prompt §1 rule 1, edit the three bullets per §4.2 above.
2. Run `validate-manifest.py` to confirm the manifest still validates (no manifest changes were made, but the validator is cheap to run and catches regressions if someone touched the YAML by accident).
3. Run the targeted Plant 1R re-run per §4.4. Save outputs under `trial-logs/round1-correction-plant-1R/`.
4. Confirm 10/10 invocations recommend `no-action` with `reason_class: "sample-app-mirror"`.

If any of the 10 invocations still recommend action, the prompt edit didn't land cleanly — iterate.

## 5. Acceptance criteria

A PR is mergeable when all of:

- [ ] `bind_recs_to_plants` has the signal-list gate per §3.2.
- [ ] New tests in `test_score_all.py` cover the three cases in §3.4 step 1.
- [ ] Full `pytest experiments/v7-refactor-recommendation/` passes (the 38 existing tests plus the new ones).
- [ ] `analyses/scored.json`, `analyses/scored-aggregate.json`, `analyses/panel-routing.jsonl`, `analyses/panel-unblind.json` regenerated; checked-in artifacts match the tightened harness output byte-for-byte.
- [ ] Agent prompt §1 rule 1 edited per §4.2.
- [ ] Targeted Plant 1R re-run shows 10/10 no-action recommendations (logs committed under `trial-logs/round1-correction-plant-1R/`).
- [ ] `results.md` §4 updated (drop binding-artifact caveat from §4.2; record corrected FPR for Plant 1R in §4.1); §8 known limitations updated.
- [ ] `reproducibility.yaml`: bumped `prompt_hash`, fresh `round1_correction` block under `execution`.
- [ ] Local CI passes (lint + format + type + pytest) before push.

## 6. After-merge tracking issue (A1)

File a GitHub issue titled "Round-2 panel composition: recruit 2 additional reviewers for Fleiss κ". Body covers:

- **Problem.** Round-1 panel sitting (PR #82) ran with 1 reviewer due to time constraints; `inter_rater.fleiss_kappa` is the structured-null sentinel `{fleiss_kappa: null, n_items: <N>, n_raters: 1, note: "panel-pending: m<2"}`. Methodology §12 requires κ ≥ 0.4 to claim the panel rubric is reliable.
- **Desired end state.** Two additional reviewer files (`analyses/panel-scores-reviewer-2.jsonl`, `analyses/panel-scores-reviewer-3.jsonl`) added; concatenated into `analyses/panel-scores.jsonl`; `score_all.py` re-run; `inter_rater.fleiss_kappa` populates.
- **Where.** Round-1 closeout artifacts: `analyses/panel-routing.jsonl` (the rec rows reviewers score), `experiments/v7-refactor-recommendation/panel-instructions.md` (the instructions packet).
- **Constraints.** Reviewers must be blind to condition (`unblind.json` is not shipped to them); reviewers must use the same rubric (`rubric.yaml`).
- **Acceptance criteria.** (1) Two reviewer files committed, (2) `analyses/panel-scores.jsonl` regenerated, (3) `score_all.py` re-run produces a populated `inter_rater.fleiss_kappa`, (4) `results.md` §4.3 updated to report the κ value.
- **Related.** PR #82 (round-1 panel sitting), issue #81 (closed by PR #82), this plan's PR (link after creation).

Labels: `experiment-v7`, `round-2`, `methodology`.

## 7. Risks and mitigations

- **R1: Signal-list gate accidentally drops legitimate bindings.** Mitigation: review the manifest's `expected_substrate_signals` per plant before merging. The manifest validator (`validate-manifest.py`) confirms every plant has a non-empty list. The plan's `test_missing_rec_query_falls_back_to_legacy_behavior` ensures recs without a `query` field still bind by substring alone.
- **R2: Prompt edit triggers regressions on non-Plant-1R clusters.** Mitigation: the targeted Plant 1R re-run validates the change for Plant 1R specifically. If round-2 Phase D re-run surfaces new false negatives on other plants (e.g., a real lift cluster where one record happens to be a test file), they show up as recall drops in canonical plants — visible in the round-2 results doc, addressable then.
- **R3: Regenerated `analyses/` artifacts diverge from PR #82's snapshot in ways the plan doesn't predict.** Mitigation: diff the new `analyses/scored.json` against the merged one; any unexpected changes get investigated before commit. The expected changes are bounded — only `panel_routed.size` and `unmatched.size` should shift, by the same 6 rows.
- **R4: The targeted Plant 1R re-run fails (some invocations still recommend action).** Mitigation: if 1–2 invocations still recommend action, that's prompt sensitivity — record it in `results.md` §4.1 as residual FPR (1/10 = 0.10 is still half of round 1's 0.20). If ≥3 fail, the prompt edit didn't fix the underlying issue; pause and re-design.

## 8. Sequencing inside the PR

The regeneration-order issue (M2 from review): A3's targeted Plant 1R re-run produces new parsed responses for the two Plant 1R clusters. Those responses must be merged into the parsed cache *before* `analyses/` is regenerated, otherwise the regenerated artifacts reflect only A2's binding fix and not A3's prompt fix. The corrected sequence:

1. Branch from `experiment/swift-substrate` (already done — this worktree is `v7-phase-e-round1-closeout`).
2. A2 TDD per §3.5: update `_plant` helper default, add new tests, implement the gate. Commit: `score(v7-phase-e): gate plant bindings on expected_substrate_signals`.
3. A3 prompt edit per §4.6 steps 1–2. Commit: `prompt(v7-phase-e): make restraint markers load-bearing in rule 1`.
4. Targeted Plant 1R re-run per §4.6 steps 3–4. Save raw responses + parsed responses under `trial-logs/round1-correction-plant-1R/`. Commit: `trial-logs(v7-phase-e): Plant 1R re-run under tightened prompt`.
5. Merge the new Plant 1R parsed responses into the parsed cache. Strategy: overwrite the existing Plant-1R rows in `trial-logs/parsed/<cond>/trial<N>/*.json` with the re-run output. The non-Plant-1R rows remain untouched. Commit: `parsed-cache(v7-phase-e): swap in Plant 1R re-run responses`.
6. Regenerate `analyses/scored.json`, `analyses/scored-aggregate.json`, `analyses/panel-routing.jsonl`, `analyses/panel-unblind.json` against the now-merged parsed cache. Spot-check: `panel_routed.size` shrunk by ~6 (from A2); Plant 1R category=`no-action` for all 10 invocations (from A3). Commit: `analyses(v7-phase-e): regenerate against tightened harness + Plant 1R re-run`.
7. Update `results.md` §4 (drop binding-artifact caveat from §4.2, record Plant 1R FPR = 0/5 in §4.1) and `results.md` §8 (drop binding caveat from known limitations). Update `reproducibility.yaml` per §2 template above. Commit: `results(v7-phase-e): record round-1 corrections (A2 + A3)`.
8. Run local CI (lint + format + type + pytest). Fix anything red.
9. Push. Open issue with this plan as body. Open PR with `Closes #<issue>`. File A1 tracking issue separately per §6.

**Final-state acceptance check after step 6** (verifies both corrections landed cleanly):
- `panel_routed.size` ≈ 6 (down from 12, none of which should be Plant 3.1 ↔ HSBColor)
- Plant 1R cell `n_fp == 0` for both S1 and S2 in all three trials
- `inter_rater.fleiss_kappa` still null (panel sitting hasn't been re-run with 3 reviewers yet)
- `panel_route_rate` per condition halves vs PR #82's headline
