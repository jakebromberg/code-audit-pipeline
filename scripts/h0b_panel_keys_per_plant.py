#!/usr/bin/env python3
"""Pre-flight helper for the V7 H0b curation pass (per the rubric-loosening plan §3.3).

Enumerates which `primary_answer.specifics` keys per plant ever routed to panel under
`primary_match_specifics_*` reasons in the v1-clean control corpus. The curator uses
this output to scope their blessed-alternative work: for each (plant, key) the script
reports, the curator considers whether to add up to 3 alternative values.

Criterion-(c) blindness (per plan §3.2): the curator must NOT see the agent's emitted
values at curation time. To preserve that property, this script reads ONLY the
`match_reason` and `notes[*]` fields of `panel-routing.jsonl`, and from each note it
extracts ONLY the `key='<name>'` token. Manifest values (already known to the curator
from `plant-manifest.yaml`) and rec values (the criterion-(c) sensitive content) are
both elided from the output.

The script is read-only against artifacts. It writes to stdout only.

Usage
-----
    python3 scripts/h0b_panel_keys_per_plant.py
    python3 scripts/h0b_panel_keys_per_plant.py \\
        --panel-routing experiments/v7-refactor-recommendation/analyses-v1-clean/panel-routing.jsonl
    python3 scripts/h0b_panel_keys_per_plant.py --format json

Exit code: 0 on success; 1 on file-missing / parse error.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PANEL_ROUTING = (
    REPO_ROOT
    / "experiments/v7-refactor-recommendation/analyses-v1-clean/panel-routing.jsonl"
)

# Only `primary_match_specifics_*` match reasons are scope for H0b's loosening.
SPECIFICS_MATCH_REASON_PREFIX = "primary_match_specifics_"

# Inverse of the note-format producer at experiments/v7-refactor-recommendation/
# auto-scorer.py (see _specifics_values_match). If that producer's format ever
# changes, update this regex in lockstep.
KEY_PATTERN = re.compile(r"^key='([^']+)'")


def _extract_key(note: str) -> str | None:
    """Return the `<name>` from a `key='<name>' manifest=... rec=...` note, or None.

    Only the key name is returned. Manifest and rec substrings are NOT parsed and NOT
    returned — preserving curation-time blindness per plan §3.2 criterion (c).
    """
    match = KEY_PATTERN.match(note)
    return match.group(1) if match else None


def collect_keys_per_plant(panel_routing_path: Path) -> dict[str, set[str]]:
    """Read panel-routing.jsonl and return {plant_id: {key_names_with_specifics_panel_route}}.

    Only rows with `match_reason` starting with `primary_match_specifics_` contribute;
    other panel-routing reasons fall outside H0b's loosening scope.
    """
    keys_by_plant: dict[str, set[str]] = defaultdict(set)
    with panel_routing_path.open() as fh:
        for line_no, line in enumerate(fh, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as exc:
                print(
                    f"warning: line {line_no} of {panel_routing_path} not valid JSON: {exc}",
                    file=sys.stderr,
                )
                continue
            reason = row.get("match_reason", "")
            if not reason.startswith(SPECIFICS_MATCH_REASON_PREFIX):
                continue
            plant_id = row.get("plant_id")
            if not isinstance(plant_id, str):
                continue
            notes = row.get("notes")
            if not isinstance(notes, list):
                continue
            for note in notes:
                if not isinstance(note, str):
                    continue
                key = _extract_key(note)
                if key is not None:
                    keys_by_plant[plant_id].add(key)
    return keys_by_plant


def format_text(keys_by_plant: dict[str, set[str]]) -> str:
    """One line per plant: `<plant_id>  <comma-separated keys>`."""
    if not keys_by_plant:
        return "(no plants had primary_match_specifics_* panel routes)\n"
    width = max(len(pid) for pid in keys_by_plant)
    lines = []
    for plant_id in sorted(keys_by_plant, key=lambda p: tuple(int(x) for x in p.split("."))):
        keys = sorted(keys_by_plant[plant_id])
        lines.append(f"{plant_id:<{width}}  {', '.join(keys)}")
    return "\n".join(lines) + "\n"


def format_json(keys_by_plant: dict[str, set[str]]) -> str:
    out = {pid: sorted(keys) for pid, keys in keys_by_plant.items()}
    return json.dumps(out, indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--panel-routing",
        type=Path,
        default=DEFAULT_PANEL_ROUTING,
        help="Path to panel-routing.jsonl (default: analyses-v1-clean/panel-routing.jsonl)",
    )
    parser.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
        help="Output format (default: text)",
    )
    args = parser.parse_args()

    try:
        keys_by_plant = collect_keys_per_plant(args.panel_routing)
    except FileNotFoundError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    output = format_text(keys_by_plant) if args.format == "text" else format_json(keys_by_plant)
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    sys.exit(main())
