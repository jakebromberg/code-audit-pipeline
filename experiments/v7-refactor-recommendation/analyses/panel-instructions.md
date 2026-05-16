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

## 6. Round-1 panel coverage

The 12 panel-routed recs concentrate on two plants:

- **Plant 3.1** (default-implementation): 6 recs (3 in S1, 3 in S2 — one per trial each)
- **Plant 5.1** (generic-parameterization): 6 recs (3 in S1, 3 in S2)

Each reviewer scores all 12 recs. Total panel-pair count: 12 recs × 3 reviewers = 36 score rows. Inter-rater κ is computed over the 12 items × 3 raters, with the score buckets {-0.5, 0.0, 0.3, 0.5, 0.7, 1.0} as categories.

The concentration on Plants 3.1 and 5.1 is itself a finding: the agent consistently classifies these two plants' clusters as "other" rather than as their manifest-pinned categories. The plant manifest's category attribution may be too narrow for what the agent is seeing in these clusters, or the agent's prompt is steering it toward novel-category responses on these structural shapes. Worth a debrief discussion after panel scores land.

## 7. Mechanical checklist

1. [ ] Read the methodology + rubric pointers above.
2. [ ] For each of the 12 rows in `analyses/panel-routing.jsonl`: read the `rec_*` fields, **do not** look at `unblind`, score, write a row to your `panel-scores-<id>.jsonl`.
3. [ ] After scoring all 12, concatenate your file with the other two reviewers' files into `analyses/panel-scores.jsonl` (any order; the scorer sorts internally).
4. [ ] Re-run `python3 experiments/v7-refactor-recommendation/score_all.py` so `analyses/score-summary.json` picks up the Fleiss κ.
5. [ ] If your κ comes back below 0.4 ("fair" agreement), schedule a debrief: differences in interpretation of "other" are a calibration problem the rubric needs to absorb in round 2.
