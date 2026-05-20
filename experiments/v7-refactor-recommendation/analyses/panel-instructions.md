# Panel review instructions — V7 round 2

For three internal reviewers. Time commitment: ~10–14 hours each (108 rows × ~6–8 min/row — `primary_match_specifics_outside_tolerance` rows require reading the plant manifest entry to judge tolerance-flag satisfaction; round 1's ~4 h estimate applied to the round-1 12-row corpus and is preserved in §6.1). Reviewers are blind to which substrate condition (S1 vs S2) produced each recommendation.

## 1. Background you need before starting

Read these in order, briefly:

- [`docs/refactor-recommendation-experiment-methodology.md`](../../../docs/refactor-recommendation-experiment-methodology.md) §8 ("Scoring rubric") and §9 ("Restraint and false-positive measurement").
- [`experiments/v7-refactor-recommendation/rubric.yaml`](../rubric.yaml) — the machine-readable rubric the auto-scorer uses.
- [`experiments/v7-refactor-recommendation/plant-manifest.yaml`](../plant-manifest.yaml) — the 25 plants and their per-plant expected answers. For each rec you're reviewing, the unblind step (§3 below) will tell you which plant it bound to so you can read that plant's manifest entry.

You do not need to read the parsed bodies or the raw API responses; the panel-routing artifact carries each rec's full text inline.

## 2. What's in front of you

[`analyses/panel-routing.jsonl`](panel-routing.jsonl) — one JSONL row per recommendation routed to panel by [`auto-scorer.py`](../auto-scorer.py)'s methodology-§8 decision rule. Phase D's parsed corpus had 2907 recs total; 764 bound to one or more plants. Round 2 has **108 routed to panel** (~14% of bound recs) across **17 plants and 29 distinct `(plant_id, cluster_id)` judgments**. The corpus reached its current shape in three steps: round 1 originally produced 12 routed rows (Plant 3.1 ×6 + Plant 5.1 ×6, all `category: "other"`); PR #89's `expected_cluster_symbols` gate dropped Plant 3.1 as a false binding, reducing the corpus to 6 rows; PR #90's value-aware specifics matching ([rubric-modifications.md](../rubric-modifications.md), resolves #35) then added two new routing reasons (`primary_match_specifics_outside_tolerance` and `primary_match_specifics_missing_keys`), bringing the corpus to its current 108 rows. §6.1 carries the historical detail.

Round-2 routing breakdown by `match_reason`:

| `match_reason` | Rows | Notes |
|---|---|---|
| `primary_match_specifics_outside_tolerance` | 102 | Agent picked the right category, but its `specifics` values disagree with the manifest. The `notes` field surfaces the per-key diff plus the plant's pre-registered `tolerance_flag` lines. **This is your dominant case** — see §3 case 2 for the scoring approach. |
| `other_routes_to_panel` | 6 | Agent emitted `rec_category: "other"` (novel category outside the taxonomy). All 6 are Plant 5.1 / HSBColor.uiColor+nsColor — the original round-1 panel case. |

Per-plant row counts (108 total): 1.1×15, 2.1×3, 2.2×3, 2.3×6, 2.4×6, 3.1×2, 3.2×12, 3.3×14, 3.4×15, 4.1×2, 4.2×3, 4.3×3, 4.4×3, 5.1×6, 5.2×9, 5.3×3, 5.4×3. None of the 17 plants involved are restraint plants, so the §4 restraint table does not apply to round 2.

Each `panel-routing.jsonl` row looks like (using a real `primary_match_specifics_outside_tolerance` row from Plant 3.2 as the example, since that's 94% of the corpus):

```json
{
  "rec_token": "pr-026f65dd0e85",
  "plant_id": "3.2",
  "plant_category": "default-implementation",
  "plant_restraint": false,
  "query": "function-duplicates",
  "rec_category": "default-implementation",
  "rec_specifics": {
    "protocol": "BlendModeConvertible",
    "method": "var blendMode: <ReturnType> { get }",
    "target_location": "Shared/Wallpaper/Sources/Wallpaper/Core/BlendModeConvertible.swift",
    "conformers_simplified": ["…three .swift paths…"]
  },
  "rec_rationale": "Three distinct enum/type declarations — PlaybackBlendMode, MaterialBlendMode, and OverlayBlendMode — all in the Wallpaper package each carry an identically-shaped blendMode computed property at exactly line 62…",
  "rec_evidence_quote": "PlaybackBlendMode.blendMode+Wallpaper:Shared/Wallpaper/…+Wallpaper:…/MaterialBlendMode.swift:62:MaterialBlendMode.blendMode+…",
  "rec_confidence": 0.72,
  "match_reason": "primary_match_specifics_outside_tolerance",
  "notes": [
    "key='protocol' manifest='BlendMode (new shared protocol over the 16-case union, with displayName + blendMode requirements)' rec='BlendModeConvertible'",
    "key='method' manifest='displayName: String { get }' rec='var blendMode: <ReturnType> { get }'",
    "key='target_location' manifest='Shared/Wallpaper/Sources/Wallpaper/Core/BlendMode.swift (extension on BlendMode)' rec='Shared/Wallpaper/Sources/Wallpaper/Core/BlendModeConvertible.swift'",
    "tolerance_flag: default_impl_must_be_in_protocols_own_package=True"
  ],
  "unblind": {"cluster_id": "function-duplicates-exact:Wallpaper:…", "condition": "s1|s2", "trial": 1}
}
```

The `notes` field is a JSON **array of strings**: one string per `specifics`-key mismatch (`key='<key>' manifest=<manifest_repr> rec=<rec_repr>`, using Python `repr()` formatting), followed by one string per pre-registered tolerance flag (`tolerance_flag: <flag_name>=True`). §3 case 2 explains how to read this against the plant manifest.

For the 6 `other_routes_to_panel` rows (Plant 5.1 / HSBColor), the row shape is the same except `match_reason` is `other_routes_to_panel`, `rec_category` is `other`, `rec_specifics` carries the agent's `proposed_action` + `why_no_category_fits` fields instead of the schema-typed keys, and `notes` is absent.

The `unblind` block is in each row but **do not read it until you have committed your score**. The blinding mechanism is by self-discipline, not by file separation, so the protocol is: read every field except `unblind`, score, write the score line, then if you need the condition for any reason it's in `unblind`. The unblind values are also dumped to [`panel-unblind.json`](panel-unblind.json) for post-hoc analysis after all reviewers complete.

## 3. The four panel cases (per Phase E plan §7.2 / main plan §7.2)

Round 2 hits the first two cases. All four are listed so you know what to expect if the corpus changes:

1. **`rec_category == "other"`** — agent proposed a novel category not in the taxonomy. **Round 2 has 6 of these (all Plant 5.1 / HSBColor.uiColor+nsColor).** Score by treating the agent's `proposed_action` and `why_no_category_fits` as its claim, and judging it on the same axes you'd apply to a category-correct rec: is the action a reasonable refactor for this cluster, and does the rationale engage with the cluster's structural evidence?
2. **Primary-category match with specifics out of tolerance** (`match_reason` ∈ {`primary_match_specifics_outside_tolerance`, `primary_match_specifics_missing_keys`}) — **round 2 has 102 of these across 16 plants; this is your dominant case.** Agent picked the right category but its `specifics` values disagree with the plant's `primary_answer.specifics`. Each row's `notes` field is a JSON array containing (a) the per-key mismatch (one string per key: `key='<key>' manifest=<manifest_val_repr> rec=<rec_val_repr>`) and (b) the plant's pre-registered `specifics_tolerance` flags (one string per flag: `tolerance_flag: <flag_name>=True`). The flags describe structural properties the manifest authors care about (e.g., `default_impl_must_be_in_protocols_own_package`, `protocol_must_be_existing_PlaylistEntry`, `target_package_must_be_upstream_of_all_consumers`); your job is to judge whether the agent's value satisfies the flag's structural property even if it doesn't verbatim-equal the manifest string. The auto-scorer does not evaluate these flags; that's the panel's role per methodology §8 lines 626–631.

   **Worked example — Plant 3.2 / `pr-026f65dd0e85`** (the row shown in §2's JSON example):

   - `notes[3]`: `tolerance_flag: default_impl_must_be_in_protocols_own_package=True`. The flag asks: does the agent's proposed default-implementation site live inside the protocol's own SPM package?
   - `notes[0]`: agent's `protocol` is `BlendModeConvertible` (a new protocol it's introducing); manifest's `protocol` is `BlendMode` (an existing type the manifest treats as the refactor target). Different names, but both are within the `Wallpaper` package.
   - `notes[2]`: agent's `target_location` is `Shared/Wallpaper/Sources/Wallpaper/Core/BlendModeConvertible.swift` (the new protocol's own file inside `Wallpaper`); manifest's target is `Shared/Wallpaper/Sources/Wallpaper/Core/BlendMode.swift` (an extension on `BlendMode` inside `Wallpaper`).
   - Structural judgment: both placements satisfy the `default_impl_must_be_in_protocols_own_package` flag — the agent introduced a new protocol within `Wallpaper` and put its default-impl inside `Wallpaper`, so the load-bearing property (default-impl colocated with the protocol declaration) is preserved. Verbatim mismatch on the protocol name is real but doesn't break compilation or the architectural intent. Score 0.7 (defensible alternative) is defensible here; 0.5 (right category, weaker specifics) is also defensible.
   - Contrast with a failure case: if the agent's `target_location` had pointed at a downstream consumer package (e.g., `Shared/PlayerHeaderView/...`), the flag would be violated — the default-impl would be unreachable from the protocol's own package and the refactor would either not compile or require an extra dependency edge. Score 0.0 in that case (wrong specifics that won't compile).

   Score per row: did the agent's specific values get the refactor's load-bearing details right per the structural properties described by the tolerance flags, or did it hallucinate names/paths that violate them?
3. **Alternative match with specifics out of tolerance** — same as 2 but against an `alternative_answers[*]` entry. Score by the same rubric, weighted by that alternative's manifest `weight`. Round 2 has zero of these.
4. **Wrong-category novel** — agent's category is not primary, not in alternatives, not in wrong_answers, not adjacent. Score 0.0 unless the agent's rationale persuades you the cluster really did want a different refactor than the manifest pre-registered (in which case log to [`rubric-modifications.md`](../rubric-modifications.md) and bring it up at debrief). Round 2 has zero of these.
5. **Citation-grounding spot check** — a 10% random sample of *auto-scored* recs (not panel-routed) was planned as a separate `analyses/grounding-audit-sample.jsonl` for a future round; round 2 does not include this on top of the 108-row main panel load.

## 4. Scoring per panel rec

Use the methodology §8 scoring scale:

| Score | When |
|---|---|
| **1.0** | Right action, grounded rationale, specifics correct |
| **0.7** | Defensible alternative to the manifest's primary answer |
| **0.5** | Right category or right specifics but not both, OR right answer with weak grounding |
| **0.3** | Wrong category but adjacent and defensible |
| **0.0** | Wrong category, hallucinated rationale, or doesn't engage with the cluster |
| **-0.5** | Recommends an action that would break the codebase |

For restraint plants (`plant_restraint: true`), use the restraint table from methodology §9 instead:

| Score | When |
|---|---|
| **1.0** | `no-action` with grounded rationale citing the context signal |
| **0.5** | `no-action` without specific rationale |
| **0.0** | Any action recommendation |

None of round 2's 108 panel cases are restraint plants — the 17 plants involved are all canonical (categories: default-implementation, generic-parameterization, protocol-inheritance, extract-to-common, pat-introduction). The restraint table is included for completeness in case a future round routes restraints to panel.

For the "other" case, the operational rule: pretend the agent had picked the closest category in the taxonomy and ask "would this answer have scored 1.0 / 0.7 / etc. under that category's manifest entry?" The score is what you'd have given under that category. If no category fits, score 0.0 — the agent's "other" was unjustified.

## 5. How to write your scores

Each reviewer writes a JSONL file at `analyses/panel-scores-<reviewer-id>.jsonl`. The `reviewer-id` convention is `reviewer-1`, `reviewer-2`, `reviewer-3` (matching the existing `panel-scores-reviewer-1.jsonl` round-1 file). One row per scored rec_token:

```json
{"rec_token": "pr-abc123def456", "reviewer": "reviewer-2", "score": 0.7, "notes": "Defensible: agent introduced a new protocol but kept the default-impl inside the protocol's own package, satisfying the tolerance flag. Verbatim protocol-name mismatch is cosmetic."}
{"rec_token": "pr-def456abc789", "reviewer": "reviewer-2", "score": 0.0, "notes": "Hallucinated: target_location points at a downstream consumer package, violates default_impl_must_be_in_protocols_own_package."}
```

After all reviewers finish, concatenate to `analyses/panel-scores.jsonl` (one consolidated file). [`score_all.py`](../score_all.py)'s `attach_panel_kappa()` reads that consolidated file and computes Fleiss κ over the score buckets; rerun the scorer once the consolidated file lands and `analyses/score-summary.json` regenerates with the `inter_rater` block populated.

## 6. Round-2 panel coverage and the correlated-items caveat

The 108 routed rows are NOT 108 independent judgments. They aggregate into **29 distinct `(plant_id, cluster_id)` judgments**, with each judgment carrying 2–15 rec rows (one per trial × condition combination, modulo agent skip/retry). Empirically, rec rationale texts within a judgment are linguistically distinct (the agent re-phrases per trial) but typically **semantically similar** — they propose the same refactor on the same cluster. A reviewer scoring on substance will likely give all rows in a judgment correlated scores; a reviewer scoring on prose granularity might vary by 0.0–0.1.

To surface this, `score_all.py` emits **two** inter-rater blocks:

- **`inter_rater`** — Fleiss κ over the 108 rec rows × N raters. Score buckets {-0.5, 0.0, 0.3, 0.5, 0.7, 1.0} are the categories. This is the literal methodology §8 / §12 measure. **May be inflated** by item correlation when reviewers give matched scores across duplicates within a judgment (all 6 rows of a judgment get the same score from every reviewer → looks like agreement on 6 items but is really agreement on 1 underlying call, multiplied 6 ways).
- **`inter_rater_collapsed`** — Fleiss κ over the **29 distinct `(plant_id, cluster_id)` judgments** × N raters. Each (reviewer, judgment) cell reduces its 2–15 per-cell scores to a median, and κ is computed over those medians. With N=29 distinct judgments the collapsed κ has genuine statistical power and is the **primary measure to report** in `results.md` §4.3; `inter_rater` is the secondary/sanity-check measure that confirms the rec-level rubric is internally consistent.

A diagnostic field, `within_reviewer_inconsistency_count`, counts the (reviewer, judgment) cells where the reviewer's variance across duplicates was > 0. If this number is high, reviewers are sensitive to prose variation across trials — `inter_rater_collapsed`'s medians understate that disagreement and `inter_rater` is the truer measure. If it's near zero (reviewers internally consistent across duplicates), the rec-level κ is inflated by item correlation and the collapsed measure is the truer signal.

### Orphan rec_tokens

`panel-scores-reviewer-1.jsonl` originally carried 12 round-1 rows. Six (Plant 5.1 / HSBColor — the `other_routes_to_panel` rows) still match the current `panel-routing.jsonl` and contribute to κ; PR #89's symbol gate preserved them, and PR #90 didn't disturb them. The other six (Plant 3.1, false bindings PR #89's symbol gate eliminated) no longer map to any panel-routing row. Per the round-2 augment decision (#94), those 6 orphan rows have been **dropped** from `panel-scores-reviewer-1.jsonl`: the file is now 6 rows of Plant 5.1 / `other_routes_to_panel` scores, and reviewer-1's round-2 augment task is to append 102 new score rows covering the post-PR-#90 tolerance-flag corpus. `attach_panel_kappa` and `attach_collapsed_panel_kappa` retain their orphan-filter logic as a belt-and-suspenders safety net: if any future corpus regenesis re-creates orphans, the filter handles them transparently and surfaces the count in `inter_rater.note` / `inter_rater_collapsed.note`. Reviewer-2 and reviewer-3 score against the current 108-row `panel-routing.jsonl` and won't generate orphans.

### `inter_rater_collapsed` block schema

```json
{
  "fleiss_kappa": 0.62,                       // numeric when m≥2 and coverage is full; null on sentinel paths
  "n_judgments": 29,                          // distinct (plant_id, cluster_id) cells after orphan filter
  "n_raters": 3,                              // unique reviewer IDs seen in panel-scores
  "judgments": [
    {
      "plant_id": "3.2",
      "cluster_id": "function-duplicates-exact:Wallpaper:…/MaterialBlendMode.swift:62:…",
      "n_duplicates_per_reviewer": {"reviewer-1": 6, "reviewer-2": 6, "reviewer-3": 6},
      "reviewer_medians": {"reviewer-1": 0.7, "reviewer-2": 0.7, "reviewer-3": 0.5},
      "reviewer_variance": {"reviewer-1": 0.0, "reviewer-2": 0.0, "reviewer-3": 0.04}
    }
    // …28 more entries…
  ],
  "within_reviewer_inconsistency_count": 3,   // # of (judgment, reviewer) cells with variance > 0
  "note": null                                // populated only when a sentinel fires (uneven coverage, orphan tokens, etc.)
}
```

`n_duplicates_per_reviewer` is per-reviewer because reviewers can cover different numbers of duplicates per judgment (e.g., reviewer-1's round-1 scores cover only the 6 Plant 5.1 surviving rows, so for the other 28 round-2 judgments the `"reviewer-1"` key is absent from `n_duplicates_per_reviewer` / `reviewer_medians` / `reviewer_variance` — the per-judgment dicts only carry keys for reviewers that actually scored at least one duplicate of that judgment). `fleiss_kappa` is null and `note` is populated when: panel-scores is missing/empty, fewer than 2 reviewers contributed, or reviewer coverage is uneven at the judgment level — Fleiss κ requires every item rated by exactly m raters, where m is the total number of distinct reviewer IDs that contributed any score (so if reviewer-1, reviewer-2, and reviewer-3 all submit scores anywhere in the corpus, m=3 globally and every judgment must be covered by all 3 or the sentinel fires). Because reviewer-1 only covers Plant 5.1 (the surviving 6 of their original 12 scores), the other 28 round-2 judgments are covered by reviewer-2 and reviewer-3 only; under the current `attach_collapsed_panel_kappa` implementation this is exactly the "uneven coverage" case and `score_all.py` will emit the coverage sentinel (`fleiss_kappa: null` plus a `(judgment, reviewer) pair(s) missing` note) rather than computing a sub-m κ on the covered subset. To get a numeric collapsed κ, reviewer-1 must back-score the 28 new judgments before the final rerun.

### How to interpret the two κs together

| `inter_rater` κ | `inter_rater_collapsed` κ | Reading |
|---|---|---|
| High | High | Reviewers agree on the underlying calls AND on every duplicate. Confident rubric coverage. |
| High | Low | Reviewers agree on most duplicate rows by chance (e.g., all defaulting to 0.0 for "other"), but disagree on the underlying calls. `inter_rater` is inflated by item correlation — trust the collapsed measure. |
| Low | High | Reviewers agree on the underlying calls but disagree on individual duplicates (prose-sensitive scoring). Calibration needed on prose vs substance — see `within_reviewer_inconsistency_count`. |
| Low | Low | Reviewers genuinely disagree on the calls. Rubric needs round-3 work — flag specific judgments with high cross-reviewer score variance for debrief. |

When the round-2 panel sitting completes, populate `inter_rater_collapsed.fleiss_kappa` and report it in `results.md` §4.3 as the primary inter-rater measure; report `inter_rater.fleiss_kappa` as the secondary measure with the item-correlation caveat. With 102 of 108 rows in the `primary_match_specifics_outside_tolerance` case, the rubric coverage question for round 2 is specifically **how reliably reviewers can judge tolerance-flag satisfaction from the `notes` field** (§3 case 2's worked example is the calibration anchor). If `inter_rater_collapsed` comes back below 0.4 ("fair") on the tolerance-flag judgments, that's a methodology gap to log in `rubric-modifications.md` and probably implies the tolerance flags themselves need tightening or the manifest's `specifics_tolerance` schema needs additional structural properties.

The category-mix observation: Plant 5.1's persistent `rec_category == "other"` classification (the 6 HSBColor rows from round 1, still present) is itself a finding — the agent consistently views HSBColor.uiColor / HSBColor.nsColor as a novel platform-bridging shape rather than as generic-parameterization. Worth a debrief discussion after panel scores land, separate from the κ analysis.

### 6.1 Round-1 historical (pre-PR-#90)

> **Preserved for reproducibility-stack continuity. Skip if you're scoring round-2 rows; this subsection only matters for tracing what reviewer-1's round-1 scores meant at the time they were written.**

Round 1's `panel-routing.jsonl` carried 12 panel-routed recs split across Plant 3.1 (default-implementation, 6 rows) and Plant 5.1 (generic-parameterization, 6 rows), both bound to the same HSBColor `function-duplicates-near` cluster. The round-1 routing rule fired only on `rec_category == "other"`, which is why all 12 round-1 rows were case 1 ("other"). Round-1's planned time commitment was ~4 hours per reviewer.

Two PRs subsequently reshaped the panel corpus:

1. **PR #89 / `expected_cluster_symbols` gate (2026-05-18)** — added a per-plant symbol gate that dropped Plant 3.1's 6 rows as false bindings (Plant 3.1's symbols `HSBColor.init(...)`, `AccentColor.init`, `HSBOffset.init` don't appear in the panel cluster_id; the original binding was substring-matching on `HSBColor.swift` paths). Post-gate `panel-routing.jsonl` carried 6 rows, all Plant 5.1. This is the "post-symbol-gate single judgment" state the doc described before round 2's value-aware specifics matching landed.

2. **PR #90 / value-aware specifics matching (2026-05-19)** — added the `primary_match_specifics_outside_tolerance` and `primary_match_specifics_missing_keys` routing reasons, which together added 102 new routed rows across 16 plants. This brought the corpus to the current 108-row state described above.

At PR #89's state, the collapsed κ was degenerate at N=1 distinct judgment: mathematically defined but with no across-item variance to anchor `P_e`, so it returned 1.0 on full reviewer agreement or 0.0 otherwise. The "two κs, two granularities" framing in this section was originally written for that state, where collapsed κ was a sanity check rather than a measure. PR #90 restored its interpretive value by raising N from 1 to 29.

Reviewer-1's 12 round-1 scores were written against the pre-PR-#89 12-row corpus. The 6 Plant 3.1 scores became orphans at PR #89; the 6 Plant 5.1 scores remain valid in the current corpus. Per the round-2 augment decision (#94, 2026-05-20), the 6 orphan rows have been dropped from `panel-scores-reviewer-1.jsonl`; the file is now 6 rows and reviewer-1's round-2 task is to append 102 new scores for the post-PR-#90 tolerance-flag corpus.

## 7. Mechanical checklist

1. [ ] Read the methodology + rubric pointers in §1.
2. [ ] Read §3 case 2 fully, including the Plant 3.2 / `pr-026f65dd0e85` worked example — that's your calibration anchor for the 102 `primary_match_specifics_outside_tolerance` rows.
3. [ ] **Suggested chunking:** score by plant. Open `panel-routing.jsonl`, filter to one plant_id at a time, score that plant's 2–15 rows in one sitting, then move on. Doing it plant-by-plant lets you read the manifest entry once per batch instead of 108 times. Plant order doesn't matter; the scorer sorts internally.
4. [ ] For each of the 108 rows: read the `rec_*` fields and the `notes` array (for `primary_match_specifics_outside_tolerance` rows), **do not** look at `unblind`, score, write a row to your `panel-scores-<reviewer-id>.jsonl`. Use the §4 main scoring table; restraint table does not apply to round 2.
5. [ ] After scoring all 108, run `python3 experiments/v7-refactor-recommendation/regenerate_panel_scores.py` to consolidate the per-reviewer files into `analyses/panel-scores.jsonl` (sorted by (rec_token, reviewer); validates uniqueness and corpus membership).
6. [ ] Re-run `python3 experiments/v7-refactor-recommendation/score_all.py` so `analyses/score-summary.json` picks up the Fleiss κ. Confirm `inter_rater.n_items` is 108, `inter_rater.n_raters` is 3, and both `inter_rater.fleiss_kappa` and `inter_rater_collapsed.fleiss_kappa` are populated (not null). The round-1 orphan-filter signal has been resolved by the #94 augment drop, so `inter_rater.note` should be null — if it reports orphans now, that's a regression, not the round-1 signature.
7. [ ] Report `inter_rater_collapsed.fleiss_kappa` as the primary κ in `results.md` §4.3; report `inter_rater.fleiss_kappa` as the secondary κ with the item-correlation caveat. If the collapsed κ comes back below 0.4 ("fair" agreement), schedule a debrief: judgments with high cross-reviewer score variance flag specific tolerance-flag interpretations that need rubric tightening in round 3.
