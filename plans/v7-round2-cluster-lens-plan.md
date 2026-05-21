# V7 Round 2 — explicit `cluster_lens` schema field (resolves #33, supersedes #28 §9 caveat)

> Round-2 follow-up to symbol-level binding (PR #89, [`v7-round2-symbol-matching-plan.md`](v7-round2-symbol-matching-plan.md)) and value-aware specifics (PR #90, [`v7-round2-value-aware-specifics-plan.md`](v7-round2-value-aware-specifics-plan.md)). Adds an explicit `cluster_lens` manifest field on plants that share a `cluster_id` with another plant; the auto-scorer's `bind_recs_to_plants` consults it to attribute action recommendations to the single lens-matching plant instead of all lens-sharing plants. The methodology §9 round-1 "cross-lens caveat" is superseded by the structural rule. Pre-registered via `rubric-modifications.md` per methodology §10.

## 1. Context and motivation

Round 1 closed [#28](https://github.com/jakebromberg/code-audit-pipeline/issues/28) with a doc-only resolution in methodology §9: when two restraint plants share a `cluster_id` (Plants 3R + 5R, both pointing at the `PlaylistTesting/PlaylistStubs.swift` stub cluster), the auto-scorer applies each plant's rubric independently. The §9 restraint table makes this choice "immaterial" in the sense that *every action recommendation against either plant scores 0.0 anyway*. But the headline FPR is inflated by one cluster's worth: a single failed recommendation against the shared cluster counts twice in the FPR numerator (once per plant) when canonically it should count once.

The §9 paragraph at lines 649 of `docs/refactor-recommendation-experiment-methodology.md` explicitly punts the structural fix to round 2:

> Each plant contributes one count to the FPR denominator and one count to the numerator if the agent emits action. A single failed recommendation against a cross-lens cluster therefore inflates the headline FPR by exactly one cluster's worth relative to a 1:1 cluster-to-plant scheme. This inflation is bounded (at most one shared cluster contributes one extra FP per cross-lens lens beyond the first), transparently reported, and the per-category FPR breakdown disaggregates it back out — but the inflation is real and the results writeup should call it out. Round 2 supersedes this caveat with an explicit `cluster_lens` schema field; see [issue #33](https://github.com/jakebromberg/code-audit-pipeline/issues/33).

The round-1 reasoning held because (a) the §9 "any action = FP" rule made `wrong_answers` enumerations immaterial for restraint scoring, (b) only one cross-lens pair existed in the round-1 plant set, and (c) the inflation was bounded and reportable. For round 2 — broader category coverage, more plants — a second cross-lens pair would compound the inflation. Encoding the routing rule structurally now removes the per-headline caveat and generalizes cleanly to N cross-lens plants.

The fix is small in code but principled: a plant declares which *lens* (= refactor category) it tests for a shared cluster; the scorer attributes an action recommendation to the plant whose lens matches the recommendation's category. No-action and out-of-lens-set recommendations preserve round-1 fan-out behavior (per the §9 restraint table, every lens-sharing plant scores them identically anyway).

## 2. Scope

In one PR against `experiment/swift-substrate`:

- **`plant-manifest.yaml` schema addition**: optional `cluster_lens` field on each plant, valued from `CATEGORIES` (the MVP refactor-category enum). Required iff the plant is cluster-sharing — i.e., shares both source_files and expected_cluster_symbols overlap with another plant. Migrate 3R/5R: `cluster_lens: default-implementation` on 3R, `cluster_lens: generic-parameterization` on 5R (each plant's existing `category` value).
- **`validate-manifest.py` extension**: new check 11 (`cluster_lens` schema). (a) `cluster_lens` ∈ `CATEGORIES` when present. (b) Plants in a cluster-sharing group must each declare `cluster_lens` (presence). (c) Plants in a sharing group must declare *distinct* `cluster_lens` values (uniqueness). (d) Add `cluster_lens` to `KNOWN_KEYS`. The sharing-group computation is heuristic: two plants share if `source_files ∩ source_files ≠ ∅` and `expected_cluster_symbols ∩ expected_cluster_symbols ≠ ∅`. This is the §9-encoded condition; not a substrate-emitted-`cluster_id` check (the validator doesn't run the substrate).
- **`score_all.py` `bind_recs_to_plants` extension**: after the existing symbol+signal gating produces the candidate plant list for a rec, if the candidate list has ≥2 plants AND any candidate declares a `cluster_lens`, apply the lens filter:
  - If `rec.category` is `no-action`: return all candidates unchanged (§9 restraint table dominates; all lens-sharing plants score identically).
  - Else if `rec.category` equals exactly one candidate's `cluster_lens`: return *only that one plant*.
  - Else (rec.category is an action category but matches no candidate's `cluster_lens`, or matches more than one — the latter should be impossible after validator check 11c): return all candidates unchanged. Round-1 "any action = FP across all lens-sharing plants" fallback, now explicit instead of implicit.
- **`rubric-modifications.md` append**: round-2 entry per methodology §10, citing the methodology §9 supersession, expected impact on round-2 score distribution (per-category FPR), pre-registered before round-2 trials begin.
- **`score_all.py` tests** (`test_score_all.py`): extend the existing `test_cross_lens_restraints_both_bind` test case (currently asserts both 3R and 5R bind under round-1 logic) with new cases per the routing rule above: action-rec-in-lens binds to one, action-rec-outside-lens binds to all, no-action binds to all, missing-cluster_lens fallback. The original test stays — it documents the round-1 fallback path for plants without `cluster_lens` declared.
- **`validate-manifest.py` tests** (`test_validator.py`): new `ClusterLensTests` class covering (a) accept valid `cluster_lens` value, (b) reject invalid value, (c) detect sharing-group + reject missing `cluster_lens` on at least one member, (d) reject same `cluster_lens` on two sharing-group members, (e) accept lone (non-sharing) plant without `cluster_lens`, (f) heuristic accuracy: no false positives on plants that merely share one source_file but no symbols (and vice versa).
- **Methodology §9 update** (`docs/refactor-recommendation-experiment-methodology.md`): supersede the round-1 caveat paragraph with the structural rule. New text describes the `cluster_lens` field and the three routing branches. Round-1 historical paragraph preserved as a transcluded quote for reproducibility-stack continuity.
- **Manifest doc** (`docs/refactor-recommendation-experiment-plant-manifest.md`): add `cluster_lens` to the Conventions section (the schema notes).
- **`agent-prompt.md`**: no change (the field is internal to manifest/scorer — agent never sees the lens declaration; the agent's category emission is what gets *routed against* the lens).
- **Regenerate `analyses/`**: run `score_all.py` against the existing parsed cache. Document the score-distribution shift in `rubric-modifications.md` per the round-1 → round-2 template (expected vs actual per-plant table). **Empirical pre-projection** (§3.3 below): all 45 currently-bound 3R+5R rows are `no-action` rec_category and score `no_action_ungrounded 0.5`. Under the new routing they ALL still route to both plants (per the no-action branch); zero scored-row movement is expected. The change matters for round 2 if/when action-category recs land against the shared cluster.
- **Update `reproducibility.yaml`**: bump `manifest_hash`, append a `round2_methodology_update_cluster_lens` block under `execution` describing the rubric-modifications.md addition.

### 2.1 Downstream consumer audit

Grep of the existing string identifiers across the repo (`grep -rn "cluster_lens" experiments/ docs/ plans/`) returns matches only in (a) the `KNOWN_KEYS` placeholder in the manifest doc Conventions section (mentions the field exists as round-2 scope), (b) prose references in methodology §9 (the caveat we're superseding), and (c) plan files (this plan and prior plans referencing #33). No code references — clean slate.

The bind-side routing change is local to `bind_recs_to_plants` in `score_all.py`; downstream consumers (`score_recommendations`, `panel-routing.jsonl` writer, `score-summary.json` aggregator) all consume `plant_ids` lists and are agnostic to *how* the list was produced.

**Out of scope here:**

- Tuple-valued `cluster_lens` (e.g., `{category, sub-lens}` for finer-grained routing). Lock the simplest form that survives the round-2 plant set per #33's Q1 guidance.
- Substrate-side computation of `cluster_id` in the validator. The sharing-group heuristic (source_files ∩ + symbols ∩) approximates the §9 condition without running the substrate. If the heuristic produces false negatives in round 2, escalate via a separate plan that wires the substrate's cluster outputs into the validator.
- Action-category bind-uniqueness when multiple plants in the sharing group declare the *same* `cluster_lens` as the rec's category. Validator check 11c rejects same-lens duplicates at manifest time, so the scorer doesn't need a runtime tie-break.
- Per-plant FPR re-attribution for already-merged round-1 results. The round-1 §9 caveat documents the bounded inflation and the per-category breakdown disaggregates it; this PR does not retroactively rewrite round-1 numbers.
- Round-2 panel sitting (still depends on #85).
- Plant 1.4 / 5.4 placement diagnostics (B2 — separate work).

## 3. Design decisions

### 3.1 Q1 — `cluster_lens` value space

**Decision**: `cluster_lens` ∈ `CATEGORIES` (= the five MVP refactor categories: `extract-to-common`, `protocol-inheritance`, `default-implementation`, `pat-introduction`, `generic-parameterization`).

**Rationale**: The lens IS a refactor category. The recommendation arrives with a `category` field drawn from the agent prompt's taxonomy; matching it to the plant's `cluster_lens` is a pure string comparison if both are drawn from the same enum. Restraint plants test under a category lens (e.g., 3R tests `default-implementation` restraint, even though its `primary_answer.category` is `no-action`); for restraints, `cluster_lens` equals the plant's `category`, which is the lens-under-test.

**Alternative considered**: Tuple `{category, sub-lens}` for finer-grained routing. Rejected per #33 Q1 ("Lock the simplest form that survives the round-2 plant set"). No round-2 use case has been articulated for sub-lenses; defer until one is.

**Alternative considered**: Free-form string, lens enum independent of `CATEGORIES`. Rejected: introduces a second taxonomy to maintain in sync with the agent prompt's category list, and the lens semantics ARE the category semantics.

**Schema invariant**: for restraint plants, `cluster_lens` (when declared) equals `category` (the plant's declared lens-under-test). For canonical plants, `cluster_lens` (when declared) equals `category` (the action the plant is designed to elicit). The validator does not enforce this equality — it's a documentation convention, not a structural one. A plant could legitimately test a lens different from its `category` in a future schema; today no such plant exists.

### 3.2 Q2 — Routing `no-action` recommendations

**Decision**: `no-action` recommendations bind to ALL lens-sharing plants in the candidate set (no lens-filter applied).

**Rationale**: Per methodology §9's restraint table, `no-action` against any restraint plant scores 1.0 (grounded) or 0.5 (ungrounded) regardless of lens. Both 3R and 5R produce identical scores for a given no-action rec; routing to one or both is observationally identical at the per-plant level but the doubled binding inflates the *count* of restraint-plant scoring events (denominator + numerator). However: the per-plant FPR denominator is "number of recommendations against this plant" — so binding both 3R and 5R correctly counts each plant's denominator independently. No FPR inflation occurs because both numerator and denominator scale together; the *headline* recall/FPR numbers are unchanged.

**Concrete check**: under round-1 binding, the 45 currently-bound 3R+5R rows (all `no-action` recs) produce 18 rows for 3R and 27 for 5R. Under the new routing they still produce the same 45 scored rows. The change is structural (the routing now consults `cluster_lens`) but the behavior on `no-action` recs is unchanged.

### 3.3 Q3 — Routing action recs whose category falls outside every declared lens

**Decision**: Bind to all lens-sharing plants (round-1 fallback behavior, now explicit).

**Rationale**: If an agent recommends, say, `protocol-inheritance` against the 3R+5R shared cluster, neither plant's lens (`default-implementation` / `generic-parameterization`) matches. Per §9 the restraint table makes every action recommendation a 0.0 FP regardless of lens; the agent's category being "wrong" doesn't favor attribution to any one plant. Round 1's behavior was to count both — the FPR inflation case the §9 caveat describes. This plan preserves that behavior for outside-lens action recs *because the methodology already accounts for it* (§9 says the inflation is bounded and per-category breakdowns disaggregate). The matched-lens routing branch (Q's primary motivation) is what fixes the inflation when it can be cleanly attributed.

**Alternative considered**: Bind to no plants (drop the rec). Rejected: silently dropping recs from FPR calculation under-counts agent failure mode (the agent did emit an action against a restraint cluster, that IS a false positive). The §9 restraint table is binding; preserve the FP attribution.

**Alternative considered**: Bind to one canonically-chosen plant (e.g., lexicographically first plant_id). Rejected: arbitrary tie-break introduces methodology ambiguity. Better to preserve the bounded inflation transparently.

### 3.4 Q4 — Validator enforcement

**Decision**: `validate-manifest.py` gains check 11 with the following clauses:

- **11a** (`cluster_lens` value): when present, must be in `CATEGORIES`. Type and enum check.
- **11b** (sharing-group presence): two plants are in a sharing-group iff ALL THREE conditions hold: `set(source_files) ∩ set(source_files) ≠ ∅` AND `set(expected_cluster_symbols) ∩ set(expected_cluster_symbols) ≠ ∅` AND `plant_a.category ≠ plant_b.category`. The third condition (cross-lens narrowing) was added during implementation after Plants 2.3 and 2.4 surfaced as a same-category cluster-sharing pair — both `protocol-inheritance` plants overlap on `AudioPlayerProtocol.swift` AND on the `AudioPlayerProtocol`/`AudioEnginePlayerProtocol` symbols, but the cluster_lens routing rule cannot disambiguate same-lens plants (their lens values would necessarily collide, violating 11c). Same-category cluster-sharing is a distinct manifest-design concern outside #33's §9 cross-lens scope; the auto-scorer's existing per-plant independent scoring handles it under the canonical rubric. For every sharing-group of size ≥ 2 (cross-lens only), every member MUST declare `cluster_lens`.
- **11c** (sharing-group lens uniqueness): for every sharing-group, all members' `cluster_lens` values must be distinct.
- **11d** (`KNOWN_KEYS`): add `cluster_lens` to the schema's known-keys set so the unknown-key warning doesn't fire.

**Algorithmic sketch** (validator check 11b sharing-group computation):

```python
def _sharing_groups(plants: list[dict]) -> list[set[str]]:
    """Group plants by **cross-lens** cluster-sharing (methodology §9).

    Two plants are in the same group iff ALL THREE conditions hold:
      (1) their source_files lists overlap, AND
      (2) their expected_cluster_symbols lists overlap, AND
      (3) their `category` values differ.

    Conditions (1) + (2) encode §9's structural cluster-sharing condition;
    condition (3) narrows to the cross-lens case specifically (same-category
    sharing is outside #33's scope — the lens routing rule can't disambiguate
    same-lens plants). The relation is transitive over plants of distinct
    categories: A ↔ B ↔ C with ≥ 2 categories represented end up in one group.

    Returns one set of plant_ids per group of size ≥ 2; singletons elided.
    """
```

The transitive-closure is implemented via union-find. The performance is irrelevant at 25 plants but the algorithm is documented.

**Heuristic escalation path** (from `/review-plan` MEDIUM #1): the source_files ∩ + expected_cluster_symbols ∩ overlap is a structural approximation of the substrate-emitted `cluster_id` overlap. If post-round-2 trials reveal substrate-level cluster_ids diverge from the heuristic — i.e., two plants share a substrate cluster_id but the heuristic doesn't flag them as a sharing-group (false negative), or vice versa (false positive) — escalate via a separate plan to wire substrate cluster outputs into the validator's check 11b. Until that escalation lands, the §9 fallback semantics still hold (bounded inflation, per-category disaggregation), so a false negative degrades gracefully to round-1 behavior rather than mis-scoring.

**Edge case (heuristic dimensions)**: a plant that shares source_files but no symbols (or vice versa) is NOT in a sharing-group — the §9 condition requires both overlaps. This is correct: a plant whose source_files overlap with another plant's but whose expected_cluster_symbols are disjoint does NOT bind to the same cluster_ids (PR #89's symbol gate filters them apart). So no routing ambiguity arises and `cluster_lens` is not required. Both directions of this edge case (source_files overlap with symbols disjoint, and symbols overlap with source_files disjoint) are explicitly exercised in §4.1 tests 6 and 7.

**Edge case (same-category sharing)**: Plants 2.3 and 2.4 both test `protocol-inheritance` on overlapping `AudioPlayerProtocol`/`AudioEnginePlayerProtocol` clusters. They satisfy conditions (1) and (2) but fail condition (3). The validator does NOT flag them as a sharing-group — the cluster_lens routing rule cannot disambiguate same-lens plants (a lens-match query would tie or miss either way). The auto-scorer's existing per-plant independent scoring handles same-category sharing under the canonical rubric: each plant scores the recommendation against its own `primary_answer.specifics`, so divergent answers are surfaced rather than collapsed. A separate follow-up issue should consider whether same-category cluster-sharing warrants its own routing mechanism (e.g., specifics-match-based attribution).

**Edge case**: a plant whose declared `cluster_lens` differs from its `category`. Today this never occurs (the convention is identity; see §3.1). The validator does not enforce the identity, only the enum-membership and the sharing-group constraints. If a future plant legitimately tests a lens different from its action category, the validator stays correct; the convention loosens.

### 3.5 Decision flow inside `bind_recs_to_plants`

The existing function (lines 127–193 of `score_all.py`) computes `matched` = the candidate plant_id list. Append a post-filter:

```python
def _apply_cluster_lens_routing(rec: dict, matched_plant_ids: list[str], plants_by_id: dict) -> list[str]:
    """Lens-routing post-filter applied to a candidate plant list.

    Three branches matching design decisions §3.2, §3.3, and the lens-match case:
      1. <2 candidates, or no candidate declares cluster_lens → no filter; pass through.
      2. rec.category == 'no-action' → no filter; all candidates score identically.
      3. exactly one candidate's cluster_lens == rec.category → return that one.
      4. zero or >1 candidates match (>1 should be unreachable post-validator) → pass through.

    Pass-through is the conservative default: preserves round-1 behavior when the
    lens declaration is absent or the rec's category doesn't unambiguously match.
    """
```

The function returns the filtered plant_id list; `bind_recs_to_plants` then proceeds with the existing `sorted(matched)` return.

**Ordering**: the lens filter applies AFTER the symbol gate AND AFTER the signal-match preference (lines 188–191). Symbol+signal selects which plants are valid candidates; lens routes among them. This preserves the round-1 binding correctness (lens routing only narrows the candidate set; never expands it).

## 3.3 Pre-implementation impact projection (round-1 data)

The currently-merged round-1 auto-scores have 45 bound rows on 3R+5R (18 on 3R, 27 on 5R), all `no-action` rec_category, all scoring `no_action_ungrounded 0.5`. Under the new routing:

- Lens-filter check fires (both plants declare `cluster_lens` after migration).
- Branch §3.2 triggers (`no-action` rec) → no filter.
- All 45 rows preserved exactly.

**Expected score delta on round-1 data**: zero. No headline change. The structural fix matters for round 2 (action-category recs against shared clusters) and for future cross-lens additions.

**Empirical confirmation plan**: regenerate `auto-scores.json` post-implementation; diff against the current file. Expected diff: zero scored-row movement, identical `headline` block, identical `panel_routed` count. Any non-zero delta = bug.

## 4. Implementation plan (TDD slices)

Each slice: failing test → implementation → passing test → refactor. Per global CLAUDE.md.

### 4.1 Validator `cluster_lens` schema (validator check 11)

Tests (in `test_validator.py`, new `ClusterLensTests` class):

1. `test_cluster_lens_accepted_with_valid_value`: plant with `cluster_lens: default-implementation` validates.
2. `test_cluster_lens_rejected_with_invalid_value`: plant with `cluster_lens: nonexistent-category` fails check 11a.
3. `test_cluster_lens_required_on_sharing_group_member`: two plants with overlapping source_files AND symbols, neither declares `cluster_lens` → check 11b fires.
4. `test_cluster_lens_required_on_partial_sharing_group_declaration`: one of two sharing plants declares `cluster_lens`, the other does not → check 11b fires.
5. `test_cluster_lens_uniqueness_in_sharing_group`: two sharing plants both declare `cluster_lens: default-implementation` → check 11c fires.
6. `test_cluster_lens_not_required_when_source_files_overlap_but_symbols_disjoint`: two plants share a source file but no expected_cluster_symbols overlap → no sharing-group → no `cluster_lens` required.
7. `test_cluster_lens_not_required_when_symbols_overlap_but_source_files_disjoint`: two plants share symbols but no source_files overlap → no sharing-group → no `cluster_lens` required.
8. `test_cluster_lens_not_required_for_singleton_plant`: plant with no overlapping plant → no `cluster_lens` required.
9. `test_cluster_lens_in_known_keys`: plant with `cluster_lens` produces no unknown-key warning.

Implementation:

- Add `"cluster_lens"` to `KNOWN_KEYS`. Place adjacent to `expected_cluster_symbols` (the other round-2 schema field) with an in-code comment matching its style — e.g., `# Round-2 cross-lens routing (#33)`. This keeps the rationale-by-issue convention visible in the schema.
- Add `_sharing_groups(plants)` helper (union-find on the source_files ∩ + symbols ∩ relation).
- Add `validate_cluster_lens(plants, errors)` function called once per validate() run (not per-plant — needs the whole list).
- Wire into `validate()` after the per-plant loop.

### 4.2 Scorer lens-routing post-filter

Tests (in `test_score_all.py`, augmenting `bind_recs_to_plants` section):

1. `test_cross_lens_action_rec_in_lens_routes_to_one_plant`: rec.category = `default-implementation`, both 3R and 5R candidate; only 3R returned.
2. `test_cross_lens_action_rec_outside_lens_routes_to_all`: rec.category = `protocol-inheritance` (outside both 3R/5R lenses); both returned.
3. `test_cross_lens_no_action_rec_routes_to_all`: rec.category = `no-action`; both returned.
4. `test_cross_lens_routing_skipped_when_lens_undeclared`: 3R and 5R without `cluster_lens` field; both returned regardless of rec category (round-1 fallback).
5. `test_cross_lens_routing_skipped_for_single_candidate`: only 3R candidate (5R not in list); rec.category irrelevant; 3R returned.
6. (Update existing) `test_cross_lens_restraints_both_bind`: keep the assertion but rename to `test_cross_lens_restraints_both_bind_under_round1_fallback` and document it tests the pre-`cluster_lens`-declaration path.

Implementation:

- Add `_apply_cluster_lens_routing(rec, matched, plants_by_id)` helper in `score_all.py`.
- Index `plants_by_id` at the top of `bind_recs_to_plants` (currently computed in the caller `score_recommendations` only).
- Call the post-filter after the `signal_matches if signal_matches else symbol_matches` line; pass the result through `sorted()` for stable output.

### 4.3 Manifest migration (3R, 5R)

Test (in `test_validator.py`): re-run validator against the migrated manifest; passes.

Implementation:

- Edit `plant-manifest.yaml`: add `cluster_lens: default-implementation` to 3R; `cluster_lens: generic-parameterization` to 5R.

### 4.4 Documentation

- Methodology §9: rewrite the cross-lens paragraph. New text (one paragraph, ~4 sentences) describes the `cluster_lens` field, the three routing branches, and points to PR #33-resolution in the rubric-modifications log.
- Manifest doc Conventions section: add a bullet describing `cluster_lens` (when required, value space, sharing-group condition).
- `rubric-modifications.md`: append a round-2 entry with the same template used for symbol-matching and value-aware-specifics changes. Expected impact: structural change, no headline movement on round-1 data, fixes bounded FPR inflation for round-2 action recs against shared clusters.

### 4.5 Regenerate analyses + reproducibility update

- Run `python3 score_all.py` against the existing parsed cache; commit the regenerated `analyses/auto-scores.json`, `analyses/panel-routing.jsonl`, `analyses/score-summary.json`.
- Bump `manifest_hash` and `auto-scorer-sha` in `reproducibility.yaml`.
- Append a `round2_methodology_update_cluster_lens` block under `execution` (sibling to the existing `round2_symbol_matching` and `round2_value_aware_specifics` entries from PRs #88/#89 and #90 respectively), with the rubric-modifications.md commit SHA. The YAML structure mirrors `rubric-modifications.md`'s per-round markdown headers — one entry per round-2 methodology change, stacked under `execution`.

## 5. Risks and mitigations

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| Sharing-group heuristic produces false negatives (real cluster-sharing plants not detected by source_files ∩ + symbols ∩). | Low (current manifest has only one cross-lens pair, and it overlaps on both) | Validator silently accepts undeclared `cluster_lens` → scorer falls back to fan-out routing for that pair → round-2 FPR inflation reappears | Mitigation 1: post-implementation, run a one-time audit of all 25 plants' cluster_ids (from a round-1 substrate run) to confirm the heuristic catches every real overlap. Mitigation 2: if a false-negative case appears in round 2, the existing §9 fallback semantics still apply (inflation is bounded and per-category breakdowns disaggregate); not a correctness failure. |
| Sharing-group heuristic produces false positives (plants share both source_files and symbols but their substrate cluster_ids are actually distinct). | Very low (the symbol gate in PR #89 specifically aligns plant ↔ cluster identity via symbol-substring; if both source AND symbols overlap, cluster overlap is structurally implied) | Validator demands `cluster_lens` declarations on plants that don't need them | Mitigation: if a future plant pair is flagged by the heuristic but real cluster_ids don't overlap, declare `cluster_lens` anyway (it's harmless — the routing post-filter only fires when ≥2 plants bind to the same rec). |
| Validator check 11b transitive-closure bug (union-find off-by-one). | Low | False-negative on chains of ≥3 plants sharing pairwise | Unit tests cover 3-plant chains explicitly. |
| Action-rec in-lens binding miscounts FPR (only one plant counted instead of two → headline FPR drops artificially for plants that didn't previously have any in-lens action recs). | Medium for round 2 — depends on whether agents emit in-lens action categories against shared clusters | Headline FPR shifts down by the in-lens-rec count | Pre-register the change in `rubric-modifications.md` per methodology §10. Document the round-1 → round-2 score-distribution shift transparently. The shift is the *intended* correction, not a regression. |
| The lens-routing post-filter is reached by a code path that doesn't pre-compute `plants_by_id` (e.g., a future caller skips `score_recommendations` and calls `bind_recs_to_plants` directly). | Low (only `score_recommendations` and tests call `bind_recs_to_plants`) | NameError or empty filter | Index `plants_by_id` inside `bind_recs_to_plants` itself; pass nothing through the API. |

**Rollback**: revert the commit. The lens-routing post-filter is purely a narrowing operation (it never adds plants), so reverting cannot lose data — it restores round-1 fan-out behavior. The manifest field becomes dead (unread) on revert; the validator check 11 still passes (rule is "iff sharing-group, must declare") because the migrated 3R/5R retain the field. Removing the validator check 11 + the manifest field is a follow-up.

## 6. Validation

### Pre-merge

- `pytest experiments/v7-refactor-recommendation/test_validator.py` — all green (existing + new `ClusterLensTests`).
- `pytest experiments/v7-refactor-recommendation/test_score_all.py` — all green (existing + new lens-routing tests).
- `python3 validate-manifest.py` against the migrated manifest — exits 0.
- `python3 score_all.py` against the existing parsed cache — `auto-scores.json` byte-diff against the merged version is empty in the `headline` and `scored` blocks (per §3.3 projection).

### Post-merge (round 2 trials)

- Per-category FPR breakdown for Cat 3 (default-implementation) and Cat 5 (generic-parameterization) cleanly attributes action-category recs to their lens-matching plant.
- No regression in round-1 reproducibility: re-running round-1 data through the new scorer produces byte-identical `headline` numbers.

## 7. Documentation updates

Files to touch:

- `docs/refactor-recommendation-experiment-methodology.md` §9 — rewrite cross-lens paragraph (supersede caveat).
- `docs/refactor-recommendation-experiment-plant-manifest.md` Conventions — add `cluster_lens` bullet.
- `experiments/v7-refactor-recommendation/plant-manifest.yaml` — add field to 3R and 5R.
- `experiments/v7-refactor-recommendation/rubric-modifications.md` — round-2 entry.
- `experiments/v7-refactor-recommendation/reproducibility.yaml` — bump hashes + append block.
- `experiments/v7-refactor-recommendation/validate-manifest.py` — check 11.
- `experiments/v7-refactor-recommendation/score_all.py` — lens-routing post-filter in `bind_recs_to_plants`.
- `experiments/v7-refactor-recommendation/test_validator.py` — new tests.
- `experiments/v7-refactor-recommendation/test_score_all.py` — new tests + rename of existing.
- `experiments/v7-refactor-recommendation/analyses/{auto-scores.json, panel-routing.jsonl, score-summary.json}` — regenerated.

Files NOT touched:

- `docs/refactor-recommendation-experiment-agent-prompt.md` — the agent doesn't see `cluster_lens`; no prompt changes.
- `auto-scorer.py` — the scorer per se is unchanged; only the binding layer (`score_all.py`) gains the post-filter. The rationale is that `score_recommendation()` is per-plant per-rec; it takes the plant as input. The lens-routing decision is upstream of that — at the rec → plant binding step.
- `analyses/panel-instructions.md` — no new panel routes; the panel sees the same set of routed rows as today (per §3.3, no row movement).

## 8. Out of scope / round-3 candidates

- Tuple-valued `cluster_lens` (`{category, sub-lens}`) for hierarchical lens routing. Defer until a round-2/3 plant articulates the need.
- Substrate-side computation of `cluster_id` in the validator. If the heuristic produces false-negatives, escalate via a separate plan that wires the substrate's cluster outputs into the validator's check 11b.
- Automatic FPR re-attribution for retroactive round-1 data. Round-1 results stand as documented under the §9 caveat; this PR fixes the rule going forward.
- Plant 1.4 / 5.4 placement diagnostics (B2 — separate work).

## 9. Acceptance criteria (from issue #33)

- [x] **`cluster_lens` field documented** in companion plant-manifest doc + methodology §9. (No agent-prompt change — field is internal.)
- [x] **Validator enforces field presence on cluster-sharing plants and across-plants cluster-id uniqueness.** Check 11 covers (a) enum, (b) sharing-group presence, (c) sharing-group uniqueness.
- [x] **Auto-scorer routes recommendations to one plant per cluster_id, per the resolved design.** `_apply_cluster_lens_routing` post-filter on the candidate plant list inside `bind_recs_to_plants`.
- [x] **Round-1 plants 3R and 5R migrated to the new schema.** `cluster_lens: default-implementation` on 3R, `cluster_lens: generic-parameterization` on 5R.

## 10. Reproducibility

- Manifest hash: bumped to reflect 3R/5R field addition.
- Auto-scorer SHA: unchanged (only `score_all.py` changes).
- `score_all.py` SHA: bumped.
- `validate-manifest.py` SHA: bumped.
- `rubric-modifications.md` round-2 entry: round-2 `cluster_lens` operationalization, references this plan + PR + issue #33.
- `reproducibility.yaml`: `round2_methodology_update_cluster_lens` block under `execution`.

## See also

- [`experiments/v7-refactor-recommendation/glossary.md`](../experiments/v7-refactor-recommendation/glossary.md) — shared V7 vocabulary (S1/S2, substrate, plants, metrics, all 13 auto-scorer match labels, binding rules, rounds/phases, code refs, PR/issue index).
