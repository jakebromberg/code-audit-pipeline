#!/usr/bin/env python3
"""Phase E PR-E3 — bulk auto-scorer runner over the parsed cache.

Walks every parsed recommendation under `trial-logs/parsed/<cond>/trial<n>/`,
binds each rec to zero-or-more plants via cluster_id substring match against
plant.source_files, calls `auto-scorer.py::score_recommendation` for every
(rec, plant) pair, and emits four artifacts:

  • `analyses/auto-scores.json`  — every (rec, plant) pair the scorer ran on,
    plus per-rec buckets for unmatched (no plant) and parse_error rows.
  • `analyses/score-summary.json` — aggregates per (condition, category,
    trial) cell: canonical recall, restraint FPR, panel-route rate, plus the
    headline 2-D point (canonical recall × 1−FPR) per condition. Fleiss κ is
    populated from `analyses/panel-scores.jsonl` if present and ≥2 reviewers
    are present; if the file is missing or holds <2 reviewers, `inter_rater`
    is a structured panel-pending sentinel `{fleiss_kappa: null, n_items,
    n_raters, note}` so downstream consumers can render "panel pending"
    cleanly.
  • `analyses/panel-routing.jsonl` — opaque-tokenized one-per-line records
    for the panel sitting (per methodology §17 decision #3, 3 internal
    reviewers blind to condition).
  • `analyses/panel-unblind.json` — token → {cluster_id, condition, trial}
    mapping; commits alongside results.md after the panel sitting (Phase E
    plan §6 decision #3).

Run from the repo root:

  python3 experiments/v7-refactor-recommendation/score_all.py
  python3 experiments/v7-refactor-recommendation/score_all.py \\
      --parsed experiments/v7-refactor-recommendation/trial-logs/parsed \\
      --manifest experiments/v7-refactor-recommendation/plant-manifest.yaml \\
      --rubric experiments/v7-refactor-recommendation/rubric.yaml \\
      --auto-scores-out experiments/v7-refactor-recommendation/analyses/auto-scores.json \\
      --summary-out     experiments/v7-refactor-recommendation/analyses/score-summary.json \\
      --panel-routing-out experiments/v7-refactor-recommendation/analyses/panel-routing.jsonl

Determinism:
  - bind_recs_to_plants sorts matched plant_ids.
  - score_recommendations sorts every list it emits by a stable key.
  - JSON serialization uses sort_keys=True; trailing newline pinned.
  - The panel-routing opaque rec_token is a SHA-256 prefix over the rec's
    stable identity (cluster_id + condition + trial + plant_id), so re-runs
    against the same corpus reproduce identical tokens.

Methodology cross-refs:
  - §8 — scoring rubric and the panel-route decision rule that auto-scorer.py
    implements per-rec; this module is the bulk-walking shell.
  - §9 — restraint-plant table; canonical recall and restraint FPR are
    aggregated separately and combined in the headline 2-D point.
  - §12 — Fleiss κ over panel-scores.jsonl when present.
  - §14.3 — panel-route rate ≤ 50% acceptance bar (Phase E plan §3.2).
  - §17 decision #3 — 3 internal reviewers, blind to condition.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import sys
from collections import defaultdict
from pathlib import Path
from typing import Iterable

try:
    import yaml
except ImportError:
    sys.stderr.write("ERROR: PyYAML not installed. Run: pip install pyyaml\n")
    sys.exit(2)


SCHEMA_VERSION = "1.0"
HERE = Path(__file__).resolve().parent

# Default acceptance bar from methodology §14.3 / Phase E plan §3.2.
DEFAULT_PANEL_ROUTE_RATE_THRESHOLD = 0.50


# ─── auto-scorer import (hyphenated filename) ─────────────────────────────


def _load_auto_scorer(scorer_path: Path):
    """Load auto-scorer.py as a module despite the hyphen in its filename.

    The module is registered in `sys.modules` so its @dataclass-decorated
    classes can resolve `cls.__module__` during class construction.
    """
    spec = importlib.util.spec_from_file_location("auto_scorer", scorer_path)
    if spec is None or spec.loader is None:
        raise FileNotFoundError(
            f"could not load auto-scorer from {scorer_path}; "
            "check the path exists and is importable"
        )
    module = importlib.util.module_from_spec(spec)
    sys.modules["auto_scorer"] = module
    spec.loader.exec_module(module)
    return module


# Module-level singleton bound to the in-tree auto-scorer.py for the common
# case. Tests that need a different scorer path pass `scorer=` to
# score_recommendations() explicitly.
_DEFAULT_SCORER_PATH = HERE / "auto-scorer.py"
_default_scorer = None


def _get_default_scorer():
    global _default_scorer
    if _default_scorer is None:
        _default_scorer = _load_auto_scorer(_DEFAULT_SCORER_PATH)
    return _default_scorer


PANEL_ROUTE = "panel_route"  # mirrors auto_scorer.PANEL_ROUTE for downstream comparisons


# ─── plant ↔ rec binding ──────────────────────────────────────────────────


def bind_recs_to_plants(parsed_records: list[dict], plants: list[dict]) -> list[tuple[dict, list[str]]]:
    """For each rec, return the (sorted) list of plant_ids that the rec binds
    to. Resolution rule (round-1 closeout):

    1. Compute `substring_matches` — plants whose `source_files` substring-
       match the rec's `cluster_id` (the V7 round-1 strategy).
    2. Compute `signal_matches` — subset of `substring_matches` where the
       rec's `query` is in the plant's `expected_substrate_signals` list.
    3. If `signal_matches` is non-empty, bind to those plants only — they
       "claim" the cluster because the cluster came from a query the plant
       pre-registered as expected. The other substring matches drop out.
    4. Otherwise, fall back to all `substring_matches` — the cluster's query
       isn't pre-registered for any candidate, so substring is the only
       available signal.

    The motivating round-1 case: an HSBColor `pat-candidates` cluster
    substring-matched both Plant 3.1 (signals: function-duplicates,
    default-impl-candidates) and Plant 5.1 (signals: pat-candidates,
    cross-package-shape-near-duplicates-any). Old logic bound to both. New
    logic recognizes that Plant 5.1 claims the cluster via signal-match and
    binds to 5.1 only — Plant 3.1's spurious co-binding disappears.

    The fallback in step 4 preserves Plant 1R bindings (Plant 1R's signals
    are exact-duplicates and cross-package-shape-near-duplicates-any, but
    its source_files mostly substring-match clusters from path-bearing
    queries like function-duplicates-exact). Without the fallback those
    bindings would silently vanish and Plant 1R's restraint specificity
    signal would be suppressed by binding logic rather than measured.

    Recs with a missing/None/empty `query` field collapse `signal_matches`
    to empty unconditionally, so they fall through to substring-only —
    preserving byte-stable behavior for any pre-`query`-field parsed cache.

    parse_error rows are returned with their plant matches preserved, but
    callers should route them to the parse_errors bucket downstream rather
    than scoring them.
    """
    bindings: list[tuple[dict, list[str]]] = []
    for rec in parsed_records:
        cluster_id = rec.get("cluster_id") or ""
        rec_query = rec.get("query") or ""
        substring_matches: list[str] = []
        signal_matches: list[str] = []
        for plant in plants:
            paths = plant.get("source_files") or []
            substring_hit = any(p and p in cluster_id for p in paths)
            if not substring_hit:
                continue
            substring_matches.append(plant["plant_id"])
            signals = plant.get("expected_substrate_signals") or []
            if rec_query and rec_query in signals:
                signal_matches.append(plant["plant_id"])
        matched = signal_matches if signal_matches else substring_matches
        bindings.append((rec, sorted(matched)))
    return bindings


# ─── core scoring loop ────────────────────────────────────────────────────


def _opaque_token(*parts: str) -> str:
    """Stable opaque identifier derived from the rec's identity fields. Used
    for the panel-routing artifact so reviewers see no condition/trial cues.
    """
    h = hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()
    return f"pr-{h[:12]}"


def _token_parts(cluster_id, condition, trial, plant_id) -> tuple[str, str, str, str]:
    """Normalize the four identity fields into the exact strings that
    `_opaque_token` hashes. Both the panel-routing writer in
    `score_recommendations` and the matching read in `promote_panel_scores`
    MUST use this helper so the tokens round-trip — any asymmetry in how
    None/missing fields are stringified silently breaks promotion.

    Missing fields (None, missing keys) normalize to the empty string,
    matching what JSON `null` looks like once serialized and re-loaded. A
    plant_id that comes back from YAML as a float (e.g. `5.1`) is stringified
    with Python's default repr so the token round-trips through scored
    entries' `plant_id` field.
    """
    def _norm(v):
        return "" if v is None else str(v)
    return (_norm(cluster_id), _norm(condition), _norm(trial), _norm(plant_id))


def _build_recommendation_dict(parsed: dict) -> dict:
    """Reshape a parsed.parsed dict into the auto-scorer's expected input."""
    return {
        "category": parsed.get("category"),
        "specifics": parsed.get("specifics") or {},
        "rationale": parsed.get("rationale") or "",
        "evidence_quote": parsed.get("evidence_quote"),
        "confidence": parsed.get("confidence"),
    }


def score_recommendations(
    parsed_records: list[dict],
    plants: list[dict],
    rubric: dict,
    *,
    scorer=None,
) -> dict:
    """Score every (rec, plant) pair derivable from the parsed cache.

    Returns:
        {
          "schema_version": "1.0",
          "scored": [...],          # one row per (rec, plant) pair
          "unmatched": [...],       # parsed recs that bound to zero plants
          "parse_errors": [...],    # rows the parser flagged
          "panel_routed": [...],    # subset of `scored` with score == PANEL_ROUTE
        }

    All lists are sorted by a stable key for byte-identical re-run output.
    """
    scorer = scorer or _get_default_scorer()
    plants_by_id = {p["plant_id"]: p for p in plants}

    scored: list[dict] = []
    unmatched: list[dict] = []
    parse_errors: list[dict] = []
    panel_routed: list[dict] = []

    bindings = bind_recs_to_plants(parsed_records, plants)
    for rec, plant_ids in bindings:
        if rec.get("parse_error"):
            parse_errors.append({
                "cluster_id": rec.get("cluster_id"),
                "condition": rec.get("condition"),
                "trial": rec.get("trial"),
                "query": rec.get("query"),
                "parse_error": rec["parse_error"],
                "matched_plant_ids": plant_ids,
            })
            continue
        if not plant_ids:
            unmatched.append({
                "cluster_id": rec.get("cluster_id"),
                "condition": rec.get("condition"),
                "trial": rec.get("trial"),
                "query": rec.get("query"),
                "rec_category": (rec.get("parsed") or {}).get("category"),
            })
            continue
        rec_dict = _build_recommendation_dict(rec.get("parsed") or {})
        for plant_id in plant_ids:
            plant = plants_by_id[plant_id]
            result = scorer.score_recommendation(rec_dict, plant, rubric)
            entry = {
                "cluster_id": rec.get("cluster_id"),
                "condition": rec.get("condition"),
                "trial": rec.get("trial"),
                "query": rec.get("query"),
                "plant_id": plant_id,
                "plant_category": plant.get("category"),
                "plant_restraint": bool(plant.get("restraint")),
                "rec_category": rec_dict["category"],
                "rec_confidence": rec_dict.get("confidence"),
                "score": result.score,
                "match": result.match,
                "notes": list(result.notes),
            }
            scored.append(entry)
            if result.score == PANEL_ROUTE:
                token = _opaque_token(*_token_parts(
                    rec.get("cluster_id"),
                    rec.get("condition"),
                    rec.get("trial"),
                    plant_id,
                ))
                panel_routed.append({
                    "rec_token": token,
                    "plant_id": plant_id,
                    "plant_category": plant.get("category"),
                    "plant_restraint": bool(plant.get("restraint")),
                    "query": rec.get("query"),
                    "rec_category": rec_dict["category"],
                    "rec_specifics": rec_dict.get("specifics"),
                    "rec_rationale": rec_dict.get("rationale"),
                    "rec_evidence_quote": rec_dict.get("evidence_quote"),
                    "rec_confidence": rec_dict.get("confidence"),
                    "match_reason": result.match,
                    # condition + trial deliberately omitted from this view;
                    # unblind map records them separately.
                    "unblind": {
                        "cluster_id": rec.get("cluster_id"),
                        "condition": rec.get("condition"),
                        "trial": rec.get("trial"),
                    },
                })

    # Sort all lists for byte-stable output.
    scored.sort(key=lambda r: (r["condition"], r["trial"], r["plant_id"], r["cluster_id"]))
    unmatched.sort(key=lambda r: (r["condition"], r["trial"], r["cluster_id"]))
    parse_errors.sort(key=lambda r: (r["condition"], r["trial"], r["cluster_id"]))
    panel_routed.sort(key=lambda r: r["rec_token"])

    return {
        "schema_version": SCHEMA_VERSION,
        "scored": scored,
        "unmatched": unmatched,
        "parse_errors": parse_errors,
        "panel_routed": panel_routed,
    }


# ─── panel-score promotion ────────────────────────────────────────────────


def promote_panel_scores(scored_doc: dict, panel_scores_path: Path) -> dict:
    """Replace `PANEL_ROUTE` sentinels in `scored_doc["scored"]` with the
    panel-supplied numeric score from `panel_scores_path`. For multi-reviewer
    panels, uses the median across reviewers per rec_token.

    Match key: each scored entry's rec_token is recomputed from
    (cluster_id, condition, trial, plant_id) using `_opaque_token`, matching
    the scheme `score_recommendations` uses when it populates
    `scored_doc["panel_routed"]`. A token with no panel-supplied score is
    left at `PANEL_ROUTE` (deferred to a later round).

    The function mutates `scored_doc` in place and returns it for chaining.
    Numeric (non-`PANEL_ROUTE`) entries are never touched.

    Why this exists: the auto-scorer routes the rec_category=="other" and
    specifics-out-of-tolerance cases to panel and stamps `score=PANEL_ROUTE`.
    `_best_score` (used by `aggregate_summary`) ignores `PANEL_ROUTE` because
    it isn't numeric, so per-cell `best_score` and the headline
    canonical_recall reflect auto-scored pairs only. Once the panel sitting
    produces scores, this step backfills them into `scored_doc["scored"]` so
    the re-run pickup is a single change: panel-routed cells get their final
    panel-resolved value before aggregation, instead of staying as deferred
    nulls forever.
    """
    if not panel_scores_path.exists():
        return scored_doc
    by_token: dict[str, list[float]] = defaultdict(list)
    with panel_scores_path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            token = row["rec_token"]
            score = row["score"]
            if isinstance(score, (int, float)) and not isinstance(score, bool):
                by_token[token].append(float(score))
    if not by_token:
        return scored_doc
    for entry in scored_doc["scored"]:
        if entry.get("score") != PANEL_ROUTE:
            continue
        token = _opaque_token(*_token_parts(
            entry.get("cluster_id"),
            entry.get("condition"),
            entry.get("trial"),
            entry.get("plant_id"),
        ))
        scores = by_token.get(token, [])
        if not scores:
            continue
        scores_sorted = sorted(scores)
        n = len(scores_sorted)
        if n % 2:
            median = scores_sorted[n // 2]
        else:
            median = (scores_sorted[n // 2 - 1] + scores_sorted[n // 2]) / 2.0
        original_match = entry.get("match")
        entry["score"] = median
        entry["match"] = "panel_promoted"
        notes = entry.get("notes") or []
        notes.append(f"panel_promoted_from_{original_match}_n_reviewers_{n}")
        entry["notes"] = notes
    return scored_doc


# ─── aggregation ──────────────────────────────────────────────────────────


def _best_score(pairs: list[dict]) -> tuple[float | None, dict]:
    """Pick the per-plant cell representative: highest numeric score wins.
    Returns (best_score_or_None, info_dict).
    """
    numeric = [p["score"] for p in pairs if isinstance(p["score"], (int, float))]
    panel_count = sum(1 for p in pairs if p["score"] == PANEL_ROUTE)
    best = max(numeric) if numeric else None
    return best, {
        "best_score": best,
        "n_pairs": len(pairs),
        "n_numeric": len(numeric),
        "n_panel_route": panel_count,
    }


def aggregate_summary(scored_doc: dict, plants: list[dict]) -> dict:
    """Compute per-cell aggregates + the headline 2-D point per condition.

    Cell granularity: (condition, trial, plant_id) for per-plant rows;
                      (condition, trial, plant_category) for per-category rows.

    The "missing rec" handling: if a plant has zero matched recs in a given
    (condition, trial) cell, its per-plant score defaults to 0.0 for the
    canonical-recall mean (a missed plant is a recall miss, not an excluded
    one). Restraint FPR denominator is fixed at the number of restraint
    plants in the category; numerator counts plants with ≥1 action rec.
    """
    plants_by_id = {p["plant_id"]: p for p in plants}
    categories = sorted({p["category"] for p in plants})
    conditions = sorted({r["condition"] for r in scored_doc["scored"]} | {"s1", "s2"})
    trials = sorted({r["trial"] for r in scored_doc["scored"]} | {1, 2, 3})

    # Group scored pairs by (condition, trial, plant_id)
    cell_pairs: dict[tuple[str, int, str], list[dict]] = defaultdict(list)
    for pair in scored_doc["scored"]:
        cell_pairs[(pair["condition"], pair["trial"], pair["plant_id"])].append(pair)

    # Per-plant per-cell summary
    per_plant_per_cell: dict[str, dict[str, dict[str, dict]]] = {}
    for cond in conditions:
        per_plant_per_cell[cond] = {}
        for t in trials:
            per_plant_per_cell[cond][str(t)] = {}
            for p in plants:
                pairs = cell_pairs.get((cond, t, p["plant_id"]), [])
                if pairs:
                    _, info = _best_score(pairs)
                else:
                    info = {"best_score": None, "n_pairs": 0, "n_numeric": 0, "n_panel_route": 0}
                per_plant_per_cell[cond][str(t)][p["plant_id"]] = info

    # Per-category per-cell summary (condition × trial × category)
    per_category_per_cell: dict[str, dict[str, dict[str, dict]]] = {}
    for cond in conditions:
        per_category_per_cell[cond] = {}
        for t in trials:
            per_category_per_cell[cond][str(t)] = {}
            for category in categories:
                canon_plants = [p for p in plants if p["category"] == category and not p.get("restraint")]
                rest_plants = [p for p in plants if p["category"] == category and p.get("restraint")]
                canon_scores = []
                for p in canon_plants:
                    pairs = cell_pairs.get((cond, t, p["plant_id"]), [])
                    best, _ = _best_score(pairs)
                    # Panel-route-only plants get `best is None` (no numeric
                    # score available). Counted as 0.0 against canonical
                    # recall: the auto-scored headline can't credit a
                    # deferred panel decision. A plant whose every (cond,
                    # trial) cell is panel-routed thus silently lands at 0.0
                    # until `promote_panel_scores` (run upstream of
                    # `aggregate_summary` in `main`) substitutes the panel-
                    # supplied numeric for the PANEL_ROUTE sentinel.
                    canon_scores.append(best if best is not None else 0.0)
                n_fp = 0
                for p in rest_plants:
                    pairs = cell_pairs.get((cond, t, p["plant_id"]), [])
                    if any(pair["rec_category"] not in (None, "no-action") for pair in pairs):
                        n_fp += 1
                canonical_recall = sum(canon_scores) / len(canon_scores) if canon_scores else None
                restraint_fpr = n_fp / len(rest_plants) if rest_plants else None
                per_category_per_cell[cond][str(t)][category] = {
                    "n_canonical_plants": len(canon_plants),
                    "n_restraint_plants": len(rest_plants),
                    "n_restraint_fp": n_fp,
                    "canonical_recall": canonical_recall,
                    "restraint_fpr": restraint_fpr,
                }

    # Headline 2-D point per condition. Per methodology §8 + V5/V6 results
    # convention: per-plant score is max across trials (best-effort recall —
    # "did the agent ever get this plant right?"); canonical_recall is the
    # mean per-plant score across canonical plants; FPR counts restraint
    # plants with at least one action rec across any trial.
    headline: dict[str, dict] = {}
    for cond in conditions:
        canon_best: list[float] = []
        rest_action: int = 0
        rest_total: int = 0
        for p in plants:
            best_across_trials: float | None = None
            any_action: bool = False
            for t in trials:
                pairs = cell_pairs.get((cond, t, p["plant_id"]), [])
                best, _ = _best_score(pairs)
                if best is not None:
                    best_across_trials = best if best_across_trials is None else max(best_across_trials, best)
                if any(pair["rec_category"] not in (None, "no-action") for pair in pairs):
                    any_action = True
            if p.get("restraint"):
                rest_total += 1
                if any_action:
                    rest_action += 1
            else:
                canon_best.append(best_across_trials if best_across_trials is not None else 0.0)
        canonical_recall = sum(canon_best) / len(canon_best) if canon_best else None
        fpr = rest_action / rest_total if rest_total else None
        headline[cond] = {
            "canonical_recall": canonical_recall,
            "fpr": fpr,
            "one_minus_fpr": (1 - fpr) if fpr is not None else None,
            "n_canonical_plants": len(canon_best),
            "n_restraint_plants": rest_total,
        }

    # Panel-route rate per condition (denominator = planted recs, i.e. scored entries).
    # The numerator counts ORIGINALLY panel-routed pairs from
    # `scored_doc["panel_routed"]` — that list is populated by
    # `score_recommendations` and is preserved across `promote_panel_scores`,
    # so the §14.3 acceptance check measures the auto-scorer's true punt rate
    # regardless of whether panel sitting has happened yet.
    panel_route_rate: dict[str, dict] = {}
    panel_by_cond: dict[str, int] = defaultdict(int)
    for r in scored_doc["panel_routed"]:
        cond = r.get("unblind", {}).get("condition")
        if cond:
            panel_by_cond[cond] += 1
    for cond in conditions:
        denom = sum(1 for r in scored_doc["scored"] if r["condition"] == cond)
        n_panel = panel_by_cond.get(cond, 0)
        panel_route_rate[cond] = {
            "n_panel": n_panel,
            "n_planted": denom,
            "fraction": (n_panel / denom) if denom else None,
            "passes_threshold": (n_panel / denom <= DEFAULT_PANEL_ROUTE_RATE_THRESHOLD) if denom else None,
        }

    # Counts: parsed totals, planted totals, unmatched totals, parse errors
    counts = {
        "n_scored_pairs": len(scored_doc["scored"]),
        "n_unmatched_recs": len(scored_doc["unmatched"]),
        "n_parse_errors": len(scored_doc["parse_errors"]),
        "n_panel_routed_pairs": len(scored_doc["panel_routed"]),
        "n_plants": len(plants),
        "n_canonical_plants": sum(1 for p in plants if not p.get("restraint")),
        "n_restraint_plants": sum(1 for p in plants if p.get("restraint")),
    }

    return {
        "schema_version": SCHEMA_VERSION,
        "config": {
            "panel_route_rate_threshold": DEFAULT_PANEL_ROUTE_RATE_THRESHOLD,
            "missing_rec_default_score": 0.0,
            "per_plant_best_score_strategy": "max-over-recs-then-panel-fallback-null",
        },
        "counts": counts,
        "headline": headline,
        "panel_route_rate": panel_route_rate,
        "per_category_per_cell": per_category_per_cell,
        "per_plant_per_cell": per_plant_per_cell,
        "inter_rater": None,  # populated by attach_panel_kappa() once panel-scores.jsonl exists
    }


# ─── Fleiss κ ─────────────────────────────────────────────────────────────


def fleiss_kappa(ratings_per_item: list[dict[str, int]], *, m: int) -> float:
    """Fleiss κ over `len(ratings_per_item)` items each rated by `m` raters
    into a fixed set of categories.

    `ratings_per_item[i]` is a dict mapping category → count of raters who
    assigned item i to that category. The counts in each item must sum to m.

    Returns κ in [-1, 1]. Returns 1.0 when P_e == 1.0 and all items have
    P_i == 1.0 (the perfect-agreement degenerate case where the (1 - P_e)
    denominator vanishes).
    """
    N = len(ratings_per_item)
    if N == 0:
        return 0.0
    if m < 2:
        # κ is undefined for fewer than two raters per item — the P_i
        # denominator m*(m-1) vanishes at m=1 and the metric has no meaning at
        # m=0. Callers should treat m<2 as a precondition violation and route
        # to a panel-pending sentinel; we raise here so the failure is loud
        # rather than silently emitting an undefined number.
        raise ValueError(
            f"fleiss_kappa requires at least 2 raters per item (got m={m}); "
            "use attach_panel_kappa's panel-pending sentinel instead"
        )
    categories: set[str] = set()
    for r in ratings_per_item:
        categories.update(r.keys())
    categories_sorted = sorted(categories)
    # p_j: proportion of all ratings assigned to category j
    total = N * m
    p = {}
    for j in categories_sorted:
        p[j] = sum(r.get(j, 0) for r in ratings_per_item) / total
    # P_i: extent of agreement among raters for item i
    P_i = []
    for r in ratings_per_item:
        sq = sum((r.get(j, 0) ** 2) for j in categories_sorted)
        P_i.append((sq - m) / (m * (m - 1)))
    P_bar = sum(P_i) / N
    P_e = sum(v * v for v in p.values())
    if (1 - P_e) == 0:
        return 1.0 if P_bar == 1.0 else 0.0
    return (P_bar - P_e) / (1 - P_e)


def attach_panel_kappa(summary: dict, panel_scores_path: Path) -> dict:
    """Load `panel-scores.jsonl` (one row per (rec_token, reviewer, score))
    and populate `summary["inter_rater"]` with Fleiss κ. The score buckets
    from methodology §8 form the rating categories.

    If `panel_scores_path` does not exist or is empty, leaves `inter_rater`
    as null with an explanatory note.
    """
    if not panel_scores_path.exists():
        summary["inter_rater"] = {
            "fleiss_kappa": None,
            "n_items": 0,
            "n_raters": None,
            "note": f"panel scores file not present at {panel_scores_path}; populate after panel sitting",
        }
        return summary
    by_token: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    reviewers: set[str] = set()
    with panel_scores_path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            token = row["rec_token"]
            reviewer = row["reviewer"]
            score = str(row["score"])  # category bucket key
            by_token[token][score] += 1
            reviewers.add(reviewer)
    m = len(reviewers)
    items = [dict(counts) for counts in by_token.values()]
    if not items or m < 2:
        # Fleiss κ requires ≥2 raters per item to be defined. A 0- or
        # 1-reviewer file is a partial-panel state, not a κ value — emit a
        # structured sentinel so downstream consumers (results.md) can show
        # "panel pending" rather than crash on a ZeroDivisionError.
        note = (
            "panel scores file is empty or has no reviewers"
            if not items
            else f"only {m} reviewer(s) present; Fleiss κ requires ≥2"
        )
        summary["inter_rater"] = {
            "fleiss_kappa": None,
            "n_items": len(items),
            "n_raters": m,
            "note": note,
        }
        return summary
    kappa = fleiss_kappa(items, m=m)
    summary["inter_rater"] = {
        "fleiss_kappa": kappa,
        "n_items": len(items),
        "n_raters": m,
        "score_buckets": sorted({k for counts in items for k in counts}),
    }
    return summary


# ─── attach_collapsed_panel_kappa (judgment-level κ) ─────────────────────


def _median(values: list[float]) -> float:
    """Median of a non-empty list of floats. Even-count median averages the
    middle two values — may produce a value outside the rubric's score
    buckets, which is fine for Fleiss κ (categories are derived from
    observed values)."""
    s = sorted(values)
    n = len(s)
    if n % 2:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) / 2.0


def _variance(values: list[float]) -> float:
    """Population variance of a non-empty list of floats. 0.0 when all values
    are equal — that's the "reviewer was internally consistent across
    duplicates" signal we want.
    """
    n = len(values)
    if n <= 1:
        return 0.0
    mean = sum(values) / n
    return sum((v - mean) ** 2 for v in values) / n


def attach_collapsed_panel_kappa(
    summary: dict,
    panel_scores_path: Path,
    panel_routing_path: Path,
) -> dict:
    """Compute Fleiss κ over distinct (plant_id, cluster_id) judgments rather
    than over the per-(condition, trial) panel rows. Round-1's 12 panel-
    routed pairs are 2 cluster-plant calls duplicated across 3 trials × 2
    conditions, so the rec-level κ is inflated by item correlation. This
    function collapses each reviewer's set of scores per judgment to a
    median, then computes Fleiss κ over those medians.

    Output shape (assigned to summary["inter_rater_collapsed"]):

        {
          "fleiss_kappa": float | None,
          "n_judgments": int,
          "n_raters": int | None,
          "judgments": [
            {"plant_id": ..., "cluster_id": ...,
             "n_duplicates_per_reviewer": int,
             "reviewer_medians": {reviewer_id: float, ...},
             "reviewer_variance": {reviewer_id: float, ...}},
            ...
          ],
          "within_reviewer_inconsistency_count": int,
          "note": str | None,
        }

    `within_reviewer_inconsistency_count` is the number of (judgment,
    reviewer) cells where the reviewer's variance across duplicates is > 0
    — i.e., the reviewer didn't score every duplicate of that judgment
    identically. High counts mean reviewers are sensitive to the prose
    variation across trials, not just the underlying call.

    Sentinel emitted (fleiss_kappa=None, note populated) when:
      - panel_scores_path doesn't exist
      - panel_routing_path doesn't exist
      - fewer than 2 reviewers contributed scores
      - panel scores file is empty
    """
    if not panel_scores_path.exists():
        summary["inter_rater_collapsed"] = {
            "fleiss_kappa": None,
            "n_judgments": 0,
            "n_raters": None,
            "judgments": [],
            "within_reviewer_inconsistency_count": 0,
            "note": f"panel scores file not present at {panel_scores_path}; populate after panel sitting",
        }
        return summary
    if not panel_routing_path.exists():
        summary["inter_rater_collapsed"] = {
            "fleiss_kappa": None,
            "n_judgments": 0,
            "n_raters": None,
            "judgments": [],
            "within_reviewer_inconsistency_count": 0,
            "note": f"panel routing file not present at {panel_routing_path}; needed to map rec_token to judgment",
        }
        return summary

    # 1. Load the rec_token → (plant_id, cluster_id) mapping from panel-routing.
    token_to_judgment: dict[str, tuple[str, str]] = {}
    with panel_routing_path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            cluster_id = (row.get("unblind") or {}).get("cluster_id", "")
            token_to_judgment[row["rec_token"]] = (row["plant_id"], cluster_id)

    # 2. Load panel scores, grouping by (judgment, reviewer) → list of scores.
    by_cell: dict[tuple[str, str, str], list[float]] = defaultdict(list)
    reviewers: set[str] = set()
    orphan_tokens: set[str] = set()
    with panel_scores_path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            token = row["rec_token"]
            reviewer = row["reviewer"]
            score = row["score"]
            if not isinstance(score, (int, float)) or isinstance(score, bool):
                continue
            if token not in token_to_judgment:
                orphan_tokens.add(token)
                continue
            plant_id, cluster_id = token_to_judgment[token]
            by_cell[(plant_id, cluster_id, reviewer)].append(float(score))
            reviewers.add(reviewer)

    m = len(reviewers)
    note_parts = []
    if orphan_tokens:
        note_parts.append(
            f"{len(orphan_tokens)} orphan rec_token(s) in panel-scores had no matching panel-routing row; skipped"
        )

    # 3. Reduce per-(judgment, reviewer): median + variance.
    judgments_by_key: dict[tuple[str, str], dict] = {}
    inconsistency_count = 0
    for (plant_id, cluster_id, reviewer), scores in by_cell.items():
        key = (plant_id, cluster_id)
        if key not in judgments_by_key:
            judgments_by_key[key] = {
                "plant_id": plant_id,
                "cluster_id": cluster_id,
                "n_duplicates_per_reviewer": len(scores),
                "reviewer_medians": {},
                "reviewer_variance": {},
            }
        judgments_by_key[key]["reviewer_medians"][reviewer] = _median(scores)
        var = _variance(scores)
        judgments_by_key[key]["reviewer_variance"][reviewer] = var
        if var > 0:
            inconsistency_count += 1

    judgments = sorted(judgments_by_key.values(), key=lambda j: (j["plant_id"], j["cluster_id"]))
    n_judgments = len(judgments)

    if n_judgments == 0 or m < 2:
        note = (
            "panel scores file is empty or has no judgments"
            if n_judgments == 0
            else f"only {m} reviewer(s) present; Fleiss κ requires ≥2"
        )
        if note_parts:
            note = note + "; " + "; ".join(note_parts)
        summary["inter_rater_collapsed"] = {
            "fleiss_kappa": None,
            "n_judgments": n_judgments,
            "n_raters": m,
            "judgments": judgments,
            "within_reviewer_inconsistency_count": inconsistency_count,
            "note": note,
        }
        return summary

    # 4. Build the (item × category-count) matrix Fleiss κ expects.
    items: list[dict[str, int]] = []
    for j in judgments:
        counts: dict[str, int] = defaultdict(int)
        for reviewer in reviewers:
            if reviewer not in j["reviewer_medians"]:
                continue  # reviewer didn't cover this judgment
            counts[str(j["reviewer_medians"][reviewer])] += 1
        items.append(dict(counts))

    kappa = fleiss_kappa(items, m=m)
    summary["inter_rater_collapsed"] = {
        "fleiss_kappa": kappa,
        "n_judgments": n_judgments,
        "n_raters": m,
        "judgments": judgments,
        "within_reviewer_inconsistency_count": inconsistency_count,
        "note": "; ".join(note_parts) if note_parts else None,
    }
    return summary


# ─── loaders ──────────────────────────────────────────────────────────────


def load_plants(manifest_path: Path) -> list[dict]:
    with open(manifest_path) as f:
        m = yaml.safe_load(f)
    plants = m.get("plants") or []
    if not plants:
        raise ValueError(f"manifest has no plants entries: {manifest_path}")
    return plants


def load_rubric(rubric_path: Path) -> dict:
    with open(rubric_path) as f:
        return yaml.safe_load(f)


def load_parsed_records(parsed_dir: Path) -> list[dict]:
    records = []
    for cond_dir in sorted(parsed_dir.iterdir()):
        if not cond_dir.is_dir():
            continue
        for trial_dir in sorted(cond_dir.iterdir()):
            if not trial_dir.is_dir():
                continue
            for f in sorted(trial_dir.glob("*.json")):
                records.append(json.loads(f.read_text()))
    return records


# ─── output writers ───────────────────────────────────────────────────────


def _write_json(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")


def _write_panel_jsonl(path: Path, panel_routed: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # JSONL with stable line order; sort_keys for byte-stable diffs.
    with path.open("w") as f:
        for row in panel_routed:
            f.write(json.dumps(row, sort_keys=True) + "\n")


def _write_unblind(path: Path, panel_routed: list[dict]) -> None:
    """Panel-unblind map: token → {cluster_id, condition, trial}. Per Phase E
    plan §6 decision #3 this commits alongside results.md after the panel
    sitting; it lives behind a clear filename so reviewers can ignore it
    pre-sitting.
    """
    mapping = {row["rec_token"]: row["unblind"] for row in panel_routed}
    _write_json(path, {"schema_version": SCHEMA_VERSION, "tokens": mapping})


# ─── CLI ──────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).resolve().parent
    default_parsed = here / "trial-logs" / "parsed"
    default_manifest = here / "plant-manifest.yaml"
    default_rubric = here / "rubric.yaml"
    default_auto_scores = here / "analyses" / "auto-scores.json"
    default_summary = here / "analyses" / "score-summary.json"
    default_panel_routing = here / "analyses" / "panel-routing.jsonl"
    default_unblind = here / "analyses" / "panel-unblind.json"
    default_panel_scores = here / "analyses" / "panel-scores.jsonl"

    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--parsed", type=Path, default=default_parsed)
    ap.add_argument("--manifest", type=Path, default=default_manifest)
    ap.add_argument("--rubric", type=Path, default=default_rubric)
    ap.add_argument("--auto-scores-out", type=Path, default=default_auto_scores)
    ap.add_argument("--summary-out", type=Path, default=default_summary)
    ap.add_argument("--panel-routing-out", type=Path, default=default_panel_routing)
    ap.add_argument("--panel-unblind-out", type=Path, default=default_unblind)
    ap.add_argument("--panel-scores", type=Path, default=default_panel_scores,
                    help="Optional path to panel-scores.jsonl for Fleiss κ; if missing, inter_rater is null.")
    args = ap.parse_args(argv)

    if not args.parsed.is_dir():
        print(f"error: --parsed not a directory: {args.parsed}", file=sys.stderr)
        return 2
    if not args.manifest.is_file():
        print(f"error: manifest not found: {args.manifest}", file=sys.stderr)
        return 2
    if not args.rubric.is_file():
        print(f"error: rubric not found: {args.rubric}", file=sys.stderr)
        return 2

    plants = load_plants(args.manifest)
    rubric = load_rubric(args.rubric)
    parsed_records = load_parsed_records(args.parsed)
    if not parsed_records:
        print(f"error: no parsed records under {args.parsed}", file=sys.stderr)
        return 2

    scored = score_recommendations(parsed_records, plants, rubric)
    promote_panel_scores(scored, args.panel_scores)
    summary = aggregate_summary(scored, plants)
    attach_panel_kappa(summary, args.panel_scores)

    # Write panel-routing.jsonl BEFORE attach_collapsed_panel_kappa so it has
    # the rec_token → (plant_id, cluster_id) map available. The collapsed-κ
    # block reduces the panel-routed rec rows to distinct (plant_id,
    # cluster_id) judgments (round-1 panel is duplicated across (condition,
    # trial)) and computes κ over the median per judgment-reviewer cell.
    _write_panel_jsonl(args.panel_routing_out, scored["panel_routed"])
    attach_collapsed_panel_kappa(summary, args.panel_scores, args.panel_routing_out)

    _write_json(args.auto_scores_out, scored)
    _write_json(args.summary_out, summary)
    _write_unblind(args.panel_unblind_out, scored["panel_routed"])

    # Console digest
    print(
        f"score_all: scored_pairs={summary['counts']['n_scored_pairs']} "
        f"unmatched={summary['counts']['n_unmatched_recs']} "
        f"parse_errors={summary['counts']['n_parse_errors']} "
        f"panel_routed={summary['counts']['n_panel_routed_pairs']}",
        file=sys.stderr,
    )
    for cond in sorted(summary["headline"]):
        h = summary["headline"][cond]
        rr = summary["panel_route_rate"][cond]
        recall = f"{h['canonical_recall']:.3f}" if h["canonical_recall"] is not None else "n/a"
        fpr = f"{h['fpr']:.3f}" if h["fpr"] is not None else "n/a"
        rate = f"{rr['fraction']:.3f}" if rr["fraction"] is not None else "n/a"
        flag = "" if rr["passes_threshold"] in (True, None) else " [EXCEEDS §14.3 BAR]"
        print(
            f"  {cond}: canonical_recall={recall} fpr={fpr} panel_route_rate={rate}{flag}",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
