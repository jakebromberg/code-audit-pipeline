#!/usr/bin/env python3
"""V7 round-3 prompt-sensitivity sub-experiment — drift-check 30-rec sample.

Per plans/v7-round2-prompt-sensitivity-plan.md §3.2: before authorizing the
full v2 rerun (~$39), call Sonnet 4.6 once per rec against 30 round-2
records re-rendered with the unchanged v1 prompt and compare to the stored
round-2 response. If category disagreement, specifics-key drift, or panel-
route rate move outside the pre-registered tolerances, halt and file a
follow-up issue.

Three pre-registered metrics (plan §3.2):

  - category_disagreement_max_count        ≤ 6 of 30      (20%)
  - specifics_key_drift_max_avg_pct        ≤ 30%          (Jaccard symmetric
                                                          difference / union)
  - panel_route_delta_max_pp               ≤ 10 pp        (drift_pct - r2_pct)

Sampling: 5 plant categories × 2 conditions × 3 recs = 30, sorted by
(plant_id, cluster_id, trial) and drawn with random.Random(seed=20260520)
for byte-deterministic selection across reruns.

Usage:
  python3 scripts/drift_check.py                       # full run (API spend)
  python3 scripts/drift_check.py --dry-run             # print sample only
  python3 scripts/drift_check.py --sample-only         # write sample JSON;
                                                       # skip API calls
"""

from __future__ import annotations

import argparse
import datetime as _dt
import importlib.util
import json
import os
import random
import sys
from collections import Counter
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
EXP_DIR = REPO_ROOT / "experiments" / "v7-refactor-recommendation"
ANALYSES_V2_DIR = EXP_DIR / "analyses-v2"
PROMPT_V1_DOC = REPO_ROOT / "docs" / "refactor-recommendation-experiment-agent-prompt.md"

# Make `harness` and `parse_responses` importable.
sys.path.insert(0, str(REPO_ROOT / "scripts"))
sys.path.insert(0, str(EXP_DIR))

# Pre-registered constants (frozen by PR 1 / rubric-modifications.md round-3).
SAMPLING_SEED = 20260520
PER_STRATUM = 3
PLANT_CATEGORIES = (
    "extract-to-common",
    "protocol-inheritance",
    "default-implementation",
    "pat-introduction",
    "generic-parameterization",
)
CONDITIONS = ("s1", "s2")
SAMPLE_SIZE = len(PLANT_CATEGORIES) * len(CONDITIONS) * PER_STRATUM

# Pin the model alias explicitly so a future change to harness_api.DEFAULT_MODEL
# does NOT silently retarget the drift-check. Plan §3.2 names Sonnet 4.6 as the
# model the round-2 control was rendered against; this constant freezes that
# decision in the script that consumes it.
MODEL_ALIAS = "claude-sonnet-4-6"

THRESHOLD_CATEGORY_DISAGREEMENT_MAX_COUNT = 6
THRESHOLD_SPECIFICS_KEY_DRIFT_MAX_AVG_PCT = 30.0
THRESHOLD_PANEL_ROUTE_DELTA_MAX_PP = 10.0


# ──────────────────────────────────────────────────────────────────────────
# Sampling
# ──────────────────────────────────────────────────────────────────────────


def load_scored_records(auto_scores_path: Path) -> list[dict]:
    """Return the `scored` list from auto-scores.json (round-2 corpus)."""
    with auto_scores_path.open() as f:
        d = json.load(f)
    return list(d["scored"])


def _stratum_sort_key(rec: dict) -> tuple:
    """Stable key used to sort each stratum before drawing the sample.

    `random.sample` walks the input in order, so a deterministic sort is the
    contract that lets two runs with the same seed pick the same recs.
    """
    return (
        rec.get("plant_id", ""),
        rec.get("cluster_id", ""),
        rec.get("trial", 0),
    )


def stratified_sample(
    records: list[dict],
    *,
    seed: int = SAMPLING_SEED,
    per_stratum: int = PER_STRATUM,
    categories: tuple[str, ...] = PLANT_CATEGORIES,
    conditions: tuple[str, ...] = CONDITIONS,
) -> list[dict]:
    """Sample `per_stratum` recs from each (category, condition) cell.

    Returns 30 recs for the 5×2 default. Raises ValueError if any stratum
    holds fewer than `per_stratum` candidates — the caller should not see
    a silently truncated sample.
    """
    rng = random.Random(seed)
    chosen: list[dict] = []
    for category in categories:
        for condition in conditions:
            candidates = sorted(
                (
                    r for r in records
                    if r.get("plant_category") == category
                    and r.get("condition") == condition
                ),
                key=_stratum_sort_key,
            )
            if len(candidates) < per_stratum:
                raise ValueError(
                    f"stratum ({category}, {condition}) has only "
                    f"{len(candidates)} candidates; need {per_stratum}"
                )
            chosen.extend(rng.sample(candidates, per_stratum))
    return chosen


# ──────────────────────────────────────────────────────────────────────────
# Telemetry / response lookup
# ──────────────────────────────────────────────────────────────────────────


def build_telemetry_index(trial_logs_dir: Path) -> dict[tuple[str, str, int], Path]:
    """Index telemetry files by (cluster_id, condition, trial)."""
    index: dict[tuple[str, str, int], Path] = {}
    for cond_dir in trial_logs_dir.iterdir():
        if not cond_dir.is_dir() or cond_dir.name in ("raw", "parsed"):
            continue
        condition = cond_dir.name
        for trial_dir in cond_dir.iterdir():
            if not trial_dir.is_dir() or not trial_dir.name.startswith("trial"):
                continue
            trial = int(trial_dir.name[len("trial"):])
            for tel_path in trial_dir.glob("*.json"):
                tel = json.loads(tel_path.read_text())
                key = (tel["cluster_id"], condition, trial)
                index[key] = tel_path
    return index


def load_round2_response(telemetry: dict, trial_logs_dir: Path) -> dict | None:
    """Parse the stored round-2 response for a rec.

    Returns a dict like `{category, specifics, rationale, evidence_quote,
    confidence}` on success, or None if the response failed to parse at
    round-2 time.
    """
    # parse_responses uses a hyphenated import-name; load via the
    # `parse_responses` module (lives next to auto-scorer.py).
    from parse_responses import extract_recommendation  # type: ignore[import-not-found]

    raw_rel = telemetry["raw_response_path"]
    raw_path = trial_logs_dir / raw_rel
    raw_doc = json.loads(raw_path.read_text())
    blocks = raw_doc.get("content") or []
    if not blocks or not isinstance(blocks, list):
        return None
    text = blocks[0].get("text") if isinstance(blocks[0], dict) else None
    if not isinstance(text, str):
        return None
    rec, err = extract_recommendation(text)
    if err is not None:
        return None
    return rec


def load_cluster_row(
    cluster_id: str, query: str, condition: str, clusters_root: Path
) -> dict:
    """Find the cluster row with `cluster_id` in clusters-<cond>/<query>.jsonl.

    cluster_id is the primary key the scorer uses; looking up by it is robust
    against benign row_index shifts (e.g., when an extractor change inserts
    or removes a row earlier in the file). For drift-check purposes a missing
    cluster_id is an error — we can't re-render the prompt without the input.
    """
    cluster_path = clusters_root / f"clusters-{condition}" / f"{query}.jsonl"
    with cluster_path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if row.get("cluster_id") == cluster_id:
                return row
    raise KeyError(
        f"cluster_id {cluster_id!r} not found in {cluster_path}"
    )


# ──────────────────────────────────────────────────────────────────────────
# Drift metrics
# ──────────────────────────────────────────────────────────────────────────


def category_disagreement(round2: list[dict], drift: list[dict]) -> dict:
    """Count of recs where round-2 category != drift category."""
    if len(round2) != len(drift):
        raise ValueError(f"length mismatch: {len(round2)} vs {len(drift)}")
    disagree = sum(
        1
        for r, d in zip(round2, drift)
        if (r or {}).get("category") != (d or {}).get("category")
    )
    pct = (disagree / len(round2)) * 100.0 if round2 else 0.0
    return {
        "count": disagree,
        "of_total": len(round2),
        "pct": pct,
        "threshold_max_count": THRESHOLD_CATEGORY_DISAGREEMENT_MAX_COUNT,
        "pass": disagree <= THRESHOLD_CATEGORY_DISAGREEMENT_MAX_COUNT,
    }


def _key_drift_pct(round2_specifics: dict | None, drift_specifics: dict | None) -> float:
    """Per-rec specifics-key drift: |sym diff| / |union| × 100.

    Treats a None/missing specifics as an empty set; if both are empty the
    drift is 0 (perfectly matched: no keys gained or lost).
    """
    keys_r = set((round2_specifics or {}).keys())
    keys_d = set((drift_specifics or {}).keys())
    union = keys_r | keys_d
    if not union:
        return 0.0
    sym_diff = keys_r.symmetric_difference(keys_d)
    return (len(sym_diff) / len(union)) * 100.0


def specifics_key_drift(round2: list[dict], drift: list[dict]) -> dict:
    """Average per-rec Jaccard symmetric-difference fraction over keys."""
    if len(round2) != len(drift):
        raise ValueError(f"length mismatch: {len(round2)} vs {len(drift)}")
    per_rec = [
        _key_drift_pct(
            (r or {}).get("specifics"),
            (d or {}).get("specifics"),
        )
        for r, d in zip(round2, drift)
    ]
    avg = sum(per_rec) / len(per_rec) if per_rec else 0.0
    return {
        "avg_pct": avg,
        "per_rec_pct": per_rec,
        "threshold_max_avg_pct": THRESHOLD_SPECIFICS_KEY_DRIFT_MAX_AVG_PCT,
        "pass": avg <= THRESHOLD_SPECIFICS_KEY_DRIFT_MAX_AVG_PCT,
    }


def panel_route_delta(round2_scores: list, drift_scores: list) -> dict:
    """Absolute pp delta between drift and round-2 panel-route rates.

    Pass semantics: count-space delta is exact (drift_panel - r2_panel) and
    converts to pp via × 100/n. The pass check rounds to 1e-9 before
    comparing so threshold-on-the-nose pp values (e.g., 3/30 → 10.0pp) are
    not flipped by IEEE-754 rounding in the subtraction.
    """
    if len(round2_scores) != len(drift_scores):
        raise ValueError(f"length mismatch: {len(round2_scores)} vs {len(drift_scores)}")
    n = len(round2_scores)
    r2_panel = sum(1 for s in round2_scores if s == "panel_route")
    drift_panel = sum(1 for s in drift_scores if s == "panel_route")
    r2_pct = (r2_panel / n) * 100.0 if n else 0.0
    drift_pct = (drift_panel / n) * 100.0 if n else 0.0
    delta_pp = drift_pct - r2_pct
    pass_check = round(abs(delta_pp), 9) <= THRESHOLD_PANEL_ROUTE_DELTA_MAX_PP
    return {
        "round2_panel_count": r2_panel,
        "drift_panel_count": drift_panel,
        "round2_panel_pct": r2_pct,
        "drift_panel_pct": drift_pct,
        "delta_pp": delta_pp,
        "threshold_max_abs_pp": THRESHOLD_PANEL_ROUTE_DELTA_MAX_PP,
        "pass": pass_check,
    }


def decide_disposition(
    category: dict, specifics: dict, panel: dict
) -> dict:
    """Aggregate the three pass flags into a single proceed/halt verdict."""
    all_pass = bool(category["pass"] and specifics["pass"] and panel["pass"])
    reasons: list[str] = []
    if not category["pass"]:
        reasons.append("category_disagreement_exceeded")
    if not specifics["pass"]:
        reasons.append("specifics_key_drift_exceeded")
    if not panel["pass"]:
        reasons.append("panel_route_delta_exceeded")
    return {
        "all_pass": all_pass,
        "decision": "proceed" if all_pass else "halt",
        "halt_reasons": reasons,
    }


# ──────────────────────────────────────────────────────────────────────────
# Auto-scorer wrapping (round-2 + drift scoring)
# ──────────────────────────────────────────────────────────────────────────


def _load_auto_scorer():
    """Import the in-tree auto-scorer.py via importlib (hyphenated name)."""
    scorer_path = EXP_DIR / "auto-scorer.py"
    spec = importlib.util.spec_from_file_location("auto_scorer", scorer_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load auto-scorer from {scorer_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["auto_scorer"] = module
    spec.loader.exec_module(module)
    return module


def _load_manifest_and_rubric():
    """Read plant-manifest.yaml + rubric.yaml, return ({plant_id: plant}, rubric)."""
    import yaml  # type: ignore[import-not-found]
    manifest = yaml.safe_load((EXP_DIR / "plant-manifest.yaml").read_text())
    rubric = yaml.safe_load((EXP_DIR / "rubric.yaml").read_text())
    plants_by_id = {p["plant_id"]: p for p in manifest["plants"]}
    return plants_by_id, rubric


_SCORER_STATE: dict = {}


def score_with_auto_scorer(rec: dict | None, plant_id: str) -> Any:
    """Run auto-scorer.score_recommendation; return score (numeric or panel_route).

    Caches the scorer module and manifest+rubric across calls so a 30-rec
    drift loop doesn't reparse YAML and reimport the scorer thirty times.
    """
    if rec is None:
        return "panel_route"  # round-2 parse-error → panel-route under §8
    if "plants_by_id" not in _SCORER_STATE:
        _SCORER_STATE["plants_by_id"], _SCORER_STATE["rubric"] = _load_manifest_and_rubric()
        _SCORER_STATE["scorer"] = _load_auto_scorer()
    plant = _SCORER_STATE["plants_by_id"].get(plant_id)
    if plant is None:
        return "panel_route"
    result = _SCORER_STATE["scorer"].score_recommendation(rec, plant, _SCORER_STATE["rubric"])
    return result.score


# ──────────────────────────────────────────────────────────────────────────
# Orchestration
# ──────────────────────────────────────────────────────────────────────────


def render_user_message(cluster_row: dict, prompt_doc_text: str) -> str:
    """Re-render the v1 prompt body for one cluster row."""
    from harness.prompt import extract_prompt_body, normalize_row, render
    instructions, specifics = extract_prompt_body(prompt_doc_text)
    normalized = normalize_row(cluster_row)
    return render(instructions, specifics, normalized)


def run_drift_check(
    *,
    auto_scores_path: Path,
    trial_logs_dir: Path,
    clusters_root: Path,
    prompt_v1_doc: Path,
    api_key: str,
    dry_run: bool = False,
    sample_only: bool = False,
) -> dict:
    """Top-level orchestration: sample → fetch → compare → write."""
    from harness import api as harness_api
    from parse_responses import extract_recommendation  # type: ignore[import-not-found]

    scored = load_scored_records(auto_scores_path)
    sample = stratified_sample(scored)

    print(f"Sampled {len(sample)} recs across "
          f"{len(PLANT_CATEGORIES)}×{len(CONDITIONS)} strata "
          f"(seed={SAMPLING_SEED})", file=sys.stderr)
    if dry_run or sample_only:
        for r in sample:
            print(f"  {r['plant_category']:24s} {r['condition']} "
                  f"trial={r['trial']} {r['cluster_id'][:60]}",
                  file=sys.stderr)
        if dry_run and not sample_only:
            return {"dry_run": True, "sample_size": len(sample)}

    tel_index = build_telemetry_index(trial_logs_dir)
    prompt_doc_text = prompt_v1_doc.read_text()

    per_rec: list[dict] = []
    round2_recs: list[dict] = []
    drift_recs: list[dict] = []
    round2_scores: list = []
    drift_scores: list = []
    response_models: Counter = Counter()
    total_cost = 0.0

    for i, scored_rec in enumerate(sample, 1):
        key = (scored_rec["cluster_id"], scored_rec["condition"], scored_rec["trial"])
        tel_path = tel_index.get(key)
        if tel_path is None:
            raise RuntimeError(f"telemetry not found for {key}")
        tel = json.loads(tel_path.read_text())

        r2 = load_round2_response(tel, trial_logs_dir)
        cluster_row = load_cluster_row(
            tel["cluster_id"], tel["query"], tel["condition"], clusters_root
        )
        user_message = render_user_message(cluster_row, prompt_doc_text)

        if sample_only:
            d = None
            response_model = None
            cost = 0.0
        else:
            # Pass MODEL_ALIAS explicitly rather than relying on harness_api's
            # default — the drift-check's pre-registration pins the model, so
            # a future harness-side default change must not silently rotate it.
            payload = harness_api.build_payload(user_message, model=MODEL_ALIAS)
            resp = harness_api.call_messages(payload, api_key)
            if resp.status != 200:
                err_body = resp.body
                raise RuntimeError(
                    f"API call failed for {key}: status={resp.status} body={err_body}"
                )
            text = harness_api.extract_text(resp.body)
            d, derr = extract_recommendation(text)
            response_model = resp.body.get("model")
            usage = resp.body.get("usage") or {}
            # Sonnet 4.6: $3/M input, $15/M output (current pricing pin).
            in_tok = usage.get("input_tokens", 0)
            out_tok = usage.get("output_tokens", 0)
            cost = (in_tok / 1_000_000) * 3.0 + (out_tok / 1_000_000) * 15.0
            total_cost += cost
            if response_model:
                response_models[response_model] += 1
            print(f"  [{i}/{len(sample)}] {key[0][:60]} → cat={d.get('category') if d else 'PARSE_ERR'} "
                  f"model={response_model} cost=${cost:.4f}", file=sys.stderr)

        round2_recs.append(r2)
        drift_recs.append(d)
        round2_scores.append(scored_rec.get("score"))
        if d is not None:
            drift_scores.append(score_with_auto_scorer(d, scored_rec["plant_id"]))
        else:
            drift_scores.append("panel_route")

        per_rec.append({
            "cluster_id": scored_rec["cluster_id"],
            "condition": scored_rec["condition"],
            "trial": scored_rec["trial"],
            "query": tel["query"],
            "plant_id": scored_rec["plant_id"],
            "plant_category": scored_rec["plant_category"],
            "round2_category": (r2 or {}).get("category"),
            "drift_category": (d or {}).get("category"),
            "round2_specifics_keys": sorted((r2 or {}).get("specifics", {}).keys()),
            "drift_specifics_keys": sorted((d or {}).get("specifics", {}).keys()),
            "round2_score": scored_rec.get("score"),
            "drift_score": drift_scores[-1],
            "response_model": response_model if not sample_only else None,
        })

    cat_metric = category_disagreement(round2_recs, drift_recs)
    spec_metric = specifics_key_drift(round2_recs, drift_recs)
    panel_metric = panel_route_delta(round2_scores, drift_scores)
    disposition = decide_disposition(cat_metric, spec_metric, panel_metric)

    return {
        "schema_version": "1.0",
        "run_timestamp_utc": _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds"),
        "sampling_seed": SAMPLING_SEED,
        "sample_size": len(sample),
        "per_stratum": PER_STRATUM,
        "categories": list(PLANT_CATEGORIES),
        "conditions": list(CONDITIONS),
        "model_alias": MODEL_ALIAS,
        "captured_response_models": dict(response_models),
        "total_cost_usd": total_cost,
        "thresholds": {
            "category_disagreement_max_count": THRESHOLD_CATEGORY_DISAGREEMENT_MAX_COUNT,
            "specifics_key_drift_max_avg_pct": THRESHOLD_SPECIFICS_KEY_DRIFT_MAX_AVG_PCT,
            "panel_route_delta_max_pp": THRESHOLD_PANEL_ROUTE_DELTA_MAX_PP,
        },
        "metrics": {
            "category_disagreement": cat_metric,
            "specifics_key_drift": spec_metric,
            "panel_route": panel_metric,
        },
        "disposition": disposition,
        "substrate_notes": (
            "Cluster rows are looked up by cluster_id, not row_index, so a "
            "benign substrate row-shift (extractor inserts/removes a row that "
            "does not affect a sampled cluster's membership) does not "
            "invalidate the comparison. The drift-check at this run-date "
            "diverges from the round-2 substrate hash by 1 swift file in 485 "
            "(0.2%); all 30 sampled cluster_ids resolve cleanly under the "
            "regenerated catalogs. See pre_registration.plant_tree_sha in "
            "reproducibility.yaml for the round-2 substrate pin."
        ),
        "per_rec": per_rec,
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--auto-scores",
        type=Path,
        default=EXP_DIR / "analyses" / "auto-scores.json",
        help="Round-2 auto-scores file (default: analyses/auto-scores.json).",
    )
    ap.add_argument(
        "--trial-logs",
        type=Path,
        default=EXP_DIR / "trial-logs",
        help="Round-2 trial-logs directory.",
    )
    ap.add_argument(
        "--clusters-root",
        type=Path,
        default=EXP_DIR,
        help="Root containing clusters-s1/ and clusters-s2/.",
    )
    ap.add_argument(
        "--prompt-v1",
        type=Path,
        default=PROMPT_V1_DOC,
        help="V1 agent-prompt file.",
    )
    ap.add_argument(
        "--output",
        type=Path,
        default=ANALYSES_V2_DIR / "drift-check.json",
        help="Output JSON path.",
    )
    ap.add_argument(
        "--dry-run", action="store_true",
        help="Print the 30-rec sample and exit; no API calls.",
    )
    ap.add_argument(
        "--sample-only", action="store_true",
        help="Reconstruct prompts but skip API calls; still writes a partial JSON.",
    )
    args = ap.parse_args(argv)

    api_key = os.environ.get("ANTHROPIC_API_KEY", "")
    if not args.dry_run and not args.sample_only and not api_key:
        print("ERROR: ANTHROPIC_API_KEY not set", file=sys.stderr)
        return 2

    result = run_drift_check(
        auto_scores_path=args.auto_scores,
        trial_logs_dir=args.trial_logs,
        clusters_root=args.clusters_root,
        prompt_v1_doc=args.prompt_v1,
        api_key=api_key,
        dry_run=args.dry_run,
        sample_only=args.sample_only,
    )

    if args.dry_run and not args.sample_only:
        return 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"\nwrote {args.output}", file=sys.stderr)
    print(f"decision: {result['disposition']['decision']}", file=sys.stderr)
    if result["disposition"]["halt_reasons"]:
        print(f"  halt reasons: {result['disposition']['halt_reasons']}", file=sys.stderr)
    return 0 if result["disposition"]["all_pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
