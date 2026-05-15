#!/usr/bin/env python3
"""Phase E PR-E2 — §14.1 substrate-helped signature check.

Reads the parsed-fields cache committed under
`experiments/v7-refactor-recommendation/trial-logs/parsed/<cond>/trial<n>/*.json`
(written by `parse_responses.py`, PR-E1) and computes per-query S1 vs S2
deltas. Emits a single JSON document at the path supplied by `--output`
(default `experiments/v7-refactor-recommendation/analyses/substrate-helped.json`),
plus a one-line console summary per query.

Pre-registered §14.1 signature check (methodology pre-mortem §14.1, the
"substrate didn't help" signature). Methodology §14.1 defines the failure
signature as "the per-plant recall delta between S0 and S2 sits within ±5
percentage points across all categories." Phase E plan §2.1 adapts this for
the MVP, which has no S0 condition: the check is run S1-vs-S2 across the
queries that exist in BOTH conditions (V7-only queries — `pat-candidates`,
`default-impl-candidates`, `protocol-inheritance-candidates`,
`generic-function-candidates`, `generic-struct-candidates` — are reported
separately under `v7_only_queries`).

Per-query criterion:

  - If `n_with_confidence` ≥ 60% of recs in BOTH conditions, the primary
    metric is `|mean_confidence_s2 − mean_confidence_s1|`. Substrate helped
    that query iff the delta exceeds the 5-percentage-point threshold (0.05
    on the 0–1 confidence scale).
  - Otherwise the primary metric falls back to category-distribution
    total-variation distance, with the same 0.05 threshold. (Phase E plan
    §6 decision #2: adopt 60% with a 50% console-warning floor.)

Aggregate criterion: substrate is considered to have helped overall iff a
**strict majority** of shared queries (`n_passed / n_shared_queries > 0.5`)
pass their per-query check. Anything weaker (half or fewer) → aggregate
fail, which is the §14.1 stop-the-line signature.

Run from the repo root:

  python3 experiments/v7-refactor-recommendation/analyses/substrate_helped.py
  python3 experiments/v7-refactor-recommendation/analyses/substrate_helped.py \\
      --parsed experiments/v7-refactor-recommendation/trial-logs/parsed \\
      --output experiments/v7-refactor-recommendation/analyses/substrate-helped.json
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

SCHEMA_VERSION = "1.0"
DEFAULT_CONFIDENCE_FALLBACK_THRESHOLD = 0.6  # methodology §14.1 + plan §6.2
DEFAULT_CONFIDENCE_WARNING_FLOOR = 0.5  # plan §6.2
DEFAULT_DELTA_SIGNIFICANT_THRESHOLD = 0.05  # methodology §14.1 (±5 percentage points)
DEFAULT_AGGREGATE_PASS_FRACTION = 0.5  # strict majority


def compute_category_distribution(records: list[dict]) -> dict[str, float]:
    """Proportion of recs falling into each `parsed.category` bucket.

    Parse-error records are excluded from the denominator.
    """
    cats = Counter()
    for r in records:
        if r.get("parse_error"):
            continue
        parsed = r.get("parsed") or {}
        cat = parsed.get("category")
        if cat is None:
            continue
        cats[cat] += 1
    total = sum(cats.values())
    if total == 0:
        return {}
    return {k: v / total for k, v in cats.items()}


def total_variation_distance(a: dict[str, float], b: dict[str, float]) -> float:
    """Total variation distance between two discrete distributions over the
    same support (computed as the union of their keys).
    """
    keys = set(a) | set(b)
    return 0.5 * sum(abs(a.get(k, 0.0) - b.get(k, 0.0)) for k in keys)


def _mean_confidence(records: list[dict]) -> tuple[float | None, int]:
    vals = []
    for r in records:
        if r.get("parse_error"):
            continue
        parsed = r.get("parsed") or {}
        c = parsed.get("confidence")
        if isinstance(c, (int, float)):
            vals.append(float(c))
    if not vals:
        return None, 0
    return sum(vals) / len(vals), len(vals)


def _good_records(records: list[dict]) -> list[dict]:
    return [r for r in records if not r.get("parse_error")]


def summarize_query(
    query: str,
    records_s1: list[dict],
    records_s2: list[dict],
    *,
    confidence_fallback_threshold: float = DEFAULT_CONFIDENCE_FALLBACK_THRESHOLD,
    delta_significant_threshold: float = DEFAULT_DELTA_SIGNIFICANT_THRESHOLD,
) -> dict:
    """Compute the per-query summary row for one query × (S1, S2).

    See module docstring for the §14.1 pass criterion.
    """
    good_s1 = _good_records(records_s1)
    good_s2 = _good_records(records_s2)
    n_s1 = len(good_s1)
    n_s2 = len(good_s2)

    mean_s1, n_conf_s1 = _mean_confidence(good_s1)
    mean_s2, n_conf_s2 = _mean_confidence(good_s2)
    coverage_s1 = n_conf_s1 / n_s1 if n_s1 else 0.0
    coverage_s2 = n_conf_s2 / n_s2 if n_s2 else 0.0

    dist_s1 = compute_category_distribution(records_s1)
    dist_s2 = compute_category_distribution(records_s2)
    dist_distance = total_variation_distance(dist_s1, dist_s2)

    delta_confidence: float | None
    if mean_s1 is not None and mean_s2 is not None:
        delta_confidence = mean_s2 - mean_s1
    else:
        delta_confidence = None

    confidence_usable = (
        delta_confidence is not None
        and coverage_s1 >= confidence_fallback_threshold
        and coverage_s2 >= confidence_fallback_threshold
    )
    primary_metric = "confidence-delta" if confidence_usable else "category-distribution"

    if confidence_usable:
        delta_significant = abs(delta_confidence) > delta_significant_threshold
        signature_pass = delta_significant
    else:
        delta_significant = (
            abs(delta_confidence) > delta_significant_threshold
            if delta_confidence is not None
            else False
        )
        signature_pass = dist_distance > delta_significant_threshold

    return {
        "query": query,
        "n_s1": n_s1,
        "n_s2": n_s2,
        "n_with_confidence_s1": n_conf_s1,
        "n_with_confidence_s2": n_conf_s2,
        "confidence_coverage_s1": coverage_s1,
        "confidence_coverage_s2": coverage_s2,
        "mean_confidence_s1": mean_s1,
        "mean_confidence_s2": mean_s2,
        "delta_confidence": delta_confidence,
        "delta_significant": delta_significant,
        "category_dist_s1": dist_s1,
        "category_dist_s2": dist_s2,
        "category_dist_distance": dist_distance,
        "primary_metric": primary_metric,
        "signature_pass": signature_pass,
    }


def _bucket_by_query_and_condition(
    records: list[dict],
) -> dict[tuple[str, str], list[dict]]:
    buckets: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for r in records:
        buckets[(r["query"], r["condition"])].append(r)
    return buckets


def analyze(
    records: list[dict],
    *,
    confidence_fallback_threshold: float = DEFAULT_CONFIDENCE_FALLBACK_THRESHOLD,
    delta_significant_threshold: float = DEFAULT_DELTA_SIGNIFICANT_THRESHOLD,
    aggregate_pass_fraction: float = DEFAULT_AGGREGATE_PASS_FRACTION,
) -> dict:
    """Compute the full substrate-helped report from a flat list of parsed records.

    Returns a deterministic, JSON-serializable dict. Keys are produced in a
    stable order; callers should still write with `sort_keys=True` for
    byte-identical re-runs.
    """
    buckets = _bucket_by_query_and_condition(records)
    queries_s1 = {q for (q, c) in buckets if c == "s1"}
    queries_s2 = {q for (q, c) in buckets if c == "s2"}
    shared = sorted(queries_s1 & queries_s2)
    v7_only = sorted(queries_s2 - queries_s1)
    s1_only = sorted(queries_s1 - queries_s2)

    per_query = []
    n_passed = 0
    for q in shared:
        row = summarize_query(
            q,
            buckets[(q, "s1")],
            buckets[(q, "s2")],
            confidence_fallback_threshold=confidence_fallback_threshold,
            delta_significant_threshold=delta_significant_threshold,
        )
        if row["signature_pass"]:
            n_passed += 1
        per_query.append(row)

    n_recs_total = len(records)
    n_parse_errors = sum(1 for r in records if r.get("parse_error"))

    aggregate = {
        "n_shared_queries": len(shared),
        "n_passed": n_passed,
        "pass_fraction": (n_passed / len(shared)) if shared else 0.0,
        "signature_pass": (n_passed / len(shared) if shared else 0.0) > aggregate_pass_fraction,
        "explanation": _aggregate_explanation(n_passed, len(shared)),
    }

    return {
        "schema_version": SCHEMA_VERSION,
        "config": {
            "confidence_fallback_threshold": confidence_fallback_threshold,
            "confidence_warning_floor": DEFAULT_CONFIDENCE_WARNING_FLOOR,
            "delta_significant_threshold": delta_significant_threshold,
            "aggregate_pass_fraction": aggregate_pass_fraction,
        },
        "n_recs_total": n_recs_total,
        "n_parse_errors": n_parse_errors,
        "per_query": per_query,
        "v7_only_queries": v7_only,
        "s1_only_queries": s1_only,
        "aggregate": aggregate,
    }


def _aggregate_explanation(n_passed: int, n_shared: int) -> str:
    if n_shared == 0:
        return "no shared queries (cannot run S1-vs-S2 §14.1 check)"
    frac = n_passed / n_shared
    if frac > DEFAULT_AGGREGATE_PASS_FRACTION:
        return (
            f"{n_passed}/{n_shared} shared queries show S2−S1 substrate effect; "
            "substrate helped per §14.1."
        )
    return (
        f"only {n_passed}/{n_shared} shared queries show S2−S1 substrate effect; "
        "§14.1 stop-the-line signature: substrate did not help across the shared corpus. "
        "Diagnose per-category breakdown before round 2."
    )


# ─── parsed-cache loader ──────────────────────────────────────────────────


def _iter_parsed_files(parsed_dir: Path):
    for cond_dir in sorted(parsed_dir.iterdir()):
        if not cond_dir.is_dir():
            continue
        for trial_dir in sorted(cond_dir.iterdir()):
            if not trial_dir.is_dir():
                continue
            for f in sorted(trial_dir.glob("*.json")):
                yield f


def load_parsed_records(parsed_dir: Path) -> list[dict]:
    """Walk `trial-logs/parsed/` and return every parsed record as a flat list."""
    records: list[dict] = []
    for f in _iter_parsed_files(parsed_dir):
        records.append(json.loads(f.read_text()))
    return records


# ─── CLI ──────────────────────────────────────────────────────────────────


def _format_console_row(row: dict) -> str:
    metric = row["primary_metric"]
    if metric == "confidence-delta":
        primary = f"Δconf={row['delta_confidence']:+.3f}" if row["delta_confidence"] is not None else "Δconf=n/a"
    else:
        primary = f"TVD={row['category_dist_distance']:.3f}"
    status = "PASS" if row["signature_pass"] else "fail"
    return (
        f"  [{status}] {row['query']:<42} n_s1={row['n_s1']:>4} n_s2={row['n_s2']:>4} "
        f"cov_s1={row['confidence_coverage_s1']:.2f} cov_s2={row['confidence_coverage_s2']:.2f} "
        f"{primary} (primary={metric})"
    )


def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).resolve().parent
    exp_dir = here.parent
    default_parsed = exp_dir / "trial-logs" / "parsed"
    default_output = here.parent / "analyses" / "substrate-helped.json"

    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--parsed",
        type=Path,
        default=default_parsed,
        help="Path to the parsed-cache root (default: experiments/v7-refactor-recommendation/trial-logs/parsed).",
    )
    ap.add_argument(
        "--output",
        type=Path,
        default=default_output,
        help="Path to write the substrate-helped JSON document.",
    )
    ap.add_argument(
        "--confidence-fallback-threshold",
        type=float,
        default=DEFAULT_CONFIDENCE_FALLBACK_THRESHOLD,
    )
    ap.add_argument(
        "--delta-significant-threshold",
        type=float,
        default=DEFAULT_DELTA_SIGNIFICANT_THRESHOLD,
    )
    args = ap.parse_args(argv)

    if not args.parsed.is_dir():
        print(f"error: --parsed path is not a directory: {args.parsed}", file=sys.stderr)
        return 2

    records = load_parsed_records(args.parsed)
    if not records:
        print(f"error: no parsed records found under {args.parsed}", file=sys.stderr)
        return 2

    doc = analyze(
        records,
        confidence_fallback_threshold=args.confidence_fallback_threshold,
        delta_significant_threshold=args.delta_significant_threshold,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")

    print(
        f"substrate_helped: n_recs={doc['n_recs_total']} parse_errors={doc['n_parse_errors']} "
        f"shared_queries={doc['aggregate']['n_shared_queries']} "
        f"v7_only={len(doc['v7_only_queries'])}",
        file=sys.stderr,
    )
    for row in doc["per_query"]:
        print(_format_console_row(row), file=sys.stderr)
        if min(row["confidence_coverage_s1"], row["confidence_coverage_s2"]) < DEFAULT_CONFIDENCE_WARNING_FLOOR:
            print(
                f"  WARN: confidence coverage below {DEFAULT_CONFIDENCE_WARNING_FLOOR:.0%} floor on {row['query']}",
                file=sys.stderr,
            )
    agg = doc["aggregate"]
    print(
        f"aggregate: {agg['n_passed']}/{agg['n_shared_queries']} passed → signature_pass={agg['signature_pass']}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
