# Phase D trial harness

V7 §6.2: drives one (condition, trial) run of the refactor-recommendation experiment. Walks the cluster JSONL outputs, normalizes each row to the agent-prompt §3 input shape, calls the pinned Sonnet 4.6 alias via `/v1/messages`, and writes per-recommendation telemetry. Cost-control gates from plan §6.3 run inline; mid-run §14.1 / §14.4 signature checks fire at the 25% completion mark.

The harness is intentionally split into small modules so the unit tests in [`pipeline/queries/_tests/test_phase_d_harness.py`](../../pipeline/queries/_tests/test_phase_d_harness.py) can drive each piece without HTTP. The production run in §6.3 only has to trust the well-tested primitives.

## Layout

| File | Purpose |
|---|---|
| [`../phase-d-harness.py`](../phase-d-harness.py) | CLI entry; orchestration loop |
| `prompt.py` | Cluster-row normalization + prompt rendering (also used by `render-prompt.py`) |
| `extract.py` | Fence-aware JSON-array extraction from the model response |
| `api.py` | `/v1/messages` HTTP wrapper with an injectable transport for tests |
| `gates.py` | Per-rec token cap + per-condition $-budget accounting |
| `checks.py` | §14.1 (substrate-helped) and §14.4 (batching-variance) signature checks |
| `telemetry.py` | Per-rec JSON writer with atomic-rename + resume support |

## Quickstart

```bash
export ANTHROPIC_API_KEY=sk-ant-...
scripts/phase-d-harness.py --condition s2 --trial 1
```

By default writes to `experiments/v7-refactor-recommendation/trial-logs/`. Override with `--out <dir>`.

### Smoke run

```bash
# Process at most 5 rows; pause skipped; no API key required.
scripts/phase-d-harness.py --condition s2 --trial 1 --max-rows 5 --dry-run --no-pause
```

### Restricting queries

```bash
# Only process pat-candidates and exact-duplicates rows.
scripts/phase-d-harness.py --condition s2 --trial 1 \
    --queries pat-candidates,exact-duplicates
```

## Environment variables

| Var | Required | Notes |
|---|---|---|
| `ANTHROPIC_API_KEY` | yes (unless `--dry-run`) | Never logged. Passed via header `x-api-key`. |

## CLI flags

| Flag | Default | Notes |
|---|---|---|
| `--condition s1\|s2` | required | Which substrate condition to draw clusters from. |
| `--trial 1\|2\|3` | required | Which of the n=3 trials per condition. |
| `--out <dir>` | `experiments/v7-refactor-recommendation/trial-logs/` | Telemetry root. |
| `--queries q1,q2,...` | (all) | Restrict to these query names. |
| `--max-rows N` | 0 (no cap) | Smoke-run aid. |
| `--no-pause` | off | On signature-check fire, log only and continue. |
| `--dry-run` | off | Skip API calls; just normalize, render, report. |

## Telemetry layout

```
<out>/
├── s1/
│   └── trial1/
│       ├── <sanitized-cluster-id>.json     # per-rec metadata
│       └── ...
├── s2/
│   ├── trial1/
│   ├── trial2/
│   └── trial3/
└── raw/
    └── s2/trial1/<sanitized-cluster-id>.json  # verbatim API response
```

Per-rec record fields:

```json
{
  "cluster_id": "<verbatim cluster_id from the row>",
  "condition": "s1|s2",
  "trial": 1,
  "query": "pat-candidates",
  "row_index": 0,
  "input_tokens": 2735,
  "output_tokens": 643,
  "latency_ms": 21259,
  "cost_usd": 0.01785,
  "error_class": null,
  "response_model": "claude-sonnet-4-6",
  "response_id": "msg_xxx",
  "raw_response_path": "raw/s2/trial1/<sanitized-cluster-id>.json"
}
```

`response_model` is the §6.1 drift-detection field — if Anthropic re-points the bare `claude-sonnet-4-6` alias mid-experiment, the change is visible here.

### `error_class` values

| Value | Meaning |
|---|---|
| `null` | Success: model returned a valid 1-element recommendation array. |
| `trial-overrun` | Per-rec token cap (50K combined) exceeded. |
| `api-status-<NNN>` | Non-200 from `/v1/messages` after retries. |
| `no-array` | Model response contained no JSON array. |
| `json-parse-error` | Array text was present but not parseable. |
| `not-a-list` | Parsed JSON wasn't a list. |
| `wrong-array-length` | Got an array, but length ≠ 1. |
| `normalizer-unsupported` | Cluster row's `query` field isn't covered by the §3 normalizer. |

## Resume semantics

Re-running the harness with the same `--out` continues from the first row whose per-cluster telemetry file is missing. The harness lists `<out>/<condition>/trial<n>/*.json` at start, builds the set of sanitized cluster ids already covered, and skips any row whose sanitized id is in that set.

To force a re-run of a specific row: delete its telemetry file (and optionally its raw response under `<out>/raw/<condition>/trial<n>/<sanitized>.json`).

## Cost-control gates (plan §6.3)

| Gate | Threshold | Behavior |
|---|---|---|
| Per-rec token cap | 50,000 combined input+output | Recorded with `error_class: "trial-overrun"`; continue with next row. |
| Per-condition $-alert | 80% of $3.50 | Log a warning, continue. Fires once per condition state. |
| Per-condition $-halt | 100% of $3.50 | Stop the loop after writing the current row's telemetry. Subsequent rows are not processed. |

Pricing comes from `reproducibility.yaml > execution.api_pricing_snapshot` ($3.00 input + $15.00 output per million tokens for Sonnet 4.6).

## Mid-run signature checks

After 25% of the (condition, trial) rows have been processed, the harness runs:

- **§14.4 batching-variance**: across-trial category agreement for the same cluster. Self-skips on the first trial of any condition (no across-trial data yet).
- **§14.1 substrate-helped**: S2 vs S1 mean confidence delta. Self-skips at §6.2 scope because the telemetry record doesn't carry confidence — full cross-condition analysis is §6.3 / Phase E.

By default the harness pauses for human review on a fire (press ENTER to continue, Ctrl-C to abort). Pass `--no-pause` to log and continue.

## Recovery

| Situation | Action |
|---|---|
| Killed mid-run (Ctrl-C, OOM, network drop) | Re-run with same `--out` — resume picks up from the first missing telemetry file. |
| Single row with `error_class != null` to retry | `rm <out>/<condition>/trial<n>/<sanitized-cluster-id>.json` and re-run. |
| Whole trial corrupted | `rm -rf <out>/<condition>/trial<n>/` and re-run. |
| Condition halted on budget | Inspect telemetry; if intentional, raise budget or wait for billing window. Re-run resumes naturally. |

## Tests

```bash
pipeline/queries/_tests/test_phase_d_harness.sh
```

27 unit tests cover fence extraction, cost gates, signature-check trigger and outcomes, telemetry write/resume, mocked-HTTP round-trip. No live API calls.

## See also

- [V7 implementation plan §6](../../plans/v7-refactor-recommendation-implementation-plan.md) — phase D scope.
- [`reproducibility.yaml`](../../experiments/v7-refactor-recommendation/reproducibility.yaml) — pinned model id, parameters, pricing snapshot.
- [`refactor-recommendation-experiment-methodology.md`](../../docs/refactor-recommendation-experiment-methodology.md) — §10 reproducibility checklist, §14 failure-mode signatures.
- [`refactor-recommendation-experiment-agent-prompt.md`](../../docs/refactor-recommendation-experiment-agent-prompt.md) — §1 prompt body, §2 specifics schemas, §3 normalized input shape.
