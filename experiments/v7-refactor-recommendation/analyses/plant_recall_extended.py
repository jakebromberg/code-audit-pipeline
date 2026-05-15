#!/usr/bin/env python3
"""Phase E PR-E2 — plant-recall confirm against parsed categories.

Extends `examples/swift-plants-v7/analyzer.py` (which checks
`expected_substrate_signals` presence at the cluster-row level) by adding a
parallel check: for each of the 25 plants, did the parsed-recommendation
*category* match the manifest's `primary_answer.category` in any trial under
S2?

The signal-presence helpers (`plant_hits`, `collect_file_paths`) are imported
from `analyzer.py` as a library per Phase E plan §2.1. The category-recall
walk operates on the parsed cache written by `parse_responses.py` (PR-E1)
and matches recs to plants via substring-membership of the plant's
`source_files[]` paths in the rec's `cluster_id` string.

Plant 5.3 escalation: per Phase E plan §6 decision #4, if the parsed
categories also do not surface Plant 5.3, the output's `plant_5_3` block is
flagged for a substrate-recall follow-up issue. The round 1 manifest stays
frozen; manifest tuning is a round 2 concern.

Run from the repo root:

  python3 experiments/v7-refactor-recommendation/analyses/plant_recall_extended.py
  python3 experiments/v7-refactor-recommendation/analyses/plant_recall_extended.py \\
      --parsed experiments/v7-refactor-recommendation/trial-logs/parsed \\
      --manifest experiments/v7-refactor-recommendation/plant-manifest.yaml \\
      --output experiments/v7-refactor-recommendation/analyses/plant-recall-extended.json \\
      [--clusters-s1 PATH --clusters-s2 PATH]

If `--clusters-s1` / `--clusters-s2` are supplied, the signal-recall column is
populated by re-running `analyzer.plant_hits` against the JSONL cluster
outputs. The cluster JSONLs are not committed (regeneratable via
`scripts/generate-clusters-v7.sh`), so this argument is optional; without
it, the signal-recall column is reported as `null` with a one-line note.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("ERROR: PyYAML not installed. Run: pip install pyyaml\n")
    sys.exit(2)

# Import analyzer.py from examples/swift-plants-v7/ as a library. Per Phase E
# plan §2.1: "import the existing analyzer's plant-loading + signal-matching
# helpers as a library; do not duplicate the manifest-walking logic."
_HERE = Path(__file__).resolve().parent
_REPO_ROOT = _HERE.parents[2]
_ANALYZER_DIR = _REPO_ROOT / "examples" / "swift-plants-v7"
sys.path.insert(0, str(_ANALYZER_DIR))
import analyzer as _analyzer  # noqa: E402

SCHEMA_VERSION = "1.0"
PLANT_5_3_ID = "5.3"

# A cluster_id is a string of `query:pkglayer:pkgname:path:line:symbol`
# tokens joined by `+`, where each `path` ends in `.swift`. Splitting on the
# token delimiters (`:` and `+`) and keeping `.swift`-suffixed tokens
# recovers the file path set. The path itself may contain `/` but never `:`
# or `+`, so the split is unambiguous.
_TOKEN_RE = re.compile(r"[:+]")


def cluster_id_files(cluster_id: str) -> set[str]:
    """Extract the set of `.swift` file paths embedded in a cluster_id string."""
    if not cluster_id:
        return set()
    return {tok for tok in _TOKEN_RE.split(cluster_id) if tok.endswith(".swift")}


def _alternative_categories(plant: dict) -> set[str]:
    return {
        a.get("category")
        for a in (plant.get("alternative_answers") or [])
        if a.get("category")
    }


def _classify_match(plant: dict, rec_category: str | None) -> str | None:
    """Return 'primary', 'alternative', or None."""
    if not rec_category:
        return None
    primary = (plant.get("primary_answer") or {}).get("category")
    if rec_category == primary:
        return "primary"
    if rec_category in _alternative_categories(plant):
        return "alternative"
    return None


def category_recall_for_plant(plant: dict, parsed_records: list[dict]) -> dict:
    """For one plant, walk parsed recs and return per-condition match info.

    Returns:
        {
          "s1": {"matches": [...], "surfaced": bool},
          "s2": {"matches": [...], "surfaced": bool}
        }

    `surfaced` is true iff at least one parsed rec under the condition
    references one of the plant's source_files in its cluster_id AND that
    rec's `parsed.category` matches the plant's `primary_answer.category`.
    Alternative-category matches are recorded but do not flip `surfaced`.
    """
    plant_paths = set(plant.get("source_files") or [])
    out: dict[str, dict] = {
        "s1": {"matches": [], "surfaced": False},
        "s2": {"matches": [], "surfaced": False},
    }
    if not plant_paths:
        return out

    for rec in parsed_records:
        if rec.get("parse_error"):
            continue
        cond = rec.get("condition")
        if cond not in out:
            continue
        rec_paths = cluster_id_files(rec.get("cluster_id", ""))
        if not (plant_paths & rec_paths):
            continue
        parsed = rec.get("parsed") or {}
        rec_cat = parsed.get("category")
        match_kind = _classify_match(plant, rec_cat)
        if match_kind is None:
            continue
        out[cond]["matches"].append(
            {
                "cluster_id": rec["cluster_id"],
                "trial": rec.get("trial"),
                "query": rec.get("query"),
                "category": rec_cat,
                "match": match_kind,
            }
        )
        if match_kind == "primary":
            out[cond]["surfaced"] = True

    for cond in ("s1", "s2"):
        out[cond]["matches"].sort(
            key=lambda m: (m.get("trial") or 0, m.get("query") or "", m["cluster_id"])
        )
    return out


def _signal_recall_for_plant(
    plant: dict,
    clusters_s1: dict | None,
    clusters_s2: dict | None,
) -> dict:
    out = {}
    for cond_label, clusters in (("s1", clusters_s1), ("s2", clusters_s2)):
        if clusters is None:
            out[cond_label] = None
            continue
        hits = _analyzer.plant_hits(plant, clusters)
        out[cond_label] = {
            "signals_hit": sorted({sig for sig, _ in hits}),
            "cluster_ids": [cid for _, cid in hits],
            "surfaced": bool(hits),
        }
    return out


def analyze(
    *,
    plants: list[dict],
    parsed_records: list[dict],
    clusters_s1: dict | None = None,
    clusters_s2: dict | None = None,
) -> dict:
    """Compute the full plant-recall-extended report.

    Returns a deterministic, JSON-serializable dict.
    """
    plant_blocks = []
    aggregate = {
        "n_plants": len(plants),
        "s1": {"surfaced_by_category": 0, "surfaced_by_signal": None},
        "s2": {"surfaced_by_category": 0, "surfaced_by_signal": None},
    }
    if clusters_s1 is not None:
        aggregate["s1"]["surfaced_by_signal"] = 0
    if clusters_s2 is not None:
        aggregate["s2"]["surfaced_by_signal"] = 0

    plant_5_3_block = None
    for plant in plants:
        cat_recall = category_recall_for_plant(plant, parsed_records)
        sig_recall = _signal_recall_for_plant(plant, clusters_s1, clusters_s2)

        primary = (plant.get("primary_answer") or {}).get("category")
        alts = sorted(_alternative_categories(plant))
        block = {
            "plant_id": plant["plant_id"],
            "category": plant.get("category"),
            "primary_answer_category": primary,
            "alternative_categories": alts,
            "restraint": bool(plant.get("restraint")),
            "source_files": sorted(plant.get("source_files") or []),
            "recall_by_signal": sig_recall,
            "recall_by_category": cat_recall,
        }
        plant_blocks.append(block)

        for cond in ("s1", "s2"):
            if cat_recall[cond]["surfaced"]:
                aggregate[cond]["surfaced_by_category"] += 1
            if sig_recall[cond] and sig_recall[cond]["surfaced"]:
                aggregate[cond]["surfaced_by_signal"] += 1

        if plant["plant_id"] == PLANT_5_3_ID:
            surfaced_s2 = cat_recall["s2"]["surfaced"]
            plant_5_3_block = {
                "plant_id": PLANT_5_3_ID,
                "surfaced_by_category_s2": surfaced_s2,
                "escalation_flag": not surfaced_s2,
                "escalation_action": "none" if surfaced_s2 else "file-substrate-recall-followup",
                "note": (
                    "Plant 5.3's declared expected_substrate_signals did not "
                    "surface it in Phase C; this analysis checks whether the "
                    "parsed categories close the gap. Plan §6 decision #4: round "
                    "1 manifest stays frozen; escalation means filing a "
                    "substrate-recall follow-up issue, not modifying the manifest."
                ),
            }

    plant_blocks.sort(key=lambda p: p["plant_id"])

    return {
        "schema_version": SCHEMA_VERSION,
        "config": {
            "match_strategy": "cluster_id substring match against plant.source_files; primary category match flips `surfaced`",
            "plant_5_3_id": PLANT_5_3_ID,
        },
        "aggregate": aggregate,
        "plants": plant_blocks,
        "plant_5_3": plant_5_3_block,
    }


# ─── loaders ──────────────────────────────────────────────────────────────


def load_plants(manifest_path: Path) -> list[dict]:
    with open(manifest_path) as f:
        m = yaml.safe_load(f)
    plants = m.get("plants") or []
    if not plants:
        raise ValueError(f"manifest has no plants entries: {manifest_path}")
    return plants


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


# ─── CLI ──────────────────────────────────────────────────────────────────


def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).resolve().parent
    exp_dir = here.parent
    default_parsed = exp_dir / "trial-logs" / "parsed"
    default_manifest = exp_dir / "plant-manifest.yaml"
    default_output = here.parent / "analyses" / "plant-recall-extended.json"

    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--parsed", type=Path, default=default_parsed)
    ap.add_argument("--manifest", type=Path, default=default_manifest)
    ap.add_argument("--output", type=Path, default=default_output)
    ap.add_argument(
        "--clusters-s1",
        type=Path,
        default=None,
        help="Optional path to S1 cluster JSONL directory (for signal-recall column).",
    )
    ap.add_argument(
        "--clusters-s2",
        type=Path,
        default=None,
        help="Optional path to S2 cluster JSONL directory.",
    )
    args = ap.parse_args(argv)

    if not args.manifest.is_file():
        print(f"error: manifest not found: {args.manifest}", file=sys.stderr)
        return 2
    if not args.parsed.is_dir():
        print(f"error: --parsed not a directory: {args.parsed}", file=sys.stderr)
        return 2

    plants = load_plants(args.manifest)
    parsed_records = load_parsed_records(args.parsed)
    if not parsed_records:
        print(f"error: no parsed records found under {args.parsed}", file=sys.stderr)
        return 2

    clusters_s1 = _analyzer.load_clusters(str(args.clusters_s1)) if args.clusters_s1 else None
    clusters_s2 = _analyzer.load_clusters(str(args.clusters_s2)) if args.clusters_s2 else None

    doc = analyze(
        plants=plants,
        parsed_records=parsed_records,
        clusters_s1=clusters_s1,
        clusters_s2=clusters_s2,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")

    agg = doc["aggregate"]
    print(
        f"plant_recall_extended: n_plants={agg['n_plants']} "
        f"category_surface s1={agg['s1']['surfaced_by_category']} s2={agg['s2']['surfaced_by_category']}",
        file=sys.stderr,
    )
    if doc["plant_5_3"]:
        p53 = doc["plant_5_3"]
        flag = "ESCALATE" if p53["escalation_flag"] else "ok"
        print(
            f"  plant 5.3: surfaced_by_category_s2={p53['surfaced_by_category_s2']} [{flag}]",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
