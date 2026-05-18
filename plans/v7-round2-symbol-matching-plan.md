# V7 Round 2 — symbol-level binding (resolves #86)

> Successor to [`v7-phase-e-round1-closeout-plan.md`](v7-phase-e-round1-closeout-plan.md). Round-1 closeout's prefer-signal-match rule in `bind_recs_to_plants` cleaned 24 incidental false bindings but left two known gaps documented in `results.md` §4.2 and §8: the panel-routed Plant 3.1 ↔ Plant 5.1 co-binding on HSBColor (12 panel rows), and Plant 1R's binding-structural 1.0 per-cell FPR from 16 incidental DebugMetricsProvider bindings on `DebugHUD.swift`. Both have the same root cause: (path, query) granularity cannot disambiguate when two plants share both a source file and a signal. This plan introduces a per-plant `expected_cluster_symbols` manifest field that gates bindings on planted-symbol substring membership in `cluster_id`, and pre-registers it via `rubric-modifications.md` per methodology §10.

## 1. Context and motivation

Two known-gap cases that the prefer-signal-match rule doesn't fix:

- **Panel-routed HSBColor co-binding (12 rows).** Plant 3.1 (default-implementation, source_type "HSBColor/AccentColor/HSBOffset init") and Plant 5.1 (generic-parameterization, source_type "HSBColor.uiColor ↔ HSBColor.nsColor") both list `HSBColor.swift` in their source_files AND both list `function-duplicates` in their signals. The panel-routed cluster (`function-duplicates-near:...:HSBColor.uiColor+...:HSBColor.nsColor`) is Plant 5.1's territory empirically — but the binding rule attributes it to both plants, doubling the panel load and producing 6 "false" Plant 3.1 rows that the panel sitting correctly scored as 0.0.
- **Plant 1R structural FPR.** Plant 1R's two source files are `DebugPanel/DebugHUD.swift` (production) and `Wallpaper/Examples/WallpaperSampleApp/Sources/DebugHUD.swift` (sample app). 16 of Plant 1R's 18 bindings are incidental — clusters about `DebugMetricsProvider.updateMetrics`, `.measureCPUUsage`, `.measureMemoryUsage`, etc., which substring-match `DebugHUD.swift` but aren't about Plant 1R's planted MetricRow shape. Round-1 closeout audit confirmed: the agent emits `no-action` on Plant 1R's two canonical MetricRow clusters but (correctly) recommends `extract-to-common` on the incidental DebugMetricsProvider clusters; the binding logic mis-attributes the latter to Plant 1R, producing 1.0 per-cell FPR.

Both gaps converge on the same fix: gate bindings on planted-symbol membership in `cluster_id`, not just source_file substring.

## 2. Scope

In one PR against `experiment/swift-substrate`:

- **New manifest field** `expected_cluster_symbols` per plant (non-empty list of literal substrings the cluster_id must contain for a binding to be valid). Populate for all 25 plants by reading round-1's empirical cluster_id list per plant (already enumerated; see §3.1 inventory).
- **Validator extension** in `validate-manifest.py` — require non-empty `expected_cluster_symbols` per plant; reject empty or missing.
- **`bind_recs_to_plants` rule update** — add a hard symbol gate between substring-match and signal-prefer.
- **`rubric-modifications.md` (new file)** — pre-registration discipline per methodology §10. Record the post-hoc manifest field addition with rationale, expected impact, and pointer to this plan.
- **Regression tests** for: HSBColor Plant 3.1 / 5.1 disambiguation, Plant 1R incidental DebugMetricsProvider exclusion, fallback semantics, validator rule.
- **Regenerate analyses/** against the new rule. Expected outcomes:
  - `panel_routed.size`: 12 → 6 (Plant 3.1 entries drop out; Plant 5.1 entries persist).
  - Plant 1R bindings: 99 → ~24 (just the canonical MetricRow clusters across (cond, trial)) — wait, let me audit this in §3.3.
  - Plant 1R per-cell FPR: 1.0 → 0.0 in all 6 cells.
  - Headline `canonical_recall` unchanged.
- **Update `results.md`** §4.2 (binding-artifact now fully resolved), §4.1 (Plant 1R FPR resolved), §8 known limitations (drop both resolved entries; add a note about cluster_id-symbol gating).
- **Update `reproducibility.yaml`** — bump `manifest_hash`, add a `round2_methodology_update` block under `execution` describing the rubric-modifications.md addition.

**Out of scope here:**
- Plant 1.4 surfaces (separate methodology gap; tracked in §8 of results.md).
- Plant 5.4 surfaces (only 2 clusters, both fine — see §3.1).
- Round-2 panel sitting (still depends on #85's reviewer recruitment).
- Value-aware specifics matching (#35 / B1).

## 3. Design

### 3.1 Empirical cluster_id inventory per plant

A full audit of `trial-logs/parsed/**/*.json` produces these per-plant cluster_id counts under the round-1 closeout binding rule:

| Plant | Category | Clusters | Notes |
|---|---|---|---|
| 1.1 | extract-to-common | 8 | Multi-file; legit binding is SwiftUI.Image extensions. |
| 1.2 | extract-to-common | 4 | Intents (PauseWXYC, PlayWXYC, ToggleWXYC, WhatsPlayingOnWXYC). |
| 1.3 | extract-to-common | 2 | HLSRateDidChangeMessage.makeMessage / makeNotification. |
| 1.4 | extract-to-common | **0** | Plant doesn't surface in any V7 cluster (round-1 known limitation). |
| 1R | extract-to-common/restraint | 18 | **Only 2 are canonical (MetricRow); 16 are incidental DebugMetricsProvider.** |
| 2.1 | protocol-inheritance | 7 | MainActorNotificationMessage / AsyncNotificationMessage. |
| 2.2 | protocol-inheritance | 4 | PlayerProtocol / HLSAVPlayerProtocol. |
| 2.3 | protocol-inheritance | 10 | AudioPlayerProtocol / MockAudioPlayer / AudioEnginePlayerProtocol. |
| 2.4 | protocol-inheritance | 9 | AudioEnginePlayerProtocol / AudioPlayerProtocol. |
| 2R | protocol-inheritance/restraint | 3 | _Plant_MockAsyncNotificationMessage (`*Testing/` mocks). |
| 3.1 | default-implementation | 11 | HSBColor/AccentColor/HSBOffset init. **Includes 6 panel-routed Plant 5.1 territory clusters (HSBColor uiColor/nsColor).** |
| 3.2 | default-implementation | 5 | MaterialBlendMode.displayName / .blendMode. |
| 3.3 | default-implementation | 4 | FFTProcessor.reset / .setNormalizationMode. |
| 3.4 | default-implementation | 16 | Talkset.init / Breakpoint.init / _Plant_Announcement.init. |
| 3R | default-implementation/restraint | 6 | Breakpoint.stub / Talkset.stub / _Plant_PlaycutStub. |
| 4.1 | pat-introduction | 11 | NowPlayingItem / PlaycutSelection. |
| 4.2 | pat-introduction | 4 | _Plant_ShowContainer / ShowContainerProtocol. |
| 4.3 | pat-introduction | 2 | _Plant_ArtistRepository / ArtistRepository. |
| 4.4 | pat-introduction | 2 | _Plant_CacheLoader / _Plant_MetadataLoader. |
| 4R | pat-introduction/restraint | 8 | MockStructuredAnalytics / PlaybackAnalytics (Testing target). |
| 5.1 | generic-parameterization | 7 | HSBColor.uiColor / HSBColor.nsColor. **Includes Plant 3.1 territory overlap on `cross-package-shape-near-duplicates-any:HSBColor`.** |
| 5.2 | generic-parameterization | 2 | _Plant_GenericFetcher.fetchInt / fetchString. |
| 5.3 | generic-parameterization | 7 | AsyncNotificationMessageSequence.AsyncIterator.init (cross-plant overlap with 2.1). |
| 5.4 | generic-parameterization | 2 | _Plant_IntCache / _Plant_StringCache. |
| 5R | generic-parameterization/restraint | 6 | Breakpoint.stub / Talkset.stub / _Plant_PlaycutStub (same stubs as 3R; cross-lens restraint). |

The "incidental binding" pattern shows up wherever a source file contains MULTIPLE planted-or-real symbols and the substring rule grabs everything. Plants 1R, 3.1, 3.4, and 4R are the most affected.

### 3.2 `expected_cluster_symbols` semantics

Per-plant non-empty list of literal substrings. A cluster binds to the plant only if at least one entry is a substring of the cluster's `cluster_id`. Examples:

```yaml
- plant_id: "3.1"
  expected_cluster_symbols:
    - "HSBColor.init(hue:saturation:brightness:)"
    - "AccentColor.init"
    - "HSBOffset.init"
- plant_id: "5.1"
  expected_cluster_symbols:
    - "HSBColor.uiColor"
    - "HSBColor.nsColor"
- plant_id: "1R"
  expected_cluster_symbols:
    - "MetricRow"
```

Symbols should be **specific enough to disambiguate** when two plants share a file (e.g., `HSBColor.init` vs `HSBColor.uiColor`) and **stable across cluster-query variants** (the substring should appear in clusters from all of the plant's `expected_substrate_signals`).

### 3.3 Binding rule update

Current rule (post-PR-#84):

```python
substring_matches = [plants whose source_files substring-match cluster_id]
signal_matches = [substring_matches ∩ plants whose signals contain rec_query]
return signal_matches if signal_matches else substring_matches
```

New rule:

```python
substring_matches = [plants whose source_files substring-match cluster_id]
symbol_matches = [substring_matches ∩ plants whose any expected_cluster_symbol substring-matches cluster_id]
signal_matches = [symbol_matches ∩ plants whose signals contain rec_query]
return signal_matches if signal_matches else symbol_matches  # NO fallback to substring_matches
```

Three invariants:
1. **Hard symbol gate.** A plant must signal-match AND symbol-match for any binding. Substring-only matches that the symbol gate rejects produce no binding (rec goes to unmatched).
2. **Symbol-match is the new "claim".** The signal-prefer resolution still applies *within* the symbol-matched set, not against the broader substring set.
3. **Backward fallback for testing.** A plant with an empty `expected_cluster_symbols` list (the validator rejects this in production) preserves the previous behavior. Manifest validator enforces non-empty.

### 3.4 Expected effect on round-1 numbers

Projected from the §3.1 inventory:

**Plant 3.1 / 5.1 panel-route resolution:**
- Old: 12 panel-routed pairs (6 for 3.1, 6 for 5.1) on the HSBColor function-duplicates-near cluster
- New: 6 panel-routed pairs (Plant 5.1 only) — Plant 3.1's expected_cluster_symbols (init signatures) don't appear in the panel-routed cluster's cluster_id

**Plant 1R FPR resolution:**
- Old: 18 Plant 1R bindings × 1.0 per-cell FPR (16 incidentals trigger action recs)
- New: 2 Plant 1R bindings (canonical MetricRow only) × 5 (cond, trial) cells = 10 rows, all `no-action` → 0.0 per-cell FPR
- Wait — that's wrong arithmetic. Plant 1R has 2 distinct canonical clusters (`exact-duplicates:MetricRow+MetricRow` and `function-duplicates-exact:...MetricRow.body...`), and each appears in 5 of 6 trial-condition cells (S1 has only `exact-duplicates`, S2 has both). I'll verify the exact count during implementation.
- Either way: 0/6 cells trigger action recs → restraint_fpr drops from 1.0 to 0.0 for extract-to-common.

**Headline:**
- `canonical_recall`: unchanged. No plant gains a binding; removed bindings don't carry the best score in any cell (Plant 3.1's best-across-trials is 1.0 from its real init clusters; Plant 1R's score was already 0.5 for the canonical no-action).
- Headline 1−FPR: 0.800 → 0.840 (1−0.20 → 1−0.16... wait, need to recalculate). The FPR is the mean across categories. Old: 1/5 categories had FPR > 0 (extract-to-common at 1/1 = 1.0); mean FPR = 0.20. New: 0/5 categories have FPR > 0; mean FPR = 0.0. **Headline 1−FPR jumps from 0.800 to 1.000.** This is the methodologically biggest round-2 result.
- `panel_route_rate` per condition halves (the 6 dropped Plant 3.1 panel routings).

### 3.5 Per-plant symbol enumeration (draft)

Working drafts for the 24 plants with at least 1 cluster (Plant 1.4 is empty and stays empty for round 1's purposes; the validator should treat an empty list as a methodology gap to log, not a binding rule):

| Plant | expected_cluster_symbols (draft) |
|---|---|
| 1.1 | `["SwiftUI.Image.background", "SwiftUI.Image"]` — Image extensions in both files; logo + background are the planted methods |
| 1.2 | `["PauseWXYC", "PlayWXYC", "ToggleWXYC", "WhatsPlayingOnWXYC", "MakeARequest", "NowPlayingWidgetIntent"]` |
| 1.3 | `["HLSRateDidChangeMessage.makeMessage", "HLSRateDidChangeMessage.makeNotification"]` |
| 1.4 | `["SystemQualityClock", "SystemClock"]` — planted symbol names from the manifest's source_type ("SystemQualityClock ↔ SystemClock"). See §3.5a below for the explicit handling procedure. |
| 1R | `["MetricRow"]` — the planted struct, present in both canonical clusters |
| 2.1 | `["MainActorNotificationMessage", "AsyncNotificationMessage"]` |
| 2.2 | `["HLSAVPlayerProtocol", "PlayerProtocol"]` (RadioPlayerProtocol references HLSAVPlayerProtocol — pick the more specific) |
| 2.3 | `["AudioPlayerProtocol", "AudioEnginePlayerProtocol", "MockAudioPlayerForController"]` |
| 2.4 | `["AudioEnginePlayerProtocol", "AudioPlayerProtocol"]` (overlaps with 2.3; check for over-broad matches in §5) |
| 2R | `["_Plant_MockAsyncNotificationMessage", "AsyncNotificationMessage"]` — needs the _Plant_ prefix for the restraint signal |
| 3.1 | `["HSBColor.init(hue:saturation:brightness:)", "AccentColor.init", "HSBOffset.init"]` |
| 3.2 | `["MaterialBlendMode.displayName", "MaterialBlendMode.blendMode"]` |
| 3.3 | `["FFTProcessor.reset", "FFTProcessor.setNormalizationMode"]` |
| 3.4 | `["PlaylistEntry", "Talkset.init", "Breakpoint.init", "_Plant_Announcement.init", "Announcement.init"]` |
| 3R | `["Breakpoint.stub", "Talkset.stub", "_Plant_PlaycutStub", "PlaylistStubs"]` |
| 4.1 | `["NowPlayingItem", "PlaycutSelection"]` |
| 4.2 | `["_Plant_ShowContainer", "ShowContainerProtocol"]` |
| 4.3 | `["_Plant_ArtistRepository", "ArtistRepository"]` |
| 4.4 | `["_Plant_CacheLoader", "_Plant_MetadataLoader", "CacheLoader"]` |
| 4R | `["MockStructuredAnalytics", "PlaybackStartedEvent", "CPUSessionEventProxy"]` |
| 5.1 | `["HSBColor.uiColor", "HSBColor.nsColor"]` |
| 5.2 | `["_Plant_GenericFetcher", "GenericFetcher.fetchInt", "GenericFetcher.fetchString"]` |
| 5.3 | `["AsyncNotificationMessageSequence.AsyncIterator.init", "MainActorNotificationMessageSequence.AsyncIterator.init"]` |
| 5.4 | `["_Plant_IntCache", "_Plant_StringCache", "IntCache", "StringCache"]` |
| 5R | `["Breakpoint.stub", "Talkset.stub", "_Plant_PlaycutStub", "PlaylistStubs"]` — same as 3R (cross-lens restraint) |

These drafts will be refined during implementation by checking that EVERY cluster currently bound to a plant under round-1 closeout's rule still binds under the new rule (modulo the intentional drops for 3.1 / 5.1 / 1R). See §5.7 for the validation script.

### 3.5a Plant 1.4 handling (explicit procedure)

Plant 1.4 has zero current clusters under the round-1 closeout rule (an existing known limitation documented in `results.md` §8). The validator requires a non-empty `expected_cluster_symbols` list, so the plant gets populated with `["SystemQualityClock", "SystemClock"]` (the planted symbol names) even though no current cluster will satisfy the gate. The chosen strategy:

1. **Manifest population step (step 3)**: write `expected_cluster_symbols: ["SystemQualityClock", "SystemClock"]` for Plant 1.4. The validator passes.
2. **Post-regeneration audit step (step 7)**: confirm Plant 1.4's bound-cluster count remains 0 under the new rule. If it does (expected), the §8 known limitation persists unchanged.
3. **If Plant 1.4 unexpectedly surfaces ≥1 cluster** (i.e., another plant's clusters leaked across via the broad symbol names): investigate immediately during step 7. Either tighten the symbols (drop "SystemClock" if it leaks) or document as a finding.
4. **If Plant 1.4 surfaces zero clusters** (expected): no further action this round. Note in `rubric-modifications.md` that this plant's symbols are pre-populated but not exercised by the current corpus; round-3 substrate work or manifest re-survey can address.

Rejected alternative: adding an `expected_cluster_symbols_validator_exception: true` flag would introduce special-case logic the validator has to maintain. Pre-populating with the planted symbol names is internally consistent with the other 24 plants and lets the validator stay simple.

### 3.6 Pre-registration discipline (methodology §10)

Methodology §10 item 3 says "Post-hoc rubric modifications allowed but documented" in a `rubric-modifications.md` file. This will be the first such modification; create the file with:

```markdown
# V7 rubric modifications

A running log of post-hoc edits to the manifest, rubric, or scoring rules per methodology §10. Each entry: **Change**, **Why**, **Expected impact**, **Prior results affected**. Future rounds append entries in chronological order; do not modify earlier entries.

## Round 2 — symbol-level binding (2026-05-18)

**Change.** Added `expected_cluster_symbols` field per plant in `plant-manifest.yaml`. Non-empty list of literal substrings the cluster_id must contain for a binding to be valid.

**Why.** Round-1 closeout (PR #84) added a prefer-signal-match rule that cleaned 24 incidental false bindings but didn't fix the panel-routed Plant 3.1 / 5.1 co-binding (both plants share function-duplicates signal AND HSBColor.swift source file) or Plant 1R's structural FPR (16 incidental DebugMetricsProvider clusters substring-match DebugHUD.swift). Both gaps converge on cluster_id-symbol gating.

**Expected impact.** panel_routed: 12 → 6. Plant 1R FPR: 1.0 → 0.0 per cell. Headline 1−FPR: 0.800 → 1.000. canonical_recall: unchanged. See [`plans/v7-round2-symbol-matching-plan.md`](../plans/v7-round2-symbol-matching-plan.md) §3.4.

**Prior results affected.** Round 1's panel scores in `panel-scores-reviewer-1.jsonl` no longer fully map to the new `panel-routing.jsonl` — the 6 Plant 3.1 rows become orphan tokens (handled by `promote_panel_scores` as a skip-with-note). Details and remediation in `results.md` §4.2 (post-round-2 revision) and `reproducibility.yaml::execution.round2_methodology_update`.
```

## 4. TDD plan

### 4.1 New tests in `test_score_all.py::BindRecsToPlantsTests`

1. `test_symbol_gate_blocks_incidental_bindings` — Plant 1R-shaped: source_file matches, no symbol matches → no binding. Mirrors the DebugMetricsProvider incidental case.
2. `test_symbol_gate_admits_legitimate_binding` — Plant 1R-shaped: source_file matches AND symbol matches → binding fires. The canonical MetricRow case.
3. `test_symbol_disambiguates_shared_source_file` — Plant 3.1 vs 5.1: both have HSBColor.swift; cluster contains "HSBColor.uiColor" → only 5.1 binds (3.1's init symbols not in cluster_id).
4. `test_symbol_gate_with_empty_signals_falls_back_to_substring` — round-1 closeout's empty-signal-list fallback is preserved when symbol_matches is non-empty.
5. `test_no_symbol_match_no_binding` — cluster substring-matches but symbol_matches is empty for every candidate → rec goes to unmatched.
6. `test_cross_lens_restraints_both_bind` — Plants 3R and 5R both list the PlaylistStubs symbols (`Breakpoint.stub`, `Talkset.stub`); a cluster containing one of those symbols binds to both plants (sorted plant_id list). Verifies the cross-lens restraint case identified in §7 R3.

### 4.2 New tests in `test_validator.py`

The existing validator tests follow a fixture-corruption pattern (e.g., `corrupt_rule_2_total`, `corrupt_rule_4_category` in `test_validator.py`): start from a valid manifest dict, mutate one field per fixture, run the validator, assert the specific error fires. Mirror that pattern for the new field:

1. `test_empty_expected_cluster_symbols_fails_validation` — `expected_cluster_symbols: []` rejected with "must be non-empty".
2. `test_missing_expected_cluster_symbols_fails_validation` — manifest entry without the field rejected with "missing required field".
3. `test_non_string_entries_fail_validation` — `expected_cluster_symbols: ["valid", 42]` rejected with "entries must be strings".
4. `test_null_expected_cluster_symbols_fails_validation` — `expected_cluster_symbols: null` rejected (caught alongside the missing-field case but listed separately so the rejection message is verified).
5. `test_non_list_expected_cluster_symbols_fails_validation` — `expected_cluster_symbols: "MetricRow"` (string instead of list) and `expected_cluster_symbols: {"primary": "MetricRow"}` (dict) both rejected with "must be a list".
6. `test_empty_string_entry_fails_validation` — `expected_cluster_symbols: [""]` rejected (an empty string substring-matches every cluster_id, defeating the gate).

Each test constructs a fresh corruption fixture by deep-copying the working manifest and mutating only the field under test. Mirrors `_find_canonical(doc["plants"])[...]` from existing tests at `test_validator.py:236`.

### 4.3 Test fixture update

Two fixture changes across two test files, kept in sync but logically separate:

- **`test_score_all.py::_plant` helper** gets an `expected_cluster_symbols: list[str] | None = None` parameter. Default: if `None`, populate as `["A"]` (a substring of the default `_rec(cluster_id="exact-duplicates:Pkg/Sources/A.swift+...")` so existing `BindRecsToPlantsTests` tests continue to bind through the new symbol gate). Uses the same `is None` check as `expected_substrate_signals` (see `test_score_all.py:48`) so explicit empty lists are preserved.
- **`test_score_all.py::test_runs_on_synthetic_corpus` CLI smoke test** has an inline YAML manifest at lines 786–798. Add `expected_cluster_symbols: ["A"]` to the plant entry (parallel to how `expected_substrate_signals: ["exact-duplicates"]` was added during the round-1 closeout).
- **`test_validator.py` baseline fixture** — the working manifest dict the corruption helpers (`corrupt_rule_*`) start from. This is independent of `test_score_all.py::_plant`. Add `expected_cluster_symbols: ["valid-symbol"]` to the baseline plant entries so the existing "should-pass" tests still pass after the validator gains the new rule.

The two `_plant`-style helpers in the two test files are intentionally separate because the validator tests exercise full schema correctness while the binding tests exercise just the bind logic — coupling them would force the binding helper to construct full validator-compliant plants, which is unnecessary overhead.

## 5. Implementation sequencing

1. Branch from `experiment/swift-substrate` (already done — this worktree is `v7-round2-symbol-matching`).
2. **Validator first** — extend `validate-manifest.py` to require non-empty `expected_cluster_symbols` per plant; add `test_validator.py` cases.
   - Important sequencing note: step 2 only modifies `validate-manifest.py` and `test_validator.py`. The validator is NOT yet run against the real `plant-manifest.yaml` (which still lacks the field) — that happens in step 3. The unit tests in step 2 use synthetic fixtures so they pass independently. The `test_validator.py` baseline fixture (the valid manifest mutated by corruption helpers) also gets `expected_cluster_symbols: ["valid-symbol"]` added so the existing "should-pass" tests continue to pass.
3. **Populate the manifest** — add `expected_cluster_symbols` to all 25 plants per §3.5. Then run `validate-manifest.py` against the real manifest to confirm clean.
4. **bind_recs_to_plants update** — add the symbol gate per §3.3; add the 5 new tests per §4.1. TDD: failing test → implementation → green.
5. **Update `_plant` helper and CLI smoke-test fixture** — add the new field.
6. **Run full pytest suite** — confirm all tests pass.

7. **Validate symbol enumeration** (NEW). Before regenerating analyses, run this validation script to confirm every plant's drafted symbols appear in at least one cluster currently bound to that plant under round-1 closeout's rule:

   ```python
   import json, yaml
   from collections import defaultdict

   with open('analyses/auto-scores.json') as f:
       scored = json.load(f)
   with open('plant-manifest.yaml') as f:
       plants = yaml.safe_load(f)['plants']

   clusters_per_plant = defaultdict(set)
   for r in scored['scored']:
       clusters_per_plant[r['plant_id']].add(r['cluster_id'])

   for plant in plants:
       pid = plant['plant_id']
       syms = plant.get('expected_cluster_symbols') or []
       current_clusters = clusters_per_plant[pid]
       if not current_clusters:
           print(f"INFO: Plant {pid}: 0 current clusters (expected: {pid == '1.4'})")
           continue
       matched_syms = [s for s in syms if any(s in c for c in current_clusters)]
       if not matched_syms:
           print(f"WARN: Plant {pid}: NONE of its symbols appear in any current cluster_id")
           print(f"  symbols: {syms}")
           print(f"  sample cluster: {next(iter(current_clusters))[:120]}")
       elif len(matched_syms) < len(syms):
           unused = [s for s in syms if s not in matched_syms]
           print(f"INFO: Plant {pid}: {len(unused)}/{len(syms)} symbols don't appear in any current cluster: {unused}")
   ```

   Acceptance: zero `WARN` lines. `INFO` lines for Plant 1.4 (expected) and for any plant with redundant symbols (acceptable — defense-in-depth for future cluster shapes). Adjust symbol drafts iteratively until validation passes.

8. **Regenerate analyses/** — run `score_all.py` against the parsed cache. Spot-check verification:
   - `panel_routed.size == 6` (Plant 5.1 only; Plant 3.1 entries dropped).
   - Plant 1R binding count: `18 → 2` (canonical MetricRow clusters only); per-cell FPR for extract-to-common drops from 1.0 to 0.0.
   - Plant 1.4 binding count stays at 0 (audit per §3.5a step 2).
   - If Plant 1R binding count differs from the projected 2 (e.g., the `MetricRow` symbol also appears in a non-canonical cluster_id), investigate the delta and document in `rubric-modifications.md`.
   - If Plant 1.4 surfaces ≥1 cluster, follow §3.5a step 3.
9. **rubric-modifications.md** — create per §3.6.
10. **Update `results.md`** — §4.1 (drop Plant 1R FPR caveat — now resolved), §4.2 (drop panel-routed binding-artifact caveat — now resolved), §8 (drop both known limitations; add a single line about cluster_id-symbol gating).
11. **Update `reproducibility.yaml`** — fresh `manifest_hash`, `round2_methodology_update` block under `execution`.
12. **Local CI** (lint + pytest).
13. **Push, open PR with `Closes #86`.**

## 6. Acceptance criteria

- [ ] Every plant has non-empty `expected_cluster_symbols` (validator enforces).
- [ ] `validate-manifest.py` rejects empty/missing/non-string entries with clear error messages; tests in `test_validator.py` cover each.
- [ ] `bind_recs_to_plants` symbol gate per §3.3; 5 new tests in `test_score_all.py::BindRecsToPlantsTests` pass.
- [ ] Full `pytest experiments/v7-refactor-recommendation/` passes (114 tests + 5 subtests + new tests).
- [ ] `analyses/auto-scores.json`, `analyses/score-summary.json`, `analyses/panel-routing.jsonl`, `analyses/panel-unblind.json` regenerated.
- [ ] Verified: `panel_routed.size == 6` (Plant 5.1 entries only); Plant 1R per-cell FPR `== 0.0` for both S1 and S2 across all trials; `canonical_recall` unchanged at S1=0.270 / S2=0.615; headline 1−FPR `== 1.000` in both conditions.
- [ ] **If Plant 1.4 surfaces ≥1 cluster during step 8 regeneration** (unexpected — see §3.5a): halt before pushing. Investigate whether symbols leaked into another plant's clusters; tighten or remove entries; re-run step 8 until Plant 1.4 binding count is 0 OR until the leak is documented as a finding worth shipping. Do not merge with an unresolved Plant 1.4 leak.
- [ ] **If Plant 1R binding count differs from the projected 2** (the `MetricRow` symbol may appear in non-canonical cluster_ids): document the delta in `rubric-modifications.md` before pushing. If the delta keeps Plant 1R's FPR > 0, treat as a substantive finding and consider tightening the symbol list (e.g., `["MetricRow.body", "MetricRow.init"]` instead of bare `"MetricRow"`).
- [ ] `rubric-modifications.md` created per §3.6.
- [ ] `results.md` §4.1, §4.2, §8 updated; `reproducibility.yaml` `round2_methodology_update` block added.

## 7. Risks and mitigations

- **R1: A drafted symbol is too narrow and drops a legitimate cluster.** Mitigation: during implementation step 7, compare the per-plant binding counts before and after for every plant; investigate any drops beyond the intentional ones. The §3.1 inventory pins the expected before-state.
- **R2: A drafted symbol is too broad and binds non-plant clusters.** Mitigation: same comparison step. If a plant's binding count INCREASES, the symbol leaked into a query type the plant doesn't intend to claim.
- **R3: Cross-lens restraints (Plants 3R / 5R both pointing at PlaylistStubs).** Both list the same symbols; both will bind to the same clusters. Methodology §9 already addresses this — both plants score identically on any given rec. No special handling needed in the binding rule.
- **R4: Orphan tokens after panel-routing regenerates.** The 6 Plant 3.1 panel scores from PR #82's `panel-scores-reviewer-1.jsonl` will not match any rec_token in the new `panel-routing.jsonl`. `promote_panel_scores` already handles unmatched tokens gracefully (silently skips). Document in rubric-modifications.md.
- **R5: Plant 1.4 still surfaces zero clusters; validator might force a symbol list anyway.** Per §3.5 the proposed mitigation is to populate Plant 1.4 with the planted symbol names (even if no clusters surface), keeping the manifest internally consistent. Round-2 substrate work can address whether the plant should be re-placed.

## 8. Implementation notes (from review)

Plan-review notes worth carrying into implementation:

- **`validate-manifest.py::KNOWN_KEYS`**: when extending the validator in step 2, add `"expected_cluster_symbols"` to the `KNOWN_KEYS` set (~line 78–96) so the new field doesn't trigger benign "unknown field" warnings.
- **Helper sync**: add a `# SYNC: changes to this helper must be mirrored in <other test file>'s helper` comment to both `test_score_all.py::_plant` and `test_validator.py`'s baseline-builder when modifying either, so a future edit to one is flagged at the other.
- **WARN recovery in step 7**: if a `WARN` fires during the symbol-enumeration audit, re-examine §3.1's inventory for that plant (filter `analyses/auto-scores.json::scored` by hand on `plant_id`); if the inventory is accurate, the drafted symbols are too narrow — broaden or check spacing/case. If the inventory was incomplete, update §3.1 and re-draft.
- **Results.md §8 note for Plant 1.4**: if it continues to surface zero clusters, add the line "Plant 1.4 is pre-populated with `expected_cluster_symbols` per methodology §10 discipline, but remains unexercised by the current corpus — round-3 substrate work can re-place or replace it."
- **Step 8 verification commands**:
  - `jq '[.tokens | to_entries[] | select(.value.cluster_id | contains("HSBColor.uiColor"))] | length' analyses/panel-unblind.json` — count Plant 5.1 panel routings (expect 6).
  - `jq '[.scored[] | select(.plant_id=="1R")] | length' analyses/auto-scores.json` — count Plant 1R bindings (expect ~2 × 6 cells = 12 if both canonical clusters present in every cell, or smaller if not).
  - `jq '.per_category_per_cell.s1.["1"].["extract-to-common"].restraint_fpr' analyses/score-summary.json` — Plant 1R FPR for one cell (expect 0.0; previously 1.0).
