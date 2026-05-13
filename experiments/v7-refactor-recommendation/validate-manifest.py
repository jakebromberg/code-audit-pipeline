#!/usr/bin/env python3
"""Validate plant-manifest.yaml against the wxyc-ios-64 catalog.

Checks performed:
  1. yaml syntactically valid; top-level shape has `plants:` with a list.
  2. §2.2 budget topology: exactly 25 plants total; exactly 5 plants per category; exactly 1 restraint per category.
  3. plant_id values are unique.
  4. category in the V7 MVP enum; synthesis in {none, full, hybrid}; generic_kind in {function, struct} when present.
  5. For each non-planted source_file basename (filename NOT starting with `_Plant_`), assert the path appears in
     either the type-catalog or function-catalog (matched against the catalog's `file` field, which is the relative
     path from the substrate root). This is the path-existence check that would have caught the 4 wrong paths in
     the first draft of the manifest reviewed in PR #21.
  6. For synthesis == hybrid or full, `planted_extras` must equal the count of `_Plant_*` paths under
     source_files. Catches drift between the field and the underlying file list.
  7. Restraint entries (restraint: true) must declare restraint_pair and restraint_signal.
  8. Unknown field warning: per-plant keys outside the documented schema produce warnings (not errors) so typos
     like `restraintpair` surface without blocking schema evolution.
  9. Rubric schema (Phase A.3, per methodology §8 + companion plant-manifest doc):
     a. expected_substrate_signals is a non-empty list of strings.
     b. primary_answer.category ∈ CATEGORIES ∪ {"no-action"}.
     c. primary_answer.category == "no-action" iff restraint: true.
     d. primary_answer.specifics is a non-empty dict.
     e. primary_answer.rationale_must_cite is a non-empty list of strings.
     f. specifics_tolerance is a dict (may be empty if no tolerances apply).
     g. alternative_answers is a list (possibly empty); each entry has category ∈ CATEGORIES,
        weight ∈ [0.0, 1.0], note non-empty string.
     h. wrong_answers is a non-empty list; each entry has category ∈ CATEGORIES ∪ {"no-action"},
        note non-empty string.

Usage
-----
    python3 validate-manifest.py
    python3 validate-manifest.py --catalog-root /tmp/wxyc-ios-audit-planted

Exit code: 0 if all checks pass; 1 otherwise. Errors and warnings printed to stderr; a `OK n=<plant_count>`
summary prints to stdout on success. Warnings do not affect exit code.

Dependencies: PyYAML (stdlib `json` for the catalogs).
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

import yaml

CATEGORIES = {
    "extract-to-common",
    "protocol-inheritance",
    "default-implementation",
    "pat-introduction",
    "generic-parameterization",
}
SYNTHESIS_VALUES = {"none", "full", "hybrid"}
GENERIC_KINDS = {"function", "struct"}
PLANTED_PREFIX = "_Plant_"

# §2.2 budget topology
TOTAL_PLANTS = 25
PLANTS_PER_CATEGORY = 5
RESTRAINTS_PER_CATEGORY = 1

# Documented schema fields. Anything outside this set produces a warning, not an error,
# so the schema can evolve without breaking the validator.
KNOWN_KEYS = {
    "plant_id",
    "category",
    "source_type",
    "source_files",
    "synthesis",
    "planted_extras",
    "generic_kind",
    "cross_layer",
    "restraint",
    "restraint_pair",
    "restraint_signal",
    # Phase A.3 rubric fields
    "expected_substrate_signals",
    "primary_answer",
    "specifics_tolerance",
    "alternative_answers",
    "wrong_answers",
}

# Categories valid as a primary/alternative/wrong-answer recommendation. Mirrors the agent-prompt taxonomy
# in `docs/refactor-recommendation-experiment-agent-prompt.md` §2 restricted to V7 MVP scope. `no-action`
# is a permitted answer category but is NOT in CATEGORIES; it's a separate bucket because (a) it's only
# valid as primary for restraints, and (b) it's the universal wrong-answer for canonical plants. The
# `subclass-lift` and `composition` categories are out-of-MVP-scope plant categories but remain valid
# as wrong-answer / alternative recommendations the manifest may cite.
ANSWER_CATEGORIES = CATEGORIES | {"subclass-lift", "composition"}
NO_ACTION = "no-action"


def is_planted_path(path: str) -> bool:
    """Return True if the path's basename starts with `_Plant_` (V6 plant-file convention)."""
    return Path(path).name.startswith(PLANTED_PREFIX)


def load_catalog_files(catalog_root: Path) -> set[str]:
    """Return the union of `file` values from type-catalog.json and function-catalog.json."""
    files: set[str] = set()
    for name in ("type-catalog.json", "function-catalog.json"):
        path = catalog_root / name
        if not path.exists():
            print(f"warning: catalog file not found: {path}", file=sys.stderr)
            continue
        with path.open() as f:
            for entry in json.load(f):
                if isinstance(entry, dict) and (file_val := entry.get("file")):
                    files.add(file_val)
    return files


def _is_non_empty_string_list(value: object) -> bool:
    return isinstance(value, list) and len(value) > 0 and all(
        isinstance(item, str) and item != "" for item in value
    )


def validate_rubric(plant: dict, prefix: str, is_restraint: bool, errors: list[str]) -> None:
    """Per Phase A.3, validate the rubric-related fields of a plant entry (methodology §8)."""
    # 9a: expected_substrate_signals is a non-empty list of strings.
    signals = plant.get("expected_substrate_signals")
    if not _is_non_empty_string_list(signals):
        errors.append(
            f"{prefix}: expected_substrate_signals must be a non-empty list of strings"
        )

    # 9b–9e: primary_answer shape.
    primary = plant.get("primary_answer")
    if not isinstance(primary, dict):
        errors.append(f"{prefix}: primary_answer must be a dict")
    else:
        pri_cat = primary.get("category")
        valid_primary_cats = ANSWER_CATEGORIES | {NO_ACTION}
        if pri_cat not in valid_primary_cats:
            errors.append(
                f"{prefix}: primary_answer.category {pri_cat!r} not in {sorted(valid_primary_cats)}"
            )
        # 9c: no-action iff restraint
        if is_restraint and pri_cat != NO_ACTION:
            errors.append(
                f"{prefix}: restraint=true but primary_answer.category={pri_cat!r} (must be 'no-action')"
            )
        if (not is_restraint) and pri_cat == NO_ACTION:
            errors.append(
                f"{prefix}: primary_answer.category='no-action' but restraint is not true"
            )
        specifics = primary.get("specifics")
        if not isinstance(specifics, dict) or len(specifics) == 0:
            errors.append(f"{prefix}: primary_answer.specifics must be a non-empty dict")
        cites = primary.get("rationale_must_cite")
        if not _is_non_empty_string_list(cites):
            errors.append(
                f"{prefix}: primary_answer.rationale_must_cite must be a non-empty list of strings"
            )

    # 9f: specifics_tolerance is a dict (may be empty).
    tolerance = plant.get("specifics_tolerance")
    if not isinstance(tolerance, dict):
        errors.append(f"{prefix}: specifics_tolerance must be a dict (possibly empty)")

    # 9g: alternative_answers is a list; each entry has category ∈ ANSWER_CATEGORIES, weight ∈ [0,1],
    # note non-empty string.
    alts = plant.get("alternative_answers")
    if not isinstance(alts, list):
        errors.append(f"{prefix}: alternative_answers must be a list (possibly empty)")
    else:
        for idx, alt in enumerate(alts):
            tag = f"{prefix}: alternative_answers[{idx}]"
            if not isinstance(alt, dict):
                errors.append(f"{tag}: entry must be a dict")
                continue
            cat = alt.get("category")
            if cat not in ANSWER_CATEGORIES:
                errors.append(
                    f"{tag}: category {cat!r} not in {sorted(ANSWER_CATEGORIES)}"
                )
            weight = alt.get("weight")
            if not isinstance(weight, (int, float)) or isinstance(weight, bool):
                errors.append(f"{tag}: weight must be a number in [0.0, 1.0]")
            elif not (0.0 <= float(weight) <= 1.0):
                errors.append(f"{tag}: weight {weight!r} not in [0.0, 1.0]")
            note = alt.get("note")
            if not isinstance(note, str) or note.strip() == "":
                errors.append(f"{tag}: note must be a non-empty string")

    # 9h: wrong_answers is a non-empty list; each entry has category ∈ ANSWER_CATEGORIES ∪ {no-action},
    # note non-empty string.
    wrongs = plant.get("wrong_answers")
    if not isinstance(wrongs, list) or len(wrongs) == 0:
        errors.append(f"{prefix}: wrong_answers must be a non-empty list")
    else:
        valid_wrong_cats = ANSWER_CATEGORIES | {NO_ACTION}
        for idx, wrong in enumerate(wrongs):
            tag = f"{prefix}: wrong_answers[{idx}]"
            if not isinstance(wrong, dict):
                errors.append(f"{tag}: entry must be a dict")
                continue
            cat = wrong.get("category")
            if cat not in valid_wrong_cats:
                errors.append(
                    f"{tag}: category {cat!r} not in {sorted(valid_wrong_cats)}"
                )
            note = wrong.get("note")
            if not isinstance(note, str) or note.strip() == "":
                errors.append(f"{tag}: note must be a non-empty string")


def validate(manifest_path: Path, catalog_root: Path) -> int:
    errors: list[str] = []
    warnings: list[str] = []

    with manifest_path.open() as f:
        doc = yaml.safe_load(f)

    plants = doc.get("plants") if isinstance(doc, dict) else None
    if not isinstance(plants, list):
        print("error: manifest must have top-level `plants:` list", file=sys.stderr)
        return 1

    catalog_files = load_catalog_files(catalog_root)
    if not catalog_files:
        print(f"error: no catalog entries loaded from {catalog_root}", file=sys.stderr)
        return 1

    # §2.2 budget topology checks
    if len(plants) != TOTAL_PLANTS:
        errors.append(f"§2.2 budget: expected {TOTAL_PLANTS} plants, got {len(plants)}")
    by_category = Counter(p.get("category") for p in plants)
    restraints_by_category = Counter(
        p.get("category") for p in plants if p.get("restraint")
    )
    for cat in CATEGORIES:
        if by_category[cat] != PLANTS_PER_CATEGORY:
            errors.append(
                f"§2.2 budget: category {cat!r} has {by_category[cat]} plants, expected {PLANTS_PER_CATEGORY}"
            )
        if restraints_by_category[cat] != RESTRAINTS_PER_CATEGORY:
            errors.append(
                f"§2.2 budget: category {cat!r} has {restraints_by_category[cat]} restraints, "
                f"expected {RESTRAINTS_PER_CATEGORY}"
            )

    ids = [p.get("plant_id") for p in plants]
    duplicates = [pid for pid, count in Counter(ids).items() if count > 1]
    if duplicates:
        errors.append(f"duplicate plant_id values: {duplicates}")

    for i, plant in enumerate(plants):
        pid = plant.get("plant_id", f"<index {i}>")
        prefix = f"plant {pid}"

        unknown_keys = set(plant.keys()) - KNOWN_KEYS
        if unknown_keys:
            warnings.append(f"{prefix}: unknown field(s) {sorted(unknown_keys)} (typo? schema change?)")

        category = plant.get("category")
        if category not in CATEGORIES:
            errors.append(f"{prefix}: category {category!r} not in {sorted(CATEGORIES)}")

        synthesis = plant.get("synthesis")
        if synthesis not in SYNTHESIS_VALUES:
            errors.append(f"{prefix}: synthesis {synthesis!r} not in {sorted(SYNTHESIS_VALUES)}")

        if (gk := plant.get("generic_kind")) is not None and gk not in GENERIC_KINDS:
            errors.append(f"{prefix}: generic_kind {gk!r} not in {sorted(GENERIC_KINDS)}")

        source_files = plant.get("source_files") or []
        if not isinstance(source_files, list) or not source_files:
            errors.append(f"{prefix}: source_files must be a non-empty list")
            continue

        planted_count = 0
        for sf in source_files:
            if not isinstance(sf, str):
                errors.append(f"{prefix}: source_files entry {sf!r} is not a string")
                continue
            if is_planted_path(sf):
                planted_count += 1
                continue
            if sf not in catalog_files:
                errors.append(f"{prefix}: source_file {sf!r} not found in catalog (path-existence check)")

        declared_extras = plant.get("planted_extras", 0)
        if synthesis in {"full", "hybrid"} and declared_extras != planted_count:
            errors.append(
                f"{prefix}: planted_extras={declared_extras} but found {planted_count} `_Plant_*` paths"
            )
        if synthesis == "none" and planted_count != 0:
            errors.append(
                f"{prefix}: synthesis=none but {planted_count} `_Plant_*` paths present"
            )

        if plant.get("restraint"):
            if not plant.get("restraint_pair"):
                errors.append(f"{prefix}: restraint=true but restraint_pair missing")
            if not plant.get("restraint_signal"):
                errors.append(f"{prefix}: restraint=true but restraint_signal missing")

        # Phase A.3 rubric schema checks
        is_restraint = bool(plant.get("restraint"))
        validate_rubric(plant, prefix, is_restraint, errors)

    if warnings:
        print(f"{len(warnings)} warning(s):", file=sys.stderr)
        for w in warnings:
            print(f"  ! {w}", file=sys.stderr)

    if errors:
        print(f"FAIL: {len(errors)} error(s) in {manifest_path}", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(f"OK n={len(plants)} plants validated against catalog at {catalog_root}")
    return 0


def main() -> int:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--manifest",
        type=Path,
        default=here / "plant-manifest.yaml",
        help="Path to plant-manifest.yaml",
    )
    parser.add_argument(
        "--catalog-root",
        type=Path,
        default=Path("/tmp/wxyc-ios-audit-planted"),
        help="Directory containing type-catalog.json and function-catalog.json",
    )
    args = parser.parse_args()
    return validate(args.manifest, args.catalog_root)


if __name__ == "__main__":
    sys.exit(main())
