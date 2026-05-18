# V7 refactor-recommendation experiment

Experiment artifacts directory. The experiment measures whether the substrate's cluster outputs can be converted into actionable refactor recommendations, by category. Per the [methodology doc](../../docs/refactor-recommendation-experiment-methodology.md) and the [implementation plan](../../plans/v7-refactor-recommendation-implementation-plan.md).

This directory is the shell. Each phase populates it:

| File / dir | Phase | Purpose |
|---|---|---|
| `plant-manifest.yaml` | A | Per-plant ground-truth manifest; replaces the [companion-doc schema](../../docs/refactor-recommendation-experiment-plant-manifest.md) once populated |
| `manifest-review-notes.md` | A | `/review-plan` reviewer notes for the manifest |
| `prompt.md` | A | Frozen copy of the [agent prompt](../../docs/refactor-recommendation-experiment-agent-prompt.md), hash-pinned in `reproducibility.yaml` |
| `rubric.yaml` | A | Machine-readable rubric extracted from methodology §8 |
| `clusters-s1/`, `clusters-s2/` | C | Cluster JSONL outputs per condition |
| `reproducibility.yaml` | D | Hash-pinned inputs (repo_sha, model_versions, api_pricing_snapshot, etc.) |
| `trial-logs/raw/`, `trial-logs/<cond>/` | D | Per-recommendation raw response bodies + telemetry sidecar (written by [`scripts/phase-d-harness.py`](../../scripts/phase-d-harness.py); see [`scripts/harness/README.md`](../../scripts/harness/README.md)) |
| `parse_responses.py`, `trial-logs/parsed/` | E | Idempotent fence-aware parser + parsed-fields cache (PR-E1); see [Phase E plan §1](../../plans/v7-phase-e-scoring-and-writeup-plan.md) |
| `analyses/substrate_helped.py`, `analyses/plant_recall_extended.py`, `analyses/*.json` | E | §14.1 substrate-helped signature check + plant-recall confirm against parsed categories (PR-E2); see [Phase E plan §2](../../plans/v7-phase-e-scoring-and-writeup-plan.md) |
| `score_all.py`, `analyses/auto-scores.json`, `analyses/score-summary.json`, `analyses/panel-routing.jsonl`, `analyses/panel-unblind.json`, `analyses/panel-instructions.md` | E | Bulk auto-scorer run + panel-routing artifact + unblind map + panel instructions; Fleiss κ wired into `score-summary.json::inter_rater` once `analyses/panel-scores.jsonl` lands (PR-E3); see [Phase E plan §3](../../plans/v7-phase-e-scoring-and-writeup-plan.md) |
| `analyses/panel-scores-reviewer-*.jsonl`, `analyses/panel-scores.jsonl` | E | Per-reviewer panel-sitting scores + consolidated file. `score_all.py::promote_panel_scores` backfills these into `auto-scores.json::scored` so per-cell `best_score` (and the headline) reflect panel-resolved values. Round 1 ran with 1 expert reviewer (Fleiss κ pending m≥2 in round 2); see [`reproducibility.yaml::execution.panel_composition.round1_deviation`](reproducibility.yaml). |
| `rubric-modifications.md` | D/E | Post-hoc rubric adjustments, if any |
| `results.md` | E | Companion results doc, structured like V5/V6 results |

## See also

- [`docs/refactor-recommendation-experiment-methodology.md`](../../docs/refactor-recommendation-experiment-methodology.md)
- [`docs/refactor-recommendation-experiment-plant-manifest.md`](../../docs/refactor-recommendation-experiment-plant-manifest.md)
- [`docs/refactor-recommendation-experiment-agent-prompt.md`](../../docs/refactor-recommendation-experiment-agent-prompt.md)
- [`docs/refactor-recommendation-experiment-macro-candidates.md`](../../docs/refactor-recommendation-experiment-macro-candidates.md) (round 2 reference)
- [`plans/v7-refactor-recommendation-implementation-plan.md`](../../plans/v7-refactor-recommendation-implementation-plan.md)
