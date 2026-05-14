#!/usr/bin/env python3
"""
analyzer.py — V7 refactor-recommendation plant-recall analyzer.

Reads the V7 plant manifest (YAML) and the JSONL cluster outputs produced
by scripts/generate-clusters-v7.sh, then reports per-plant recall under
S1 (V6 substrate) and S2 (V7 substrate) conditions.

A plant is considered "recalled" under a condition if at least one of its
manifest-declared `expected_substrate_signals` queries surfaces a cluster
row that mentions one of the plant's `source_files` paths. Recall is
plant-level, not row-count: a single cluster row covering a plant counts
once.

Phase C acceptance per plan §4.4: S2 recall must be ≥ 23/25; otherwise
either fix the plant authoring / query parameters, or annotate the failing
plant with `expected_substrate_gap: true` per the V6 precedent for plant 20.

Usage:
  analyzer.py --manifest path/to/plant-manifest.yaml \\
              --clusters-s1 path/to/clusters-s1/ \\
              --clusters-s2 path/to/clusters-s2/ \\
              [--threshold 23]

Exit codes:
  0 — S2 recall met threshold
  1 — S2 recall below threshold (and no annotations explain the gap)
  2 — invocation error (missing files etc.)

This script is intentionally pure-Python + PyYAML; no Node.js dependency.
The plan §4.4 calls for `analyzer.mjs` but V7's downstream tooling
(auto-scorer.py, validate-manifest.py) is Python-based and shares the
PyYAML dep; keeping the analyzer in Python avoids language fragmentation
without changing the analyzer's contract.
"""

import argparse
import json
import os
import sys

try:
    import yaml
except ImportError:
    sys.stderr.write("ERROR: PyYAML not installed. Run: pip install pyyaml\n")
    sys.exit(2)


def load_clusters(dir_path: str) -> dict[str, list[dict]]:
    """Load JSONL cluster outputs from a directory.

    Returns {query_name: [row, row, ...]} where query_name is the JSONL
    filename minus its `.jsonl` suffix.
    """
    clusters: dict[str, list[dict]] = {}
    if not os.path.isdir(dir_path):
        return clusters
    for fname in sorted(os.listdir(dir_path)):
        if not fname.endswith(".jsonl"):
            continue
        query = fname[: -len(".jsonl")]
        path = os.path.join(dir_path, fname)
        rows: list[dict] = []
        with open(path) as f:
            for lineno, line in enumerate(f, start=1):
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError as exc:
                    sys.stderr.write(
                        f"warning: bad JSONL at {path}:{lineno}: {exc}\n"
                    )
        clusters[query] = rows
    return clusters


def collect_file_paths(obj) -> set[str]:
    """Walk obj recursively, collect every string value under a key named 'file'.

    Cluster rows nest their file references in various shapes (top-level
    `file`, inside `decls[]`, inside `a`/`b` pairs). This walks the whole
    JSON tree and pulls every `file:` string out without needing per-query
    schema knowledge.
    """
    out: set[str] = set()
    stack = [obj]
    while stack:
        current = stack.pop()
        if isinstance(current, dict):
            for key, value in current.items():
                if key == "file" and isinstance(value, str):
                    out.add(value)
                else:
                    stack.append(value)
        elif isinstance(current, list):
            stack.extend(current)
    return out


def plant_hits(plant: dict, clusters: dict[str, list[dict]]) -> list[tuple[str, str]]:
    """Return [(signal, cluster_id), ...] for each expected_substrate_signal
    where the plant surfaces. Empty if plant didn't surface in any expected
    signal.

    "Surface" means: at least one cluster row in `clusters[signal]` has a
    file path overlapping `plant.source_files[]`.
    """
    hits: list[tuple[str, str]] = []
    plant_paths = set(plant.get("source_files") or [])
    if not plant_paths:
        return hits
    for signal in plant.get("expected_substrate_signals") or []:
        for row in clusters.get(signal, []):
            row_paths = collect_file_paths(row)
            if plant_paths & row_paths:
                cid = row.get("cluster_id", "(no cluster_id)")
                hits.append((signal, cid))
                break  # one hit per signal is enough; move to the next signal
    return hits


def main() -> int:
    parser = argparse.ArgumentParser(
        description="V7 plant-recall analyzer (plan §4.4)"
    )
    parser.add_argument("--manifest", required=True, help="plant-manifest.yaml path")
    parser.add_argument("--clusters-s1", required=True,
                        help="dir of S1 cluster JSONL outputs (V6 queries)")
    parser.add_argument("--clusters-s2", required=True,
                        help="dir of S2 cluster JSONL outputs (V6 + V7 queries)")
    parser.add_argument("--threshold", type=int, default=23,
                        help="min S2 plant recall for acceptance (default: 23)")
    args = parser.parse_args()

    if not os.path.isfile(args.manifest):
        sys.stderr.write(f"ERROR: manifest not found: {args.manifest}\n")
        return 2

    with open(args.manifest) as f:
        manifest = yaml.safe_load(f)
    plants = manifest.get("plants") or []
    if not plants:
        sys.stderr.write("ERROR: manifest has no `plants` entries\n")
        return 2

    s1 = load_clusters(args.clusters_s1)
    s2 = load_clusters(args.clusters_s2)

    overall_failed = False

    for condition, clusters, label in [
        ("S1", s1, "V6 substrate"),
        ("S2", s2, "V7 substrate"),
    ]:
        print(f"\n=== {condition} ({label}) ===")
        recalled = 0
        gapped = 0
        for plant in plants:
            pid = plant.get("plant_id", "?")
            cat = plant.get("category", "?")
            hits = plant_hits(plant, clusters)
            if hits:
                recalled += 1
                signals_str = ", ".join(sig for sig, _ in hits)
                print(f"  ✓ {pid:<6} [{cat}] → {signals_str}")
            else:
                expected = plant.get("expected_substrate_signals") or []
                expected_str = ", ".join(expected)
                if plant.get("expected_substrate_gap"):
                    gapped += 1
                    print(f"  · {pid:<6} [{cat}] — annotated gap (expected: {expected_str})")
                else:
                    print(f"  ✗ {pid:<6} [{cat}] — missed (expected: {expected_str})")

        total = len(plants)
        effective = recalled + gapped
        print(f"\n{condition}: {recalled}/{total} plants recalled"
              + (f" (+{gapped} annotated gaps → {effective}/{total} effective)" if gapped else ""))

        if condition == "S2":
            if effective < args.threshold:
                sys.stderr.write(
                    f"\nFAIL: S2 effective recall {effective}/{total} below "
                    f"threshold {args.threshold}\n"
                )
                overall_failed = True
            else:
                print(f"S2 acceptance: {effective}/{total} ≥ {args.threshold}  ✓")

    return 1 if overall_failed else 0


if __name__ == "__main__":
    sys.exit(main())
