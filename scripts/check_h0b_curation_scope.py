#!/usr/bin/env python3
"""V7 H0b curation-scope pre-flight (PR 2 merge-blocker per the rubric-loosening plan §3.2.2 / §5).

PR 2 of the H0b sub-experiment chain adds blessed-alternative declarations to
`plant-manifest.yaml`. The plan constrains that diff three ways:

  (a) Only `plant-manifest.yaml` is touched (no `trial-logs-v1-clean/` reads, no
      auto-scorer edits, no other files at all). Auto-scorer changes are PR 3's
      scope; pre-registration freezes are already in PR 1.
  (b) Only the 17 panel-routed plants in the round-2/3 corpus are touched.
      Adding alternatives to unrelated plants would muddy the H0b comparison.
  (c) Only `primary_answer.specifics_alternatives` and
      `primary_answer.specifics_alternatives_rationale` fields are added.
      Canonical `primary_answer.specifics` values must NOT change — that
      would silently alter the v1-clean baseline auto-scoring outcomes
      and entangle H0b's measured drop with manifest drift.

This script enforces (a)-(c) by parsing both the base-ref and working-tree copies of
`plant-manifest.yaml`, comparing per-plant. It exits 0 if all three constraints hold,
1 otherwise. The PR 2 author runs the script, pastes its stdout into the PR 2
description per the plan §5 acceptance checklist, and re-runs after each iteration
until it passes.

Usage
-----
    python3 scripts/check_h0b_curation_scope.py
    python3 scripts/check_h0b_curation_scope.py --base-ref experiment/swift-substrate
    python3 scripts/check_h0b_curation_scope.py --manifest path/to/plant-manifest.yaml

The base-ref's manifest is read via `git show <ref>:<path>`. By default the base ref
is `experiment/swift-substrate` (the round-2/3 PR convention per plan §6).

Exit codes
----------
    0 — all three constraints satisfied (PR 2 is mergeable on scope grounds).
    1 — one or more constraints violated; details printed to stderr.
    2 — git invocation failed, manifest unparseable, or other infrastructure error.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = REPO_ROOT / "experiments/v7-refactor-recommendation/plant-manifest.yaml"
DEFAULT_BASE_REF = "experiment/swift-substrate"

# The 17 panel-routed plants in the v1-clean corpus (per
# analyses-v1-clean/panel-routing.jsonl). Frozen at plan-merge time so the scope
# check is stable across runs. If a future round re-runs the auto-scorer and a
# different plant set routes to panel, edit this constant in a follow-up PR with
# corresponding plan amendment.
PANEL_ROUTED_PLANTS: frozenset[str] = frozenset(
    {
        "1.1",
        "2.1", "2.2", "2.3", "2.4",
        "3.1", "3.2", "3.3", "3.4",
        "4.1", "4.2", "4.3", "4.4",
        "5.1", "5.2", "5.3", "5.4",
    }
)

# The only fields PR 2 is allowed to ADD under primary_answer. Any other added
# field, and any modification to existing fields, fails the check.
H0B_ADDABLE_FIELDS: frozenset[str] = frozenset(
    {"specifics_alternatives", "specifics_alternatives_rationale"}
)


def load_manifest_from_ref(ref: str, path: Path) -> dict:
    """Use `git show` to load the manifest at the given ref. Raises CalledProcessError on failure."""
    repo_relative = path.resolve().relative_to(REPO_ROOT)
    cmd = ["git", "-C", str(REPO_ROOT), "show", f"{ref}:{repo_relative}"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    parsed = yaml.safe_load(result.stdout)
    if not isinstance(parsed, dict) or not isinstance(parsed.get("plants"), list):
        raise ValueError(f"manifest at {ref}:{repo_relative} has no top-level `plants:` list")
    return parsed


def load_manifest_from_path(path: Path) -> dict:
    with path.open() as fh:
        parsed = yaml.safe_load(fh)
    if not isinstance(parsed, dict) or not isinstance(parsed.get("plants"), list):
        raise ValueError(f"manifest at {path} has no top-level `plants:` list")
    return parsed


def index_by_plant_id(manifest: dict) -> dict[str, dict]:
    return {
        plant["plant_id"]: plant
        for plant in manifest["plants"]
        if isinstance(plant, dict) and isinstance(plant.get("plant_id"), str)
    }


def _diff_primary_answer(
    plant_id: str, base_primary: dict, head_primary: dict
) -> list[str]:
    """Compare `primary_answer` blocks between base and head versions of a plant.

    Returns the list of scope violations as human-readable strings. Empty list iff
    the head version differs from base only by adding `specifics_alternatives` and/or
    `specifics_alternatives_rationale` fields (constraint (c)).
    """
    violations: list[str] = []
    base_keys = set(base_primary)
    head_keys = set(head_primary)

    added = head_keys - base_keys
    bad_added = added - H0B_ADDABLE_FIELDS
    if bad_added:
        violations.append(
            f"plant {plant_id}: primary_answer adds unauthorized field(s) "
            f"{sorted(bad_added)} — only {sorted(H0B_ADDABLE_FIELDS)} may be added"
        )

    removed = base_keys - head_keys
    if removed:
        violations.append(
            f"plant {plant_id}: primary_answer removes field(s) {sorted(removed)} "
            "— PR 2 may only ADD; canonical fields must remain"
        )

    for key in base_keys & head_keys:
        if base_primary[key] != head_primary[key]:
            violations.append(
                f"plant {plant_id}: primary_answer.{key} value changed — canonical "
                "fields must remain byte-equal under H0b (PR 2 is curation-only, "
                "no canonical edits)"
            )

    return violations


def _diff_plant_root(plant_id: str, base_plant: dict, head_plant: dict) -> list[str]:
    """Compare top-level plant fields (excluding primary_answer). Returns violation list."""
    violations: list[str] = []
    base_keys = set(base_plant) - {"primary_answer"}
    head_keys = set(head_plant) - {"primary_answer"}

    added = head_keys - base_keys
    if added:
        violations.append(
            f"plant {plant_id}: top-level field(s) {sorted(added)} added — H0b only "
            "extends primary_answer.specifics_alternatives*; no top-level changes allowed"
        )
    removed = base_keys - head_keys
    if removed:
        violations.append(
            f"plant {plant_id}: top-level field(s) {sorted(removed)} removed — H0b is "
            "additive only on primary_answer; no top-level deletions allowed"
        )
    for key in base_keys & head_keys:
        if base_plant[key] != head_plant[key]:
            violations.append(
                f"plant {plant_id}: top-level field {key!r} changed value — H0b is "
                "additive only on primary_answer"
            )
    return violations


def check_scope(
    base_manifest: dict, head_manifest: dict
) -> tuple[list[str], dict[str, dict]]:
    """Apply constraints (b) and (c). Constraint (a) is enforced by the caller (git diff
    file-list check). Returns (violations, head_by_id) so the caller can reuse the index."""
    violations: list[str] = []

    base_by_id = index_by_plant_id(base_manifest)
    head_by_id = index_by_plant_id(head_manifest)

    added_plants = set(head_by_id) - set(base_by_id)
    removed_plants = set(base_by_id) - set(head_by_id)
    if added_plants:
        violations.append(f"plants added in PR 2 (not allowed): {sorted(added_plants)}")
    if removed_plants:
        violations.append(f"plants removed in PR 2 (not allowed): {sorted(removed_plants)}")

    for plant_id in sorted(base_by_id.keys() & head_by_id.keys()):
        base_plant = base_by_id[plant_id]
        head_plant = head_by_id[plant_id]

        violations.extend(_diff_plant_root(plant_id, base_plant, head_plant))

        base_primary = base_plant.get("primary_answer", {})
        head_primary = head_plant.get("primary_answer", {})
        if not isinstance(base_primary, dict):
            violations.append(f"plant {plant_id}: base primary_answer is not a dict")
            continue
        if not isinstance(head_primary, dict):
            violations.append(f"plant {plant_id}: head primary_answer is not a dict")
            continue

        primary_violations = _diff_primary_answer(plant_id, base_primary, head_primary)

        if primary_violations and plant_id not in PANEL_ROUTED_PLANTS:
            violations.append(
                f"plant {plant_id}: primary_answer modified but plant is NOT in the "
                f"{len(PANEL_ROUTED_PLANTS)}-plant panel-routed scope; "
                "H0b curation must not touch unrelated plants"
            )
        violations.extend(primary_violations)

    return violations, head_by_id


def check_files_touched(base_ref: str, manifest_path: Path) -> list[str]:
    """Constraint (a): the only file touched in PR 2 is the manifest. Anything else fails."""
    violations: list[str] = []
    repo_relative = manifest_path.resolve().relative_to(REPO_ROOT)
    cmd = ["git", "-C", str(REPO_ROOT), "diff", "--name-only", f"{base_ref}...HEAD"]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    touched = sorted(line for line in result.stdout.splitlines() if line.strip())
    unexpected = [f for f in touched if f != str(repo_relative)]
    if unexpected:
        violations.append(
            f"PR 2 touches files other than {repo_relative}: {unexpected} — "
            "constraint (a) requires manifest-only diff"
        )
    return violations


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_MANIFEST,
        help="Path to the head-tree plant-manifest.yaml",
    )
    parser.add_argument(
        "--base-ref",
        default=DEFAULT_BASE_REF,
        help=f"Git ref to compare against (default: {DEFAULT_BASE_REF})",
    )
    parser.add_argument(
        "--skip-files-check",
        action="store_true",
        help="Skip constraint (a) — file-list check. Useful in unit tests that fabricate "
        "manifest dicts directly without populating a working tree.",
    )
    args = parser.parse_args()

    try:
        head_manifest = load_manifest_from_path(args.manifest)
    except (OSError, ValueError) as exc:
        print(f"error: failed to load head manifest: {exc}", file=sys.stderr)
        return 2

    try:
        base_manifest = load_manifest_from_ref(args.base_ref, args.manifest)
    except (subprocess.CalledProcessError, ValueError) as exc:
        print(f"error: failed to load base manifest at {args.base_ref}: {exc}", file=sys.stderr)
        return 2

    all_violations: list[str] = []
    if not args.skip_files_check:
        try:
            all_violations.extend(check_files_touched(args.base_ref, args.manifest))
        except subprocess.CalledProcessError as exc:
            print(f"error: git diff failed: {exc.stderr}", file=sys.stderr)
            return 2
    scope_violations, head_by_id = check_scope(base_manifest, head_manifest)
    all_violations.extend(scope_violations)

    if all_violations:
        print(f"FAIL: {len(all_violations)} H0b curation-scope violation(s):", file=sys.stderr)
        for v in all_violations:
            print(f"  - {v}", file=sys.stderr)
        return 1

    # Successful report — stdout content is pasted into PR 2 description per plan §5.
    touched_plants = sorted(
        pid for pid, p in head_by_id.items()
        if p.get("primary_answer", {}).get("specifics_alternatives")
        or p.get("primary_answer", {}).get("specifics_alternatives_rationale")
    )
    print(f"OK: H0b curation-scope pre-flight passed against base={args.base_ref}.")
    print(f"  (a) Files touched: {args.manifest.relative_to(REPO_ROOT)} only — passed.")
    print(
        f"  (b) Plants modified: {len(touched_plants)} of {len(PANEL_ROUTED_PLANTS)} "
        f"panel-routed plants — passed."
        + (f" ({', '.join(touched_plants)})" if touched_plants else "")
    )
    print(
        "  (c) Fields modified: only `primary_answer.specifics_alternatives` and "
        "`primary_answer.specifics_alternatives_rationale` added; no canonical edits — passed."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
