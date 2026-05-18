# V7 Phase E — Round-1 Closeout (A2 + A3) Plan

> Successor to [`v7-phase-e-scoring-and-writeup-plan.md`](v7-phase-e-scoring-and-writeup-plan.md). That plan delivered [PR #82](https://github.com/jakebromberg/code-audit-pipeline/pull/82) (auto-scorer + panel-promotion + results.md). This plan closes the round-1 gaps surfaced by the panel sitting and the results-doc review: false bindings from cluster-id substring matching (A2), and Plant 1R's false positive from a not-quite-load-bearing restraint rule in the agent prompt (A3). A1 (recruit 2 more reviewers) ships as a tracking issue rather than code in this plan.

## 1. Context and motivation

Round 1 [results.md](../experiments/v7-refactor-recommendation/results.md) §4 surfaced two issues the panel sitting made concrete:

- **§4.2 binding-artifact finding.** Twenty-four recs across the corpus were bound to multiple plants via substring match on `source_files` when only one of those plants actually owned the cluster (the rec's `query` was in only one plant's `expected_substrate_signals` list). The most visible cluster is HSBColor: both Plant 3.1 (signals: `function-duplicates`, `default-impl-candidates`) and Plant 5.1 (signals: `function-duplicates`, `generic-function-candidates`) declare HSBColor.swift in their source_files. For clusters from queries only one plant lists as a signal (`default-impl-candidates`-only or `generic-function-candidates`-only), the substring rule binds to both plants instead of the one that signal-matches. A separate, deeper case — clusters from queries BOTH plants list — is round-2 work (see §6.2 below).
- **§4.1 Plant 1R FPR contribution.** Plant 1R is the restraint twin for Category 1 (extract-to-common), distinguished by `restraint_signal: "is_sample_app=true on the WallpaperSampleApp copy"`. The extract-to-common category's per-cell FPR is 1.0 across all six cells (3 trials × 2 conditions) under round 1, because in every cell at least one cluster bound to Plant 1R received an action rec. The agent acknowledges `is_sample_app=true` in its rationale on the canonical MetricRow cluster (and correctly emits `no-action` there) but lifts unrelated clusters that mention DebugHUD.swift or DebugMetricsProvider.swift, treating the sample-app flag as advisory rather than load-bearing.

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

### 3.2 The fix — prefer-signal-match resolution rule

**First-draft rule (strict gate).** The simplest fix is to require both substring match AND `rec["query"] in plant["expected_substrate_signals"]` for every binding. But empirically this is too strict for round 1: Plant 1R's pre-registered signals are `[exact-duplicates, cross-package-shape-near-duplicates-any]`, but its path-based `source_files` only substring-match clusters from path-bearing query types (`function-duplicates-exact`, `subset-pairs`, `pat-candidates`, etc.) — none of which are in Plant 1R's signal list. The strict rule would eliminate every Plant 1R binding, collapsing the restraint's FPR contribution to 0/5 by structural exclusion rather than by the agent emitting `no-action`. That suppresses the very signal A3 is meant to fix.

**Final rule (prefer signal-match when plants compete on substring).** Bind a rec to a plant when:
- The cluster_id substring-matches one of the plant's `source_files` (status quo), AND
- Either (a) no *other* plant whose `source_files` also substring-match the cluster_id has `rec["query"]` in their signal list, OR (b) this plant has `rec["query"]` in its own signal list.

In code:

```python
def bind_recs_to_plants(parsed_records, plants):
    for rec in parsed_records:
        cluster_id = rec.get("cluster_id") or ""
        rec_query = rec.get("query") or ""
        substring_matches: list[str] = []
        signal_matches: list[str] = []
        for plant in plants:
            paths = plant.get("source_files") or []
            substring_hit = any(p and p in cluster_id for p in paths)
            if not substring_hit:
                continue
            substring_matches.append(plant["plant_id"])
            signals = plant.get("expected_substrate_signals") or []
            if rec_query and rec_query in signals:
                signal_matches.append(plant["plant_id"])
        matched = signal_matches if signal_matches else substring_matches
        bindings.append((rec, sorted(matched)))
```

**Behavior on the two motivating cases:**

| Case | Old logic | New logic |
|---|---|---|
| HSBColor `pat-candidates` cluster (substring-matches both Plant 3.1 and Plant 5.1; `pat-candidates` is in 5.1's signals, not 3.1's) | Binds to [3.1, 5.1] — Plant 3.1 binding is a false positive | Binds to [5.1] — `signal_matches=[5.1]` is non-empty so it wins over the broader substring set |
| DebugHUD `function-duplicates-exact` cluster (substring-matches only Plant 1R; `function-duplicates-exact` not in Plant 1R's signals) | Binds to [1R] | Binds to [1R] — `signal_matches=[]` so falls back to `substring_matches=[1R]` |

**Defense-in-depth fallback.** If `rec["query"]` is missing/None/empty, `rec_query` is falsy, so `signal_matches` stays empty and the legacy substring-only behavior triggers via the fallback branch. This preserves byte-stable output for any pre-`query`-field parsed cache.

### 3.3 Expected effect on round-1 numbers

Measured across the full parsed cache:

- **Cleanup count: 24 false bindings removed.** Per-plant before→after row counts: Plant 3.1 (60→57, −3), Plant 3R (27→18, −9), Plant 5.1 (36→33, −3), Plant 5.3 (24→15, −9). These are recs where exactly one plant signal-matched the rec's query and the others didn't; under the new rule the others' substring matches drop out and only the signal-matched plant binds. No plant gains bindings.
- **Plant 1R bindings preserved: 99→99.** Plant 1R's signals (`exact-duplicates`, `cross-package-shape-near-duplicates-any`) don't match the path-bearing queries (`function-duplicates-exact`, `subset-pairs`, etc.) that surface its source_files. But no *other* plant has its source_files either, so `signal_matches` stays empty and the substring fallback binds Plant 1R unconditionally. A3's prompt change is therefore behaviorally measurable rather than suppressed by binding logic.
- **Plant 3.1 ↔ Plant 5.1 co-bindings on HSBColor function-duplicates clusters: NOT fixed.** This is the gap the plan does not address. Both plants list `function-duplicates` in their signals and both have `HSBColor.swift` in their source_files, so the new rule leaves both bound. The 12 panel-routed pairs the round-1 panel scored are unchanged: 6 Plant 3.1 + 6 Plant 5.1 entries for the same `function-duplicates-near:HSBColor.uiColor+HSBColor.nsColor` cluster. The panel correctly scored the Plant 3.1 bindings as 0.0 (cluster is about uiColor/nsColor, Plant 5.1's planted shape, not init signatures which are Plant 3.1's). Fixing this requires finer-grained matching on planted symbols (a new manifest field) — out of scope here; filed as a round-2 follow-up (§6.2 below).
- **Headline `canonical_recall` unchanged.** No removed binding promotes a higher-scoring rec out, and no plant gains a binding. Plant 3.1's best-across-trials in S2 is already 1.0 from its real signals.
- **`panel_routed.size` unchanged at 12.** The panel-routed pairs are the HSBColor co-bindings, which the new rule keeps.

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

### 4.3 Expected effect on Plant 1R — methodological, not measurable in round 1

Inspecting the round-1 raw responses for Plant 1R's two canonical clusters (`exact-duplicates:MetricRow+MetricRow` and `function-duplicates-exact:...MetricRow.body...`) across all 6 trial-condition cells: the agent **already emits `no-action` with `reason_class: "sample-app-mirror"`** on every one. The agent's behavior on Plant 1R's actual planted shape is correct under the current prompt.

The 1.0 per-cell FPR Plant 1R contributes to extract-to-common comes from a different source: **incidental bindings**. Plant 1R's source_files include `Shared/DebugPanel/Sources/DebugPanel/DebugHUD.swift`, which substring-matches clusters about unrelated symbols in the same file (`DebugMetricsProvider.updateMetrics`, `.measureCPUUsage`, `.measureMemoryUsage`, etc.). Those clusters' recs are `extract-to-common` — correctly so, since they ARE about lifting per-method shape, not about Plant 1R's MetricRow sample-app twin. The binding logic mis-attributes them to Plant 1R, generating false FPs.

So the round-1 FPR is structural (binding-level), not behavioral (prompt-level). A3's prompt change is therefore:
- **Methodologically correct.** The "all participating records have X" framing is wrong for restraint patterns by design — Plant 1R, 2R, 3R are exactly the mixed-marker case the original rule misses. Future restraint plants (and the round-2 panel) will exercise the corrected rule.
- **Not measurable in round 1.** Re-running Plant 1R's canonical clusters under the new prompt would just re-produce the existing `no-action` outputs. The headline FPR doesn't move because it's driven by incidental bindings, not by Plant 1R's planted shape.
- **Independent of A2's gap.** The same symbol-level matching that §6.2 calls for would also resolve Plant 1R's incidental bindings — the cluster_id mentions `DebugMetricsProvider.updateMetrics`, which is *not* in Plant 1R's planted symbols (`MetricRow` only). Once §6.2 ships, Plant 1R will have only its 2 canonical clusters bound, those will be `no-action`, and the round-2 FPR will drop to 0 — under the round-2 prompt (A3), which by then will be in force.

### 4.4 No targeted re-run

The plan originally called for a 10-invocation targeted re-run against Plant 1R's two clusters under the new prompt. Cancelled: the agent already emits `no-action` on those clusters under the OLD prompt, so re-running validates nothing observable. The prompt change only *adds* no-action triggers (any-vs-all is more permissive), so a regression on existing no-action behavior is logically impossible. Savings: $2 + one round trip.

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

### 4.6 Validation steps

The prompt is plain text — no code-level TDD. Validation:

1. Edit the existing prompt §1 rule 1 per §4.2 above.
2. Run `validate-manifest.py` as a sanity check (manifest unchanged, but the validator catches accidental edits).
3. Diff the prompt change against the methodology §9 restraint framing — confirm the change is consistent with "the agent's job is to weigh those flags against the action signal" (methodology line 643) under the mixed-marker reading.

No regression test fires because the change only adds no-action triggers. The round-2 panel sitting will exercise the corrected rule.

## 5. Acceptance criteria

A PR is mergeable when all of:

- [ ] `bind_recs_to_plants` has the prefer-signal-match resolution per §3.2.
- [ ] New tests in `test_score_all.py` cover the cases in §3.5.
- [ ] Full `pytest experiments/v7-refactor-recommendation/` passes.
- [ ] `analyses/auto-scores.json`, `analyses/score-summary.json`, `analyses/panel-routing.jsonl`, `analyses/panel-unblind.json` regenerated against the new rule; per-plant binding counts match §3.3 (Plant 3.1: 60→57, Plant 3R: 27→18, Plant 5.1: 36→33, Plant 5.3: 24→15).
- [ ] Agent prompt §1 rule 1 edited per §4.2.
- [ ] `results.md` §4 updated to describe the corrected binding logic and Plant 1R FPR's structural origin (carries forward unchanged for round 1; deferred to §6.2's round-2 fix for behavioral resolution); §8 known limitations updated.
- [ ] `reproducibility.yaml`: bumped `prompt_hash`, fresh `round1_correction` block under `execution`.
- [ ] Local CI passes (lint + format + type + pytest) before push.
- [ ] Tracking issues filed per §6.1 (A1) and §6.2 (round-2 binding-artifact v2).

### 6.1 After-merge tracking issue — A1 (recruit 2 more reviewers)

File a GitHub issue titled "Round-2 panel composition: recruit 2 additional reviewers for Fleiss κ". Body covers:

- **Problem.** Round-1 panel sitting (PR #82) ran with 1 reviewer due to time constraints; `inter_rater.fleiss_kappa` is the structured-null sentinel `{fleiss_kappa: null, n_items: <N>, n_raters: 1, note: "panel-pending: m<2"}`. Methodology §12 requires κ ≥ 0.4 to claim the panel rubric is reliable.
- **Desired end state.** Two additional reviewer files (`analyses/panel-scores-reviewer-2.jsonl`, `analyses/panel-scores-reviewer-3.jsonl`) added; concatenated into `analyses/panel-scores.jsonl`; `score_all.py` re-run; `inter_rater.fleiss_kappa` populates.
- **Where.** Round-1 closeout artifacts: `analyses/panel-routing.jsonl` (the rec rows reviewers score), `experiments/v7-refactor-recommendation/panel-instructions.md` (the instructions packet).
- **Constraints.** Reviewers must be blind to condition (`unblind.json` is not shipped to them); reviewers must use the same rubric (`rubric.yaml`).
- **Acceptance criteria.** (1) Two reviewer files committed, (2) `analyses/panel-scores.jsonl` regenerated, (3) `score_all.py` re-run produces a populated `inter_rater.fleiss_kappa`, (4) `results.md` §4.3 updated to report the κ value.
- **Related.** PR #82 (round-1 panel sitting), issue #81 (closed by PR #82), this plan's PR (link after creation).

Labels: `experiment-v7`, `round-2`, `methodology`.

### 6.2 After-merge tracking issue — round-2 binding-artifact v2 (finer-grained symbol matching)

The A2 rule shipped here doesn't fix the round-1 panel-routed Plant 3.1 ↔ Plant 5.1 co-binding for `function-duplicates-near:HSBColor.uiColor+HSBColor.nsColor` because both plants list `function-duplicates` in their signals and both have HSBColor.swift in source_files. The 12 panel-routed pairs (6 Plant 3.1, 6 Plant 5.1) remain after A2. File an issue with:

- **Problem.** When two plants share both a source file AND a substrate signal, the cluster_id substring + signal-list rule can't tell them apart. Plant 3.1 (init signatures) and Plant 5.1 (uiColor/nsColor accessors) both surface HSBColor.swift in `function-duplicates`, but a given cluster is genuinely about one specific planted shape, not both.
- **Desired end state.** A new manifest field per plant — `expected_cluster_symbols` (or similar) — listing the literal symbol substrings the cluster_id must contain for a binding to be valid. For Plant 3.1: `["HSBColor.init", "AccentColor.init", "HSBOffset.init"]`. For Plant 5.1: `["HSBColor.uiColor", "HSBColor.nsColor"]`. `bind_recs_to_plants` then gates on: (substring path match) AND (any planted symbol substring matches cluster_id).
- **Where.** `experiments/v7-refactor-recommendation/plant-manifest.yaml` (new field per plant), `validate-manifest.py` (validator), `score_all.py::bind_recs_to_plants` (rule), `test_score_all.py` + `test_validator.py` (tests).
- **Constraints.** Pre-registration discipline (methodology §10): adding manifest fields after trials is allowed via `rubric-modifications.md` documentation. Expected to land at start of round 2, before any round-2 trial executes.
- **Acceptance criteria.** (1) Every plant has a non-empty `expected_cluster_symbols` list, (2) round-1 12 panel-routed pairs project down to ~6 under the new rule, (3) regression test for the HSBColor case lives in `test_score_all.py`, (4) `results.md` round-2 §4.2 updated.

Labels: `experiment-v7`, `round-2`, `methodology`. Block on round-2 Phase D execution.

## 7. Risks and mitigations

- **R1: Signal-list gate accidentally drops legitimate bindings.** Mitigation: review the manifest's `expected_substrate_signals` per plant before merging. The manifest validator (`validate-manifest.py`) confirms every plant has a non-empty list. The plan's `test_missing_rec_query_falls_back_to_legacy_behavior` ensures recs without a `query` field still bind by substring alone.
- **R2: Prompt edit triggers regressions on non-Plant-1R clusters.** Mitigation: the targeted Plant 1R re-run validates the change for Plant 1R specifically. If round-2 Phase D re-run surfaces new false negatives on other plants (e.g., a real lift cluster where one record happens to be a test file), they show up as recall drops in canonical plants — visible in the round-2 results doc, addressable then.
- **R3: Regenerated `analyses/` artifacts diverge from PR #82's snapshot in ways the plan doesn't predict.** Mitigation: diff the new `analyses/scored.json` against the merged one; any unexpected changes get investigated before commit. The expected changes are bounded — only `panel_routed.size` and `unmatched.size` should shift, by the same 6 rows.
- **R4: The targeted Plant 1R re-run fails (some invocations still recommend action).** Mitigation: if 1–2 invocations still recommend action, that's prompt sensitivity — record it in `results.md` §4.1 as residual FPR (1/10 = 0.10 is still half of round 1's 0.20). If ≥3 fail, the prompt edit didn't fix the underlying issue; pause and re-design.

## 8. Sequencing inside the PR

Simplified after dropping the targeted re-run (§4.4) and reframing FPR resolution as round-2 work:

1. Branch from `experiment/swift-substrate` (already done).
2. A2 implementation per §3.5: update `_plant` helper default, add new tests, implement the prefer-signal-match resolution. Commit: `score(v7-phase-e): prefer signal-match over substring-only in bind_recs_to_plants`.
3. A3 prompt edit per §4.6. Commit: `prompt(v7-phase-e): make restraint markers load-bearing in rule 1`.
4. Regenerate `analyses/auto-scores.json`, `analyses/score-summary.json`, `analyses/panel-routing.jsonl`, `analyses/panel-unblind.json` against A2. Spot-check: per-plant binding counts match §3.3. Commit: `analyses(v7-phase-e): regenerate after binding-artifact filter`.
5. Update `results.md` §4 and §8 to reflect the corrected understanding (A2 cleans 24 false bindings; panel-routed Plant 3.1/5.1 deferred to §6.2; Plant 1R FPR deferred to §6.2 + A3 as round-2 fix). Update `reproducibility.yaml` per §2 template. Commit: `results(v7-phase-e): record round-1 corrections (A2 + A3)`.
6. Run local CI (lint + format + type + pytest). Fix anything red.
7. Push. Open issue with this plan as body. Open PR with `Closes #<issue>`. File A1 tracking issue per §6.1 and round-2 binding-artifact-v2 tracking issue per §6.2.

**Final-state acceptance check after step 6** (verifies both corrections landed cleanly):
- 24 fewer non-panel-routed Plant 3.1/3R/5.1/5.3 bindings present (the §3.3 cleanup).
- `panel_routed.size` unchanged at 12 — the HSBColor panel-routed co-bindings persist (round-2 §6.2 fix needed).
- Plant 1R cell `n_fp == 0` for both S1 and S2 in all three trials after A3's targeted re-run (compared to round 1's `n_fp == 1`).
- `inter_rater.fleiss_kappa` still null (panel sitting hasn't been re-run with 3 reviewers yet).
- Headline `canonical_recall` unchanged (no plant gained bindings; removed bindings didn't carry the best score in any cell).
