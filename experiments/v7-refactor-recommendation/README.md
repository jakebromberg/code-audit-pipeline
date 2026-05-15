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
| `trial-logs/` | D | Per-recommendation telemetry sidecar (written by [`scripts/phase-d-harness.py`](../../scripts/phase-d-harness.py); see [`scripts/harness/README.md`](../../scripts/harness/README.md)) |
| `rubric-modifications.md` | D/E | Post-hoc rubric adjustments, if any |
| `results.md` | E | Companion results doc, structured like V5/V6 results |

## See also

- [`docs/refactor-recommendation-experiment-methodology.md`](../../docs/refactor-recommendation-experiment-methodology.md)
- [`docs/refactor-recommendation-experiment-plant-manifest.md`](../../docs/refactor-recommendation-experiment-plant-manifest.md)
- [`docs/refactor-recommendation-experiment-agent-prompt.md`](../../docs/refactor-recommendation-experiment-agent-prompt.md)
- [`docs/refactor-recommendation-experiment-macro-candidates.md`](../../docs/refactor-recommendation-experiment-macro-candidates.md) (round 2 reference)
- [`plans/v7-refactor-recommendation-implementation-plan.md`](../../plans/v7-refactor-recommendation-implementation-plan.md)
