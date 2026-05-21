# V7 Round 2 — value-aware specifics matching (resolves #35)

> Round-2 follow-up to symbol-level binding (PR #89, [`v7-round2-symbol-matching-plan.md`](v7-round2-symbol-matching-plan.md)). The auto-scorer in `auto-scorer.py` currently performs key-only specifics matching, leaving methodology §8's panel-routing rule for "specifics fall outside tolerance" un-fired. This plan adds verbatim value comparison and routes value-mismatch cases to panel per methodology §8 lines 626–631. The change is pre-registered via `rubric-modifications.md` per methodology §10.

## 1. Context and motivation

The auto-scorer's [docstring §39–49](../experiments/v7-refactor-recommendation/auto-scorer.py) is explicit about the MVP gap: "Specifics matching is KEY-ONLY, not value-aware. A recommendation with correct keys but wrong values (e.g., `new_protocol: "Wrong"`) will score 1.0 here." The `specifics_tolerance` per-plant boolean flags (29 distinct keys across the 25 plants) are entirely unread by the scorer.

Methodology §8's panel-routing decision rule (lines 626–631) is unambiguous:

> Auto-scoring handles four cases: (1) `category` matches `primary_answer.category` AND `specifics` within tolerance → score per the canonical rubric; … Everything else routes to panel:
> - `category` matches `primary_answer.category` but `specifics` fall outside tolerance
> - `category` matches an alternative but specifics fall outside tolerance

The current scorer fires 1.0 (primary_match_full) when category matches and all required *keys* are present, regardless of whether the *values* match the manifest's pre-registered `primary_answer.specifics`. This over-credits agents whose specifics align in shape but disagree in content, and silently bypasses the §8 panel-route for "specifics fall outside tolerance."

Issue #35 raised three open design questions about how to evaluate `specifics_tolerance` flags structurally. After re-reading §8, the answer is that the auto-scorer is **not supposed to evaluate them structurally**: §8 routes out-of-tolerance specifics to the panel. The flags are panel guidance, not scorer inputs. This sidesteps issue #35's option (a) (per-flag handler code, brittle) and option (b) (restructure 25 plants' tolerance schemas) entirely — the scorer's job per §8 is binary tolerance detection (panel-route on mismatch), not tolerance evaluation.

## 2. Scope

In one PR against `experiment/swift-substrate`:

- **`auto-scorer.py` `score_recommendation()` update**: when `category` matches primary, compare `recommendation.specifics[key]` against `plant.primary_answer.specifics[key]` for each `key` in the rubric's `specifics_schemas[category].required` set. Verbatim equality (lists compared as sets, dicts compared structurally, scalars compared `==`). Any mismatch → panel-route with new match label `primary_match_specifics_outside_tolerance` and notes enumerating the mismatched fields plus the plant's `specifics_tolerance` flags.
- **Missing-keys path also panel-routes**: change `primary_category_wrong_specifics` (currently 0.5) to panel-route, renamed `primary_match_specifics_missing_keys` for label parallelism with the new `primary_match_specifics_outside_tolerance`. The §8 routing rule's "outside tolerance" bucket covers both "wrong values" and "missing required keys" (which is the most outside-tolerance case possible). Panel applies §8 table's 0.5 row if appropriate.
- **`rubric-modifications.md` append**: round-2 entry per methodology §10, documenting the change, the methodology §8 lines it operationalizes, expected impact on the round-2 score distribution, and pre-registered fixture updates.
- **`auto-scorer.py` fixture updates**: existing `SYNTHETIC_FIXTURES[0]` (`primary_category_wrong_specifics: Plant 4.1, missing 'replaces' key`) flips `expected_score` from 0.5 to `PANEL_ROUTE` and `expected_match` from `"primary_category_wrong_specifics"` to `"primary_match_specifics_missing_keys"`. Add a new synthetic fixture for `primary_match_specifics_outside_tolerance` (correct keys + wrong values). §20.1–20.5 worked examples preserved (their values all match the manifest verbatim).
- **`auto-scorer.py` docstring update**: drop the MVP-scope caveat about key-only matching; document the new value-comparison semantics.
- **`score_all.py` integration**: confirm the panel-routing pipeline (`promote_panel_scores`, `attach_panel_kappa`, `attach_collapsed_panel_kappa`) handles the new `primary_match_specifics_outside_tolerance` and reclassified-from-0.5 `primary_match_specifics_missing_keys` match labels identically to existing panel-route paths. No new pipeline branches needed — these are just additional reasons to panel-route, and the existing `panel-routing.jsonl` writer is match-label-agnostic.
- **Regenerate `analyses/`** against the new scorer. Document the score-distribution shift in `rubric-modifications.md` per the same template used for symbol-matching (expected vs actual table). **Empirical projection ran 2026-05-19 against the merged round-2 data** (see §3.3 below). Headline numbers:
  - **All 102 rows in the (primary_match_full ∪ primary_match_weak_rationale) pool flip.** 100% flip rate.
  - `primary_match_full` (currently 37) → 0 unless I'm missing something (every row had at least one value mismatch). All 37 become panel-route.
  - `primary_match_weak_rationale` (currently 65) → 0 similarly. All 65 become panel-route.
  - `panel_routed.size` (currently 6): 6 → ~108 (current 6 + 37 + 65 = 108). Note: I'll re-confirm during implementation; might be 102 + 6 if `weak_rationale_panel_policy` overlap.
  - `headline.canonical_recall`: numerator drops by 37 × 1.0 + 65 × 0.5 = 69.5; recall denominators per-plant are unchanged but per-plant numerators drop hard. **Empirical estimate**: S1 0.270 → ~0.05, S2 0.615 → ~0.10. These numbers will need explicit framing in `results.md` and `rubric-modifications.md` as "round 1 was over-crediting; this is the corrected number."
  - `headline.one_minus_fpr`: unchanged (restraint plants don't go through this path).
  - Mismatch breakdown (from §3.3 projection): 97 substantive (~95%; e.g., Plant 1.1 agent recs `target_package: "app:iOS"` when manifest says `"Shared/UI or a new Shared/Branding (must be upstream of both app:WatchXYC and app:iOS)"`), 5 trivial (~5%; Plant 3.4 manifest's parenthetical `"PlaylistEntry (already exists in Shared/Playlist)"` vs rec's `"PlaylistEntry"`).
- **Update `results.md`**: §4 (auto-scoring numbers shift), §8 (drop the round-1 limitation entry about value-aware matching, replace with a round-2 entry about the §8 routing rule operationalization and panel-load surge), TL;DR (revised recall numbers).
- **Update `reproducibility.yaml`**: bump `manifest_hash`, append a `round2_methodology_update_value_aware_specifics` block under `execution` describing the rubric-modifications.md addition.
- **Update `panel-instructions.md`**: §1 (panel routes now include "specifics outside tolerance" cases), add a §1.bis subsection on how panel applies `specifics_tolerance` flags when reviewing `primary_match_specifics_outside_tolerance` rows.

### 2.1 Downstream consumer audit (HIGH finding from /review-plan)

Grep of `primary_category_wrong_specifics` across `experiments/`, `plans/`, `docs/` returns five occurrences (audited 2026-05-19):

| Location | Role | Action |
|---|---|---|
| `auto-scorer.py:270` | Emit site (the `ScoreResult` construction) | Rename string to `primary_match_specifics_missing_keys`; change `0.5` to `PANEL_ROUTE`; add `_tolerance_flag_notes(plant)` to notes. |
| `auto-scorer.py:532` | Intro comment for SYNTHETIC_FIXTURES listing exercised match labels | Update label list; add `primary_match_specifics_outside_tolerance` to the exercised set. |
| `auto-scorer.py:543` | Fixture label string | Rename to `[synthetic] primary_match_specifics_missing_keys: Plant 4.1, missing 'replaces' key`. |
| `auto-scorer.py:556` | Fixture `expected_match` value | Change to `"primary_match_specifics_missing_keys"`; flip `expected_score` to `PANEL_ROUTE`. |
| `rubric.yaml:33` | Comment explaining §8 → match-label mapping | Update comment to cite the new label. |

`score_all.py`, `analyses/panel-instructions.md`, `analyses/score-summary.json`'s structure, and the `results.md` corpus do **not** reference the string `primary_category_wrong_specifics` — only the prose category "Primary-category match with specifics out of tolerance" (which is conceptual, not a code identifier). The panel-routing pipeline (`promote_panel_scores` and friends) keys off the `score` field (numeric vs `PANEL_ROUTE` sentinel), not the `match` field, so the relabeling is local to `auto-scorer.py` and `rubric.yaml`. Strategy: **rename in place; no dual-path needed**.

**Out of scope here:**
- Structured tolerance schema (issue #35 option (b)). The methodological argument above is that this isn't needed — §8 routes to panel, the panel evaluates flags. If a future round wants the scorer to auto-handle some flags (e.g., `*_named_X_or_synonym` as a regex/enum check), that's a separate plan.
- Manifest tolerance flag normalization (the 29 stringly-typed keys remain as-is; they're panel guidance, not scorer-readable rules).
- Plant 1.4 / 5.4 placement diagnostics (B2 — separate work).
- Round-2 panel sitting (still depends on #85).
- Recommendation-text normalization (case-folding, whitespace trimming, parenthesized-commentary stripping). Strict verbatim comparison; if normalization is needed, follow-up plan.

## 3. Design

### 3.1 Helper: `_specifics_values_match`

```python
def _specifics_values_match(
    rec_specifics: dict, primary_specifics: dict, required_keys: list[str]
) -> tuple[bool, list[str]]:
    """Verbatim value comparison for each required key.

    Scalars: == equality. Lists: set equality (order-independent; each element
    must be == to a manifest element). Dicts: structural == (recursive). Type
    mismatches (e.g., manifest expects list, rec provides string) are mismatches.

    Returns (ok, problem_descriptions). problem_descriptions is a list of
    `"key={key} manifest={manifest_val!r} rec={rec_val!r}"` strings for each
    mismatched key. Type mismatches are surfaced through the `!r` repr — no
    special-case "type mismatch" phrasing is emitted; the repr makes the type
    difference visible (e.g., `manifest=['TrackContainer', 'ShowContainer']
    rec='TrackContainer'` is unambiguous about list-vs-string).

    Precondition: caller has confirmed all required keys are present in
    rec_specifics (via _specifics_keys_match). Missing keys are not this
    function's concern.
    """
```

The `set equality on lists` rule is important: Plant 4.1's `replaces: ["TrackContainer", "ShowContainer"]` should still match if the agent emits `["ShowContainer", "TrackContainer"]`. Element-wise `==` (no recursive normalization); for nested lists/dicts inside list elements, use recursive structural ==.

### 3.2 Decision flow inside `score_recommendation()` Case 1 (primary match)

The specifics checks (keys then values) are evaluated before the rationale check; any specifics problem routes to panel regardless of rationale grounding. This ordering preserves the methodology §8 routing rule: out-of-tolerance specifics route to panel before the rationale-grounding distinction can fire.

Replace lines 242–272 of `auto-scorer.py` (current Case 1) with:

```python
if rec_cat == primary_cat:
    primary_specifics = primary.get("specifics") or {}
    keys_ok, key_problems = _specifics_keys_match(
        rec_specifics, primary_specifics_required
    )
    if not keys_ok:
        return ScoreResult(
            plant_id, PANEL_ROUTE, "primary_match_specifics_missing_keys",
            notes=key_problems + _tolerance_flag_notes(plant),
        )
    values_ok, value_problems = _specifics_values_match(
        rec_specifics, primary_specifics, primary_specifics_required
    )
    if not values_ok:
        return ScoreResult(
            plant_id, PANEL_ROUTE, "primary_match_specifics_outside_tolerance",
            notes=value_problems + _tolerance_flag_notes(plant),
        )
    # Values match verbatim — existing 1.0 / 0.5-weak-rationale path.
    grounded, missing_citations = _rationale_cites_all(rec_rationale, must_cite)
    if grounded:
        return ScoreResult(
            plant_id, 1.0, "primary_match_full",
            notes=["all conditions met"],
        )
    policy = rubric.get("weak_rationale_policy", "auto-score-0.5")
    if policy == "auto-score-0.5":
        return ScoreResult(
            plant_id, 0.5, "primary_match_weak_rationale",
            notes=[f"missing required citations: {missing_citations}"],
        )
    return ScoreResult(
        plant_id, PANEL_ROUTE, "primary_match_weak_rationale_panel",
        notes=[
            f"missing required citations: {missing_citations}",
            f"weak_rationale_policy={policy}",
        ],
    )
```

### 3.3 Pre-implementation impact projection

To tighten the §2 estimates ("~half of primary_match_full flips"), run a one-time **dry projection** before code lands:

1. Add a temporary `--project-value-mismatches` flag to `auto-scorer.py` (drops after PR lands; not committed) that loops over every parsed recommendation and reports, per row, whether `rec.specifics` values verbatim-match `plant.primary_answer.specifics` values, grouped by plant_id.
2. Generate the count: how many currently-1.0 / currently-0.5-weak-rationale rows would flip to panel-route.
3. **Classify each flip by cause**:
   - **Substantive mismatch** — different identifier names, different file paths, different list members (e.g., `new_protocol: "TotallyWrong"` vs manifest `"Container"`).
   - **Trivial mismatch** — whitespace differences, trailing punctuation, case-only differences, manifest-side parenthesized commentary that the agent legitimately omitted (e.g., manifest `target_package: "Shared/Branding (already upstream of app:iOS and app:Mac)"` vs rec `target_package: "Shared/Branding"`).
4. **Decision gate** — apply this threshold:
   - If **trivial-mismatch flips ≤ 30%** of the (1.0 + 0.5-weak) row pool: merge as-is. The panel will judge the substantive-mismatch rows per §8 tolerance; the small trivial-mismatch fraction is acceptable overhead.
   - If **trivial-mismatch flips > 30%** of the pool: stop. File a separate normalization-pre-pass issue (manifest cleanup OR scorer-side strip-parenthesized-commentary helper) and don't merge this PR until normalization lands or the manifest is cleaned. Trivial-mismatch dominance indicates the manifest's prose-rich values aren't structured-equal-comparable; fixing the scorer alone would just push the noise to the panel.
   - 30% is chosen as the threshold because panel cost scales roughly with panel-row count; the round-2 panel is already at 6 rows post-symbol-matching, so a 10× growth to ~60 rows is acceptable but ~100 rows would be operationally painful. Trivial-mismatch fraction is the controllable lever.
5. **Update §2 estimates** with empirical numbers (replace "~half" / "~30 flip" with measured counts).
6. **Record the projection in the implementation PR's commit message** so the empirical gate decision is auditable.

This projection runs against round-2's already-merged data and doesn't require regenerating analyses. Result goes in the plan's §3.3 table here, and the implementation PR's commit message cites the empirical numbers.

#### 3.3.1 Projection results (ran 2026-05-19)

Pool: 102 rows (`primary_match_full` n=37, `primary_match_weak_rationale` n=65).

| Classification | Count | Pct of pool | Notes |
|---|---|---|---|
| Substantive | 97 | 95.1% | Agent picked wrong identifier, wrong target package, wrong protocol name, or omitted required value (e.g., `type_params.constraint = null` where manifest expects `"Decodable"`). Methodologically these are exactly the §8 "specifics fall outside tolerance" cases. |
| Trivial | 5 | 4.9% | All 5 are Plant 3.4 rows where the manifest's `protocol: "PlaylistEntry (already exists in Shared/Playlist)"` and `target_location: "Shared/Playlist/.../PlaylistEntry.swift (extension PlaylistEntry where Self: Decodable)"` carry parenthetical commentary that the agent's `"PlaylistEntry"` and bare path don't include. |
| No-flip | 0 | 0% | Every row had at least one mismatched required key. |

**Gate decision**: 4.9% trivial ≪ 30% threshold → **PROCEED**.

Per-plant flip distribution (most-flipped first): Plant 1.1 (15 substantive, target_package + type_name), Plant 3.4 (10 substantive + 5 trivial), Plant 3.3 (14 substantive, protocol invented), Plant 3.2 (12 substantive, protocol invented), Plant 5.2 (9 substantive, agent unconstrained T), Plants 2.3/2.4 (6 each), Plants 2.1/2.2/4.2/4.3/4.4/5.3/5.4 (3 each), Plants 3.1/4.1 (2 each).

Substantive examples (one per plant family):
- **Plant 1.1** (extract-to-common, target_package): manifest `"Shared/UI or a new Shared/Branding (must be upstream of both app:WatchXYC and app:iOS)"`; rec `"app:iOS"`. Agent chose the consumer as the lift target — would create a downstream-of-self dependency. Real wrong-specifics.
- **Plant 3.2** (default-implementation, protocol): manifest `"BlendMode (new shared protocol over the 16-case union, with displayName + blendMode requirements)"`; rec `"BlendModeConvertible"`. Agent invented a different protocol name. Substantive — the panel will judge whether the alternative name is acceptable per the tolerance flag `default_impl_must_be_in_protocols_own_package`.
- **Plant 3.3** (default-implementation, protocol): manifest `"AudioProcessor (already exists in PlayerHeaderView)"`; rec `"NormalizationModeConfigurable"`. Agent invented a new protocol instead of using the existing one — semantically wrong per the tolerance flag `protocol_must_be_existing_AudioProcessor`.
- **Plant 5.2** (generic-parameterization, type_params): manifest `[{name: "T", constraint: "Decodable"}]`; rec `[{name: "T", constraint: null}]`. Agent omitted the constraint; methodology cares because the tolerance flag `type_param_must_be_constrained_to_Decodable_or_codable_kin` says T must be constrained.

All substantive examples are exactly the cases methodology §8 says belong on panel review.

### 3.4 Format of `_tolerance_flag_notes()`

```python
def _tolerance_flag_notes(plant: dict) -> list[str]:
    """Render `specifics_tolerance` flags as panel-guidance notes.

    Returns a list of "tolerance_flag: {key}={value}" strings, one per flag,
    sorted by key. Empty list if the plant has no tolerance flags. Output
    sorted for byte-stability in panel-routing.jsonl.
    """
    tol = plant.get("specifics_tolerance") or {}
    return [f"tolerance_flag: {k}={tol[k]}" for k in sorted(tol.keys())]
```

These notes give panel reviewers the manifest's pre-registered tolerance flags inline with the routing reason, so they don't need to cross-reference plant-manifest.yaml.

### 3.5 Worked-example regression check

§20.1, §20.2, §20.3 in methodology.md (and the corresponding `WORKED_EXAMPLES[0..2]` fixtures in `auto-scorer.py`) use Plant 4.1's INLINE_PLANTS entry. Their specifics:

- §20.1 / `WORKED_EXAMPLES[0]`: rec emits `{new_protocol: "Container", associated_type: "Item", constraints: [], replaces: ["TrackContainer", "ShowContainer"]}`. Manifest INLINE_PLANTS[4.1-s8-example]: `{new_protocol: "Container", associated_type: "Item", constraints: [], replaces: ["TrackContainer", "ShowContainer"]}`. **Verbatim match.** Expected score remains 1.0.
- §20.2 / `WORKED_EXAMPLES[1]`: same specifics as §20.1. **Verbatim match.** Expected score remains 0.5 (weak rationale).
- §20.3 / `WORKED_EXAMPLES[2]`: alternative-answer match, doesn't go through primary-match path. Unaffected.
- §20.4 / `WORKED_EXAMPLES[3]`: restraint plant, doesn't go through primary-match path. Unaffected.
- §20.5 / `WORKED_EXAMPLES[4]`: `category == "other"`, routes to panel before specifics check. Unaffected.

The §20 worked examples remain green under the new scorer — confirming that methodology authors picked verbatim-matching values when authoring the rubric. The synthetic fixture for `primary_category_wrong_specifics` (missing key) is the only existing fixture that flips expected behavior; one new synthetic fixture (`primary_match_specifics_outside_tolerance`, correct keys + wrong values) is added.

## 4. Test plan

Adds tests in `test_score_all.py` (or `test_auto_scorer.py` if one exists — check during impl; otherwise extend `test_score_all.py`'s scoring-related classes):

1. **`primary_match_full` preserved on verbatim match**: rec.specifics deep-equals plant.primary_answer.specifics → score 1.0 (regression).
2. **`primary_match_specifics_outside_tolerance` on scalar mismatch**: rec emits `new_protocol: "Wrong"` vs manifest `new_protocol: "Container"` → panel_route with notes citing the mismatched field.
3. **`primary_match_specifics_outside_tolerance` on list-element mismatch**: rec emits `replaces: ["TrackContainer", "Other"]` vs manifest `["TrackContainer", "ShowContainer"]` → panel_route.
4. **List set-equality**: rec emits `replaces: ["ShowContainer", "TrackContainer"]` (reversed) vs manifest `["TrackContainer", "ShowContainer"]` → matches; score 1.0.
5. **`primary_match_specifics_missing_keys` panel-routes**: rec omits `replaces` → panel_route (was 0.5; methodology §8 says missing required keys is even further outside tolerance than wrong values).
6. **Tolerance-flag notes inclusion**: panel-route notes for Plant 4.1 with the manifest's flags include `tolerance_flag: associated_type_named_Item_or_synonym=True` and `tolerance_flag: type_slot_at_item_must_be_identified=True`, sorted alphabetically.
7. **Restraint plants unaffected**: Plant 1R recommendations still hit the restraint path; new value-comparison code never runs (already covered by existing restraint tests; pin as a guard).
8. **Empty `specifics_tolerance` on plant**: `_tolerance_flag_notes` returns `[]`; panel-routing notes contain only the mismatch lines. (Synthetic test plant — no real manifest plant has empty tolerance, but defensively cover.)
9. **Type-mismatch on value**: rec emits `replaces: "TrackContainer"` (string) vs manifest `replaces: ["TrackContainer", "ShowContainer"]` (list) → panel_route, notes flag the type mismatch.
10. **Extras-in-specifics still tolerated**: rec emits required keys + extra `notes: "..."` field; if required values all match, score is still 1.0 (superset semantics preserved).

Run the existing 123-test suite (`pytest experiments/v7-refactor-recommendation/`) to confirm no regression in the symbol-matching, restraint, or pipeline-integration tests.

## 5. Documentation cascade

| File | Change |
|---|---|
| `auto-scorer.py` (docstring §39–49) | Drop MVP-scope "key-only" caveat. Replace with: "Specifics matching is verbatim-value-aware. `recommendation.specifics[key]` is compared structurally to `plant.primary_answer.specifics[key]` for each key in `rubric.specifics_schemas[category].required`. Lists are compared as sets; dicts structurally; scalars by ==. Per-plant `specifics_tolerance` flags are emitted as panel guidance notes, not evaluated by the scorer — per methodology §8, outside-tolerance specifics route to panel, and the panel applies the flags." |
| `rubric-modifications.md` | Append "Round 2 — value-aware specifics matching (YYYY-MM-DD)" entry. Schema: Change / Why (cite methodology §8 lines 626–631) / Expected vs actual impact (table same shape as symbol-matching) / Prior results affected. |
| `results.md` §4.x | Headline numbers shift; document the methodological correctness of the shift; cross-link to `rubric-modifications.md`. |
| `results.md` §8 | Remove or rewrite any known-limitation entry mentioning key-only matching. Add a forward-looking note: "tolerance flags remain panel-guidance; structured evaluation deferred to a future round if panel load proves dominant." |
| `reproducibility.yaml` | Bump `manifest_hash` (no manifest change here, but cleanest to re-hash for consistency with the auto-scorer rev). Add `round2_methodology_update_value_aware_specifics` block with: source = issue #35, methodology citation, expected impact summary, links to rubric-modifications.md anchor. |
| `panel-instructions.md` | §1 (routing reasons) gains two more entries: `primary_match_specifics_outside_tolerance` and `primary_match_specifics_missing_keys`. New subsection on how panel applies the manifest's `specifics_tolerance` flags when rating these rows. |
| `README.md` | No change (high-level pipeline structure unchanged). |

## 6. Risks and mitigations

| Risk | Mitigation |
|---|---|
| Headline `canonical_recall` drops noticeably (e.g., S2 0.615 → 0.45). Reads externally as "round 2 regressed performance." | Frame in results.md and rubric-modifications.md as methodological correction: the round-1 number was over-credit. Report both numbers side-by-side. Headline 1−FPR unchanged → frame as "binding-attribution correctness was round 2's headline; this is its scoring-correctness sibling." |
| Strict verbatim comparison routes most primary-match rows to panel due to manifest values containing parenthesized commentary (e.g., Plant 1.1 `target_package: "Shared/Branding (already upstream of app:iOS and app:Mac)"`). | Verified empirically via §3.3 projection. Threshold: if trivial-mismatch flips exceed 30% of the (1.0 + 0.5-weak) row pool, file a normalization-pre-pass issue and block this PR. Below 30%, merge as-is. |
| Tolerance flag notes in panel-routing.jsonl bloat the file. | Notes are short strings; even 60 panel-routed rows × ~3 flags average × ~60 char/flag = ~10KB delta. Acceptable. |
| The new `primary_match_specifics_missing_keys` match label breaks downstream consumers expecting `primary_category_wrong_specifics`. | Audit completed (see §2.1): only 5 occurrences, all inside `auto-scorer.py` + `rubric.yaml` comment. No downstream consumers. Rename in place; no dual-path needed. |
| Round-2 panel doesn't exist yet (#85); panel-routed rows accumulate without scores. | Already true under round 1 / round 2 — the panel-routing.jsonl is recruit-ready, and `score_all.py`'s `promote_panel_scores` machinery handles rows landing later. Just more rows pre-recruitment. |
| §20 worked examples assert 1.0 / 0.5 via WORKED_EXAMPLES fixtures that already pass under value-aware comparison (specifics happen to match verbatim). But future methodology edits could change this. | Add a guard test that asserts: for each WORKED_EXAMPLES entry whose `expected_match in {primary_match_full, primary_match_weak_rationale}`, the recommendation's specifics deep-equal the manifest's primary_answer.specifics. This locks in §3.5 § the invariant. |

## 7. Rollback plan

If §3.3 projection or post-merge analysis shows the change is methodologically wrong (e.g., I misread §8 routing rules), revert in one commit: restore `score_recommendation()`'s Case 1 from git history, restore the synthetic fixture's `expected_score: 0.5`, restore the docstring caveat, drop the `rubric-modifications.md` entry, regenerate analyses. The change is self-contained to `auto-scorer.py` + tests + docs; no manifest or schema changes are needed in either direction. Revert is one PR.

## 8. Implementation order (TDD)

1. Read this plan back; submit `/review-plan` per global CLAUDE.md and incorporate HIGH-priority feedback.
2. Add §3.3 projection script (temporary `--project-value-mismatches` flag); run; record empirical numbers; tighten §2 estimates in this plan; decide whether to proceed or split.
3. Add failing tests #1–#10 from §4 to `test_score_all.py` (or `test_auto_scorer.py` if it exists). Run; confirm they fail with the expected error messages.
4. Add `_specifics_values_match` and `_tolerance_flag_notes` helpers in `auto-scorer.py`. Run tests; partial pass.
5. Update `score_recommendation()` Case 1 per §3.2. Run tests; all pass.
6. Update the synthetic fixture and add the new outside-tolerance fixture in `auto-scorer.py`. Run the dry-run subcommand (`python3 auto-scorer.py --dry-run`); all WORKED_EXAMPLES + SYNTHETIC_FIXTURES pass.
7. Update `auto-scorer.py` docstring §39–49.
8. Regenerate `analyses/` via the orchestration entry point. Diff `score-summary.json` against pre-change; verify the headline shift matches §3.3 projection.
9. Update `results.md`, `panel-instructions.md`, `reproducibility.yaml`, `rubric-modifications.md` per §5.
10. Run full test suite (`pytest experiments/v7-refactor-recommendation/`); confirm 123 + new tests all pass.
11. Open issue, then PR (`Closes #35`), with rebase against latest `experiment/swift-substrate`.
12. `/review-loop <PR#>` until converged or iter-cap.

## 9. Related issues

- Resolves: [`jakebromberg/code-audit-pipeline#35`](https://github.com/jakebromberg/code-audit-pipeline/issues/35).
- Successor to PR #89 (symbol-level binding) — preserves the symbol gate added there.
- Predecessor to: optional future plan to evaluate `specifics_tolerance` flags structurally if panel load proves dominant (issue #35 option (b), now downgraded to "follow-up if needed").
- Adjacent / unaffected: #85 (panel reviewer recruitment), B2 (Plants 1.4 / 5.4 placement diagnostic), #36 (bipartite matching).

## See also

- [`experiments/v7-refactor-recommendation/glossary.md`](../experiments/v7-refactor-recommendation/glossary.md) — shared V7 vocabulary (S1/S2, substrate, plants, metrics, all 13 auto-scorer match labels, binding rules, rounds/phases, code refs, PR/issue index).
