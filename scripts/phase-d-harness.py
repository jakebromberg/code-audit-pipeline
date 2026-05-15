#!/usr/bin/env python3
"""V7 Phase D trial harness.

Walks `experiments/v7-refactor-recommendation/clusters-<condition>/*.jsonl`,
normalizes each row to the agent-prompt §3 input shape, renders the prompt,
calls `/v1/messages` against the pinned Sonnet 4.6 alias, and writes per-
recommendation telemetry. Cost-control gates from plan §6.3 run inline.

Usage:
  ANTHROPIC_API_KEY=... \\
    scripts/phase-d-harness.py --condition s2 --trial 1 \\
                               --out experiments/v7-refactor-recommendation/trial-logs/

CLI:
  --condition s1|s2   (required)
  --trial 1|2|3       (required)
  --out <dir>         (default: experiments/v7-refactor-recommendation/trial-logs/)
  --queries q1,q2,... (optional: restrict to these query types)
  --max-rows N        (optional: cap the per-condition row count, smoke-run aid)
  --budget-usd USD    (optional: per (condition, trial) envelope; default $3.50)
  --no-pause          (don't pause on mid-run signature-check fires; log only)
  --dry-run           (skip API calls; just normalize, render, and report)

Resume semantics: re-running with the same --out continues from the first
row missing its per-cluster telemetry file. Successful telemetry is never
overwritten — to re-run a row, delete its telemetry file.

Cost / token gates (plan §6.3):
  - per-rec combined token cap: 50,000 → `error_class: trial-overrun`
  - per-(condition, trial) $-budget: default $3.50 (plan §6.3 reference, scoped
    for 150-rec runs); overridable via `--budget-usd`. 80% alert, 100% halt.
    All-rows production runs pass `--budget-usd 12` to clear S2's ~525 rows.
  - mid-run §14.1 / §14.4 signature checks at 25% completion of (cond,trial)
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
from pathlib import Path

# Make `harness` importable when invoked as `python3 scripts/phase-d-harness.py`.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness import (
    BudgetState,
    PER_CONDITION_BUDGET_USD,
    cost_for_usage,
    extract_prompt_body,
    extract_recommendation_array,
    list_completed_cluster_ids,
    normalize_row,
    render,
    sanitize_cluster_id,
    write_telemetry,
)
from harness.api import build_payload, call_messages, extract_text
from harness.checks import (
    check_batching_variance,
    check_substrate_helped,
    should_run_midrun_checks,
)
from harness.extract import ExtractError
from harness.gates import is_token_overrun

REPO_ROOT = Path(__file__).resolve().parent.parent
EXP_DIR = REPO_ROOT / "experiments" / "v7-refactor-recommendation"
PROMPT_DOC = REPO_ROOT / "docs" / "refactor-recommendation-experiment-agent-prompt.md"
DEFAULT_OUT = EXP_DIR / "trial-logs"


def _log(msg: str) -> None:
    """Stderr log with ISO-8601 timestamp."""
    print(f"[{dt.datetime.now().isoformat(timespec='seconds')}] {msg}", file=sys.stderr)


def _load_rows(condition: str, queries: set[str] | None) -> list[tuple[str, int, dict]]:
    """Walk clusters-<condition>/*.jsonl and return [(query, row_index, raw_row), ...].

    Malformed JSON lines are logged and skipped — one corrupt line shouldn't
    abort a multi-hundred-row run before any telemetry is written. `row_index`
    tracks raw line offsets (including blanks/skipped) so the telemetry value
    points back to a forensically reproducible position in the source file.
    """
    cluster_dir = EXP_DIR / f"clusters-{condition}"
    if not cluster_dir.is_dir():
        raise SystemExit(f"ERROR: cluster dir not found: {cluster_dir}")
    rows: list[tuple[str, int, dict]] = []
    for path in sorted(cluster_dir.glob("*.jsonl")):
        query = path.stem
        if queries and query not in queries:
            continue
        with path.open() as f:
            for idx, line in enumerate(f):
                line = line.strip()
                if not line:
                    continue
                try:
                    parsed = json.loads(line)
                except json.JSONDecodeError as e:
                    _log(f"  skip malformed JSON in {path.name} line {idx}: {e}")
                    continue
                rows.append((query, idx, parsed))
    return rows


def _maybe_run_midrun_checks(
    rows_done: int,
    rows_total: int,
    *,
    condition: str,
    trial: int,
    out_root: Path,
    per_cluster_categories: dict[str, list[str]],
    confidences: list[float],
    pause: bool,
) -> bool:
    """Run §14.1 / §14.4 checks if at the 25% mark. Returns True if a check fired."""
    if not should_run_midrun_checks(rows_done, rows_total):
        return False
    fired = False
    var_result = check_batching_variance(per_cluster_categories)
    _log(f"midrun §14.4 ({var_result.fired=}): {var_result.reason}")
    if var_result.fired:
        fired = True

    # §14.1 needs S1 vs S2 paired data; on a single condition trial we can only
    # populate one side. Read the other side's confidences from disk if present.
    other_condition = "s2" if condition == "s1" else "s1"
    other_confidences = _read_confidences(out_root, other_condition, trial)
    if condition == "s1":
        s1_confs, s2_confs = confidences, other_confidences
    else:
        s1_confs, s2_confs = other_confidences, confidences
    sh_result = check_substrate_helped(s1_confs, s2_confs)
    _log(f"midrun §14.1 ({sh_result.fired=}): {sh_result.reason}")
    if sh_result.fired:
        fired = True

    if fired and pause:
        _log("PAUSE: a signature check fired. Inspect telemetry, then press ENTER to continue (or Ctrl-C to abort).")
        try:
            input()
        except (EOFError, KeyboardInterrupt):
            raise SystemExit("aborted at midrun-check pause")
    return fired


def _read_confidences(out_root: Path, condition: str, trial: int) -> list[float]:
    """Return the other-condition's confidences for cross-condition §14.1.

    The current telemetry schema records API metadata (tokens, latency, cost,
    model id) and a pointer to the raw response — but not the parsed
    confidence value. So at §6.2 scope, this function always returns [] and
    §14.1 self-skips (its `if not s1 or not s2: skip` branch covers this).
    The full cross-condition reanalysis lives in §6.3 / Phase E and walks
    `raw_response_path` to extract confidences and categories from disk.
    """
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--condition", required=True, choices=("s1", "s2"))
    parser.add_argument("--trial", required=True, type=int, choices=(1, 2, 3))
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--queries", type=str, default="",
                        help="comma-separated query names to restrict the run to")
    parser.add_argument("--max-rows", type=int, default=0,
                        help="cap rows per condition (smoke-run aid; 0 = no cap)")
    parser.add_argument("--budget-usd", type=float, default=PER_CONDITION_BUDGET_USD,
                        help=f"per (condition, trial) $-budget envelope. "
                             f"Default ${PER_CONDITION_BUDGET_USD:.2f} matches plan §6.3's "
                             f"reference value (scoped for 150-rec runs). All-rows runs "
                             f"against the full cluster output need ~$12 to clear S2's "
                             f"~525 rows at the §5.3 dry-run cost/rec.")
    parser.add_argument("--no-pause", action="store_true",
                        help="don't pause on signature-check fires; log only")
    parser.add_argument("--dry-run", action="store_true",
                        help="skip API calls; just normalize, render, and report")
    args = parser.parse_args()

    out_root: Path = args.out.resolve()
    out_root.mkdir(parents=True, exist_ok=True)

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not api_key and not args.dry_run:
        print("ERROR: ANTHROPIC_API_KEY must be set in env (or pass --dry-run)", file=sys.stderr)
        return 1

    queries = {q.strip() for q in args.queries.split(",") if q.strip()} if args.queries else None

    all_rows = _load_rows(args.condition, queries)
    if args.max_rows > 0:
        all_rows = all_rows[: args.max_rows]
    _log(f"loaded {len(all_rows)} rows from clusters-{args.condition}/")

    completed = list_completed_cluster_ids(out_root, args.condition, args.trial)
    _log(f"resume: {len(completed)} cluster ids already have telemetry; skipping those")

    # Filter inline rather than threading (idx, raw) through filter_incomplete:
    # `idx` is the row's offset within its JSONL file and is NOT unique across
    # files, so re-attaching the `query` via a {idx: query} dict would silently
    # mis-key rows whose offsets collide between files. Keep the (query, idx,
    # raw) tuple intact through the filter step.
    pending_full = [
        (q, idx, raw)
        for (q, idx, raw) in all_rows
        if sanitize_cluster_id(raw.get("cluster_id", "")) not in completed
    ]
    _log(f"pending after resume filter: {len(pending_full)} rows")

    prompt_doc_text = PROMPT_DOC.read_text()
    instructions, specifics = extract_prompt_body(prompt_doc_text)

    budget = BudgetState(budget_usd=args.budget_usd)
    per_cluster_categories: dict[str, list[str]] = {}
    confidences: list[float] = []
    rows_total = len(all_rows)
    rows_done = len(completed)
    midrun_done = False

    for query, row_index, raw_row in pending_full:
        cluster_id = raw_row.get("cluster_id", "")
        rows_done += 1

        if budget.is_halted:
            _log(f"HALT: budget reached for condition {args.condition}; stopping.")
            break

        try:
            normalized = normalize_row(raw_row)
        except ValueError as e:
            _log(f"  skip {cluster_id!r}: {e}")
            write_telemetry(
                out_root, args.condition, args.trial, cluster_id,
                query=query, row_index=row_index,
                input_tokens=0, output_tokens=0, latency_ms=0, cost_usd=0.0,
                error_class="normalizer-unsupported",
                response_model=None, response_id=None, raw_response=None,
            )
            continue

        user_message = render(instructions, specifics, normalized)

        if args.dry_run:
            _log(f"  dry-run: would call API for {cluster_id} ({len(user_message)} chars)")
            continue

        payload = build_payload(user_message)
        resp = call_messages(payload, api_key)

        usage = (resp.body.get("usage") or {})
        input_tokens = int(usage.get("input_tokens", 0))
        output_tokens = int(usage.get("output_tokens", 0))
        cost = cost_for_usage(input_tokens, output_tokens)
        response_model = resp.body.get("model")
        response_id = resp.body.get("id")

        error_class: str | None = None
        if resp.status != 200:
            error_class = f"api-status-{resp.status}"
        elif is_token_overrun(input_tokens, output_tokens):
            error_class = "trial-overrun"
        else:
            text = extract_text(resp.body)
            try:
                arr = extract_recommendation_array(text)
                if len(arr) != 1:
                    error_class = "wrong-array-length"
                else:
                    rec = arr[0]
                    per_cluster_categories.setdefault(cluster_id, []).append(rec.get("category", ""))
                    if isinstance(rec.get("confidence"), (int, float)):
                        confidences.append(float(rec["confidence"]))
            except ExtractError as e:
                error_class = e.error_class

        gate_state = budget.add(cost)
        if gate_state == "alert":
            _log(f"ALERT: condition {args.condition} crossed 80% of ${args.budget_usd:.2f} budget "
                 f"(spent ${budget.spent_usd:.4f})")
        elif gate_state == "halt":
            _log(f"HALT: condition {args.condition} crossed ${args.budget_usd:.2f} budget "
                 f"(spent ${budget.spent_usd:.4f}); will stop after this row")

        write_telemetry(
            out_root, args.condition, args.trial, cluster_id,
            query=query, row_index=row_index,
            input_tokens=input_tokens, output_tokens=output_tokens,
            latency_ms=resp.latency_ms, cost_usd=cost,
            error_class=error_class,
            response_model=response_model, response_id=response_id,
            raw_response=resp.body,
        )

        _log(f"  [{rows_done}/{rows_total}] {cluster_id[:60]}: "
             f"{input_tokens}+{output_tokens}tok, {resp.latency_ms}ms, ${cost:.5f}, err={error_class}")

        if not midrun_done and should_run_midrun_checks(rows_done, rows_total):
            _maybe_run_midrun_checks(
                rows_done, rows_total,
                condition=args.condition, trial=args.trial, out_root=out_root,
                per_cluster_categories=per_cluster_categories,
                confidences=confidences,
                pause=not args.no_pause,
            )
            midrun_done = True

    _log(f"done: spent ${budget.spent_usd:.4f} / ${args.budget_usd:.2f} for condition {args.condition} trial {args.trial}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
