# Panel review instructions — V7 round 1

For three internal reviewers. Time commitment: ~4 hours each. Reviewers are blind to which substrate condition (S1 vs S2) produced each recommendation.

## 1. Background you need before starting

Read these in order, briefly:

- [`docs/refactor-recommendation-experiment-methodology.md`](../../../docs/refactor-recommendation-experiment-methodology.md) §8 ("Scoring rubric") and §9 ("Restraint and false-positive measurement").
- [`experiments/v7-refactor-recommendation/rubric.yaml`](../rubric.yaml) — the machine-readable rubric the auto-scorer uses.
- [`experiments/v7-refactor-recommendation/plant-manifest.yaml`](../plant-manifest.yaml) — the 25 plants and their per-plant expected answers. For each rec you're reviewing, the unblind step (§3 below) will tell you which plant it bound to so you can read that plant's manifest entry.

You do not need to read the parsed bodies or the raw API responses; the panel-routing artifact carries each rec's full text inline.

## 2. What's in front of you

[`analyses/panel-routing.jsonl`](panel-routing.jsonl) — one JSONL row per recommendation routed to panel by [`auto-scorer.py`](../auto-scorer.py)'s methodology-§8 decision rule. Phase D's parsed corpus had 2907 recs total; 764 bound to one or more plants; **12 of those 764 routed to panel** (~1.6%). All 12 are `category: "other"` cases — the agent declined to choose from the methodology's category taxonomy and proposed something custom. There are no specifics-out-of-tolerance routes in round 1 because the auto-scorer uses key-only specifics matching (see [`auto-scorer.py`](../auto-scorer.py) MVP-scope docstring, lines 38–47).

Each panel-routing.jsonl row looks like:

```json
{
  "rec_token": "pr-<12-char-hex>",
  "plant_id": "3.1",
  "plant_category": "default-implementation",
  "plant_restraint": false,
  "query": "default-impl-candidates",
  "rec_category": "other",
  "rec_specifics": {"proposed_action": "...", "why_no_category_fits": "..."},
  "rec_rationale": "...",
  "rec_evidence_quote": "...",
  "rec_confidence": 0.6,
  "match_reason": "other_routes_to_panel",
  "unblind": {"cluster_id": "...", "condition": "s1|s2", "trial": 1}
}
```

The `unblind` block is in each row but **do not read it until you have committed your score**. The blinding mechanism is by self-discipline, not by file separation, so the protocol is: read every field except `unblind`, score, write the score line, then if you need the condition for any reason it's in `unblind`. The unblind values are also dumped to [`panel-unblind.json`](panel-unblind.json) for post-hoc analysis after all reviewers complete.

## 3. The four panel cases (per Phase E plan §7.2 / main plan §7.2)

Round 1 only hits one of the four. All four are listed so you know what to expect if the corpus changes:

1. **`rec_category == "other"`** — agent proposed a novel category not in the taxonomy. **All 12 round-1 panel cases are here.** Score by treating the agent's `proposed_action` and `why_no_category_fits` as its claim, and judging it on the same axes you'd apply to a category-correct rec: is the action a reasonable refactor for this cluster, and does the rationale engage with the cluster's structural evidence?
2. **Primary-category match with specifics out of tolerance** — agent picked the right category but its `specifics` values disagree with the plant's `primary_answer.specifics` beyond the per-plant `specifics_tolerance`. Round 1 does not auto-detect this (key-only matching, [`auto-scorer.py`](../auto-scorer.py) lines 38–47); the 10–20% spot-check (case 5 below) is the human counterweight. Score: did the agent's specific values get the refactor's load-bearing details right (correct new protocol name, correct file path, etc.) or did it hallucinate names that won't compile?
3. **Alternative match with specifics out of tolerance** — same as 2 but against an `alternative_answers[*]` entry. Score by the same rubric, weighted by that alternative's manifest `weight`.
4. **Wrong-category novel** — agent's category is not primary, not in alternatives, not in wrong_answers, not adjacent. Score 0.0 unless the agent's rationale persuades you the cluster really did want a different refactor than the manifest pre-registered (in which case log to [`rubric-modifications.md`](../rubric-modifications.md) and bring it up at debrief).
5. **Citation-grounding spot check** — a 10% random sample of *auto-scored* recs (not panel-routed) is included as a separate `analyses/grounding-audit-sample.jsonl` for round 2; round 1 skips this because the panel volume is already small (12 recs) and adding spot-check load on top is not necessary at this corpus size.

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

None of the 12 round-1 panel cases are restraint plants — both Plant 3.1 and Plant 5.1 are canonical, not restraints. The restraint table is included for completeness in case round 2 routes restraints to panel.

For the "other" case, the operational rule: pretend the agent had picked the closest category in the taxonomy and ask "would this answer have scored 1.0 / 0.7 / etc. under that category's manifest entry?" The score is what you'd have given under that category. If no category fits, score 0.0 — the agent's "other" was unjustified.

## 5. How to write your scores

Each reviewer writes a JSONL file at `analyses/panel-scores-<reviewer-id>.jsonl`:

```json
{"rec_token": "pr-abc123def456", "reviewer": "alice", "score": 0.7, "notes": "Proposed free function is reasonable but loses the polymorphism the protocol's other methods do use."}
{"rec_token": "pr-def456abc789", "reviewer": "alice", "score": 0.0, "notes": "Hallucinated; the cluster doesn't have the structure the rec claims."}
```

After all reviewers finish, concatenate to `analyses/panel-scores.jsonl` (one consolidated file). [`score_all.py`](../score_all.py)'s `attach_panel_kappa()` reads that consolidated file and computes Fleiss κ over the score buckets; rerun the scorer once the consolidated file lands and `analyses/score-summary.json` regenerates with the `inter_rater` block populated.

## 6. Round-2 panel coverage (post-symbol-gate) and the correlated-items caveat

> **Round-2 update.** Round 1's `panel-routing.jsonl` carried 12 panel-routed recs split across Plant 3.1 (default-implementation, 6 rows) and Plant 5.1 (generic-parameterization, 6 rows), both bound to the same HSBColor `function-duplicates-near` cluster. The round-2 symbol-level binding fix ([`rubric-modifications.md`](../rubric-modifications.md), 2026-05-18) added a per-plant `expected_cluster_symbols` gate; Plant 3.1's symbols (`HSBColor.init(...)`, `AccentColor.init`, `HSBOffset.init`) don't appear in the panel cluster_id, so Plant 3.1's 6 rows dropped out as false bindings. The regenerated `panel-routing.jsonl` carries 6 rows, all Plant 5.1, and the 6 round-1 Plant 3.1 panel scores in `panel-scores-reviewer-1.jsonl` become orphan rec_tokens (filtered out by both `attach_panel_kappa` and `attach_collapsed_panel_kappa` and counted in the structured note).

The 6 surviving panel-routed recs concentrate on a single plant ↔ cluster judgment:

- **Plant 5.1** (generic-parameterization): 6 recs (3 in S1, 3 in S2 — one per trial each), all bound to `function-duplicates-near:…HSBColor.uiColor+…HSBColor.nsColor`.

Each reviewer scores all 6 surviving recs. Total round-2 panel-pair count: 6 recs × N reviewers score rows.

### Two κ measures, two granularities

The 6 items are NOT 6 independent judgments. Empirically, the 6 Plant 5.1 rec rationale texts are linguistically distinct (the agent re-phrases per trial) but **semantically identical** — all 6 propose the same private-helper or `#if canImport(...)` refactor on the same cluster. A reviewer scoring on substance will likely give all 6 duplicates the same score; a reviewer scoring on prose granularity might vary by 0.0–0.1.

To surface this, `score_all.py` emits **two** inter-rater blocks:

- **`inter_rater`** — Fleiss κ over the 6 surviving rec rows × N raters. Score buckets {-0.5, 0.0, 0.3, 0.5, 0.7, 1.0} are the categories. This is the literal methodology §8 / §12 measure. **May be inflated** if reviewers give correlated scores across the duplicates (all 6 rows get the same score from every reviewer → looks like agreement on 6 items but is really agreement on 1 underlying call).
- **`inter_rater_collapsed`** — Fleiss κ over the **distinct (plant_id, cluster_id) judgments** × N raters. Each (reviewer, judgment) cell reduces the 6 per-cell scores to a median, and κ is computed over those medians. Under round 2's single distinct judgment (N=1), the κ value is mathematically defined but has essentially zero statistical power — it collapses to a function of how the single judgment's 3 reviewer medians agree, with no across-item variance to anchor `P_e`. Treat the value as a sanity check, not a measure; the diagnostic fields (`within_reviewer_inconsistency_count`, `reviewer_variance`) carry the actionable signal. A future round that introduces a second distinct panel judgment would restore the collapsed κ's interpretive value.

A diagnostic field, `within_reviewer_inconsistency_count`, counts the (reviewer, judgment) cells where the reviewer's variance across duplicates was > 0. If this number is high, reviewers are sensitive to prose variation across trials — `inter_rater_collapsed`'s medians understate disagreement and `inter_rater` is the truer measure. If it's near zero (reviewers internally consistent across duplicates), the rec-level κ is inflated by item correlation and the collapsed diagnostics are the truer signal.

### Orphan rec_tokens (round-2 consequence)

`panel-scores-reviewer-1.jsonl` still carries the 6 Plant 3.1 panel scores from round 1 (the panel didn't know the gate would land). After regenerating `panel-routing.jsonl`, those 6 rec_tokens no longer map to any panel-routing row. Both κ functions (`attach_panel_kappa`, `attach_collapsed_panel_kappa`) filter them out and surface the orphan count in `inter_rater.note` / `inter_rater_collapsed.note`. `promote_panel_scores` silently skips orphans because there's no `score=PANEL_ROUTE` entry left to backfill (Plant 3.1's HSBColor pair is no longer in `scored`). Do NOT delete the orphan rows from `panel-scores-reviewer-1.jsonl` — they're audit-trail provenance and the filter handles them transparently.

### `inter_rater_collapsed` block schema

```json
{
  "fleiss_kappa": null,                      // null when m<2, n_judgments<2, uneven coverage, or sentinel path
  "n_judgments": 1,                           // distinct (plant_id, cluster_id) cells after orphan filter
  "n_raters": 3,                              // unique reviewer IDs seen in panel-scores
  "judgments": [
    {
      "plant_id": "5.1",
      "cluster_id": "function-duplicates-near:…",
      "n_duplicates_per_reviewer": {"reviewer-1": 6, "reviewer-2": 6, "reviewer-3": 6},
      "reviewer_medians": {"reviewer-1": 0.3, "reviewer-2": 0.3, "reviewer-3": 0.3},
      "reviewer_variance": {"reviewer-1": 0.0, "reviewer-2": 0.0, "reviewer-3": 0.0}
    }
  ],
  "within_reviewer_inconsistency_count": 0,   // # of (judgment, reviewer) cells with variance > 0
  "note": "6 orphan rec_token(s) in panel-scores had no matching panel-routing row; skipped"
}
```

`n_duplicates_per_reviewer` is per-reviewer because reviewers can cover different numbers of duplicates per judgment (e.g., one reviewer missed a row). `fleiss_kappa` is null and `note` is populated when: panel-scores is missing/empty, fewer than 2 reviewers contributed, reviewer coverage is uneven at the judgment level (some reviewer didn't score some judgment at all — Fleiss κ requires every item rated by exactly m raters), or — for the collapsed κ — only one distinct judgment exists.

### How to interpret the two κs together

| `inter_rater` κ | `inter_rater_collapsed` κ | Reading |
|---|---|---|
| High | High | Reviewers agree on the underlying calls AND on every duplicate. Confident rubric coverage. |
| High | Low | Reviewers agree on most duplicate rows by chance (e.g., all defaulting to 0.0 for "other"), but disagree on the underlying calls. `inter_rater` is inflated — trust the collapsed measure. |
| Low | High | Reviewers agree on the underlying calls but disagree on individual duplicates (prose-sensitive scoring). Calibration needed on prose vs substance — see `within_reviewer_inconsistency_count`. |
| Low | Low | Reviewers genuinely disagree on the calls. Rubric needs round-2 work. |

When the round-2 panel sitting completes, populate `inter_rater` and report it in `results.md` §4.3. `inter_rater_collapsed` will stay at the panel-pending sentinel under round 2's single-judgment configuration; the per-judgment diagnostics (`within_reviewer_inconsistency_count`, `reviewer_variance`) carry the cross-reviewer agreement signal. If `inter_rater` comes back surprisingly low while the diagnostics show consistent per-reviewer medians, that's a methodology gap to log in `rubric-modifications.md`.

The concentration on Plant 5.1 (after the round-2 symbol gate dropped Plant 3.1's false binding) is itself a finding: the agent consistently classifies HSBColor.uiColor / HSBColor.nsColor as "other" rather than as generic-parameterization. The plant manifest's category attribution may be too narrow for what the agent is seeing in this cluster, or the agent's prompt is steering it toward novel-category responses on this platform-bridging shape. Worth a debrief discussion after panel scores land.

## 7. Mechanical checklist

1. [ ] Read the methodology + rubric pointers above.
2. [ ] For each of the 6 rows in `analyses/panel-routing.jsonl` (post-round-2 symbol gate, all Plant 5.1): read the `rec_*` fields, **do not** look at `unblind`, score, write a row to your `panel-scores-<id>.jsonl`.
3. [ ] After scoring all 6, concatenate your file with the other reviewers' files into `analyses/panel-scores.jsonl` (any order; the scorer sorts internally).
4. [ ] Re-run `python3 experiments/v7-refactor-recommendation/score_all.py` so `analyses/score-summary.json` picks up the Fleiss κ. Confirm the `inter_rater.note` reports `6 orphan rec_token(s) ... skipped` — that's the expected round-2 orphan-filter signal.
5. [ ] If your κ comes back below 0.4 ("fair" agreement), schedule a debrief: differences in interpretation of "other" are a calibration problem the rubric needs to absorb in round 3.
