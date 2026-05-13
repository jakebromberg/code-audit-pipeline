#!/usr/bin/env python3
"""Automated corruption-test runner for validate-manifest.py.

For each documented rule in validate-manifest.py's docstring (1–10), construct a
corrupted copy of the manifest that isolates exactly ONE schema violation, run
the validator against it, and assert:

  (a) exit code matches expectation (non-zero for errors; zero for rule 8 which
      surfaces typos as warnings only); and
  (b) the expected error-substring appears in stderr.

Also assert the clean (unmodified) manifest passes (exit 0).

Substring matches are intentionally loose — they pin the rule's key phrase (e.g.,
`expected_substrate_signals`, `reason_class`, `no-action`) rather than the full
error text, so minor wording tweaks don't break the test.

Usage
-----
    python3 experiments/v7-refactor-recommendation/test_validator.py

Exit code: 0 if every fixture fires the expected error (and clean manifest
passes); 1 if any fixture misses.

Dependencies: PyYAML, stdlib only — same surface as validate-manifest.py.
"""
from __future__ import annotations

import copy
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
VALIDATOR = HERE / "validate-manifest.py"
CLEAN_MANIFEST = HERE / "plant-manifest.yaml"
RUBRIC = HERE / "rubric.yaml"
DEFAULT_CATALOG_ROOT = Path("/tmp/wxyc-ios-audit-planted")

# ─── ANSI sugar for the pass/fail glyph (mirrors pipeline/queries/_tests style) ─
GREEN = "\033[32m"
RED = "\033[31m"
RESET = "\033[0m"
CHECK = f"{GREEN}✓{RESET}"
CROSS = f"{RED}✗{RESET}"


@dataclass
class Fixture:
    """One corruption fixture.

    Attributes
    ----------
    rule:
        Rule number from validate-manifest.py docstring (e.g., "9a", "10b").
    description:
        Short human-readable description (printed on success/failure).
    corrupt:
        Callable applied to a deep-copied parsed manifest dict; mutates it in
        place to introduce exactly one violation.
    expect_substr:
        Substring required in the validator's stderr to consider the fixture
        a pass.
    expect_zero_exit:
        If True, validator must exit 0 (used for rule 8 — warning-only).
        If False (default), validator must exit non-zero.
    """

    rule: str
    description: str
    corrupt: Callable[[dict], None]
    expect_substr: str
    expect_zero_exit: bool = False


# ─── Corruption helpers ────────────────────────────────────────────────────────


def _find_canonical(plants: list[dict]) -> dict:
    """Return the first non-restraint plant. Used by fixtures that need a
    plant they can mutate without tripping the restraint-specific checks."""
    for p in plants:
        if not p.get("restraint"):
            return p
    raise RuntimeError("no canonical plant found")


def _find_restraint(plants: list[dict]) -> dict:
    """Return the first restraint plant."""
    for p in plants:
        if p.get("restraint"):
            return p
    raise RuntimeError("no restraint plant found")


# ─── Rule 1: top-level shape ───────────────────────────────────────────────────


def corrupt_rule_1(doc: dict) -> None:
    """Replace top-level `plants:` with a non-list."""
    doc.pop("plants", None)
    doc["plants"] = "not a list"


# ─── Rule 2: §2.2 budget topology (three sub-violations, one fixture each) ────


def corrupt_rule_2_total(doc: dict) -> None:
    """Drop one plant — total count falls below 25."""
    doc["plants"].pop()


def corrupt_rule_2_per_category(doc: dict) -> None:
    """Re-category a canonical so one category has 6 plants and another has 4."""
    plants = doc["plants"]
    # Find a canonical extract-to-common and flip its category to protocol-inheritance.
    for p in plants:
        if p.get("category") == "extract-to-common" and not p.get("restraint"):
            p["category"] = "protocol-inheritance"
            return
    raise RuntimeError("no canonical extract-to-common plant to mutate")


def corrupt_rule_2_restraints(doc: dict) -> None:
    """Demote a restraint to non-restraint — category now has 0 restraints."""
    r = _find_restraint(doc["plants"])
    r["restraint"] = False
    # Keep restraint_pair/signal in place; that's a side-effect but doesn't
    # trip another error (those fields are only checked when restraint=true).


# ─── Rule 3: duplicate plant_id ────────────────────────────────────────────────


def corrupt_rule_3(doc: dict) -> None:
    """Make two plants share a plant_id."""
    plants = doc["plants"]
    plants[1]["plant_id"] = plants[0]["plant_id"]


# ─── Rule 4: enum violations (category, synthesis, generic_kind) ──────────────


def corrupt_rule_4_category(doc: dict) -> None:
    """Set a plant's category to an invalid value."""
    _find_canonical(doc["plants"])["category"] = "not-a-real-category"


def corrupt_rule_4_synthesis(doc: dict) -> None:
    """Set a plant's synthesis to an invalid value."""
    _find_canonical(doc["plants"])["synthesis"] = "partial"


def corrupt_rule_4_generic_kind(doc: dict) -> None:
    """Set generic_kind to an invalid value on a Cat. 5 plant."""
    for p in doc["plants"]:
        if p.get("category") == "generic-parameterization" and "generic_kind" in p:
            p["generic_kind"] = "enum"
            return
    # No existing generic_kind — set on first Cat. 5 plant.
    for p in doc["plants"]:
        if p.get("category") == "generic-parameterization":
            p["generic_kind"] = "enum"
            return
    raise RuntimeError("no Cat. 5 plant to mutate")


# ─── Rule 5: source_file path missing from catalog ─────────────────────────────


def corrupt_rule_5(doc: dict) -> None:
    """Add a non-`_Plant_*` source_file path that doesn't exist in the catalog."""
    p = _find_canonical(doc["plants"])
    p["source_files"] = list(p["source_files"]) + ["Shared/Fictional/NotReal.swift"]


# ─── Rule 6: planted_extras count mismatch ─────────────────────────────────────


def corrupt_rule_6(doc: dict) -> None:
    """Find a hybrid/full plant and corrupt its planted_extras count."""
    for p in doc["plants"]:
        if p.get("synthesis") in {"full", "hybrid"}:
            p["planted_extras"] = p.get("planted_extras", 0) + 99
            return
    # No hybrid/full plants — promote a `none` plant so we can mismatch it.
    p = _find_canonical(doc["plants"])
    p["synthesis"] = "full"
    p["planted_extras"] = 99  # but no _Plant_* paths in source_files


# ─── Rule 7: restraint requires restraint_pair + restraint_signal ─────────────


def corrupt_rule_7(doc: dict) -> None:
    """Strip restraint_pair from a restraint plant."""
    r = _find_restraint(doc["plants"])
    r.pop("restraint_pair", None)


# ─── Rule 8: unknown field warning (warning only — validator still exits 0) ──


def corrupt_rule_8(doc: dict) -> None:
    """Add a typo'd field to a plant — produces a warning, not an error."""
    _find_canonical(doc["plants"])["restraintpair"] = "1.1"  # typo of restraint_pair


# ─── Rule 9a: expected_substrate_signals must be non-empty list of strings ───


def corrupt_rule_9a(doc: dict) -> None:
    """Empty out expected_substrate_signals."""
    _find_canonical(doc["plants"])["expected_substrate_signals"] = []


# ─── Rule 9b: primary_answer.category must be in valid set ────────────────────


def corrupt_rule_9b(doc: dict) -> None:
    """Set primary_answer.category to a bogus value."""
    _find_canonical(doc["plants"])["primary_answer"]["category"] = "bogus-category"


# ─── Rule 9c: no-action iff restraint ──────────────────────────────────────────


def corrupt_rule_9c(doc: dict) -> None:
    """Make a canonical's primary_answer.category be 'no-action' (restraint-only).

    This corruption violates 9c but also trips 10 (specifics-keys mismatch)
    because the canonical's specifics don't match no-action's required keys.
    The expected_substr below targets 9c specifically; rule 10's error
    appears on a different line and doesn't affect our substring assertion.
    """
    p = _find_canonical(doc["plants"])
    p["primary_answer"]["category"] = "no-action"


# ─── Rule 9d: primary_answer.specifics must be non-empty dict ────────────────


def corrupt_rule_9d(doc: dict) -> None:
    """Empty out primary_answer.specifics."""
    _find_canonical(doc["plants"])["primary_answer"]["specifics"] = {}


# ─── Rule 9e: primary_answer.rationale_must_cite non-empty list of strings ───


def corrupt_rule_9e(doc: dict) -> None:
    """Empty out rationale_must_cite."""
    _find_canonical(doc["plants"])["primary_answer"]["rationale_must_cite"] = []


# ─── Rule 9f: specifics_tolerance must be a dict ──────────────────────────────


def corrupt_rule_9f(doc: dict) -> None:
    """Make specifics_tolerance a list instead of a dict."""
    _find_canonical(doc["plants"])["specifics_tolerance"] = ["not", "a", "dict"]


# ─── Rule 9g: alternative_answers entries — three violations, three fixtures ─


def corrupt_rule_9g_weight(doc: dict) -> None:
    """Push an alternative's weight above 1.0."""
    p = _find_canonical(doc["plants"])
    alts = p.get("alternative_answers") or []
    if not alts:
        # Synthesize one to corrupt.
        p["alternative_answers"] = [{"category": "extract-to-common", "weight": 1.5, "note": "x"}]
    else:
        alts[0]["weight"] = 1.5


def corrupt_rule_9g_non_dict(doc: dict) -> None:
    """Make an alternative entry a non-dict."""
    p = _find_canonical(doc["plants"])
    p["alternative_answers"] = ["just a string, not a dict"]


def corrupt_rule_9g_empty_note(doc: dict) -> None:
    """Empty out an alternative's note."""
    p = _find_canonical(doc["plants"])
    alts = p.get("alternative_answers") or []
    if not alts:
        p["alternative_answers"] = [{"category": "extract-to-common", "weight": 0.5, "note": ""}]
    else:
        alts[0]["note"] = ""


# ─── Rule 9h: wrong_answers — empty list, and invalid category ────────────────


def corrupt_rule_9h_empty(doc: dict) -> None:
    """Empty out wrong_answers (must be non-empty)."""
    _find_canonical(doc["plants"])["wrong_answers"] = []


def corrupt_rule_9h_bad_category(doc: dict) -> None:
    """Set a wrong_answers entry's category to something bogus."""
    p = _find_canonical(doc["plants"])
    p["wrong_answers"][0]["category"] = "bogus-wrong-category"


# ─── Rule 9i: convention enforcement (canonical needs no-action wrong) ───────


def corrupt_rule_9i_canonical(doc: dict) -> None:
    """Strip 'no-action' from a canonical's wrong_answers list."""
    p = _find_canonical(doc["plants"])
    p["wrong_answers"] = [w for w in p["wrong_answers"] if w.get("category") != "no-action"]
    if not p["wrong_answers"]:
        # Need at least one entry to avoid tripping 9h.
        p["wrong_answers"] = [
            {"category": "subclass-lift", "note": "filler to keep wrong_answers non-empty"}
        ]


def corrupt_rule_9i_restraint(doc: dict) -> None:
    """Strip the canonical's category from a restraint's wrong_answers list."""
    r = _find_restraint(doc["plants"])
    pair_id = r.get("restraint_pair")
    if not pair_id:
        raise RuntimeError("restraint missing restraint_pair")
    plants_by_id = {p.get("plant_id"): p for p in doc["plants"]}
    canonical_cat = plants_by_id[pair_id].get("category")
    r["wrong_answers"] = [w for w in r["wrong_answers"] if w.get("category") != canonical_cat]
    if not r["wrong_answers"]:
        r["wrong_answers"] = [
            {"category": "no-action", "note": "filler to keep wrong_answers non-empty"}
        ]


# ─── Rule 10: specifics-keys allowlist (missing, extra, bad reason_class) ────


def corrupt_rule_10a(doc: dict) -> None:
    """Remove a required specifics key from a canonical."""
    p = _find_canonical(doc["plants"])
    specifics = p["primary_answer"]["specifics"]
    # Drop the first key — whatever it is, it's required for the category.
    if specifics:
        first_key = next(iter(specifics))
        del specifics[first_key]


def corrupt_rule_10b(doc: dict) -> None:
    """Add an unknown specifics key (typo simulation)."""
    p = _find_canonical(doc["plants"])
    p["primary_answer"]["specifics"]["target_pkg"] = "bogus typo'd key"


def corrupt_rule_10c(doc: dict) -> None:
    """Set a restraint's specifics.reason_class to a value outside the enum."""
    r = _find_restraint(doc["plants"])
    r["primary_answer"]["specifics"]["reason_class"] = "fictional-reason"


# ─── Fixture registry (rule numbers track validate-manifest.py docstring) ────


FIXTURES: list[Fixture] = [
    Fixture("1", "top-level plants must be a list", corrupt_rule_1, "plants"),
    Fixture(
        "2 (total count)",
        "drop one plant — total != 25",
        corrupt_rule_2_total,
        "§2.2 budget",
    ),
    Fixture(
        "2 (per-category count)",
        "re-category a canonical so a category != 5 plants",
        corrupt_rule_2_per_category,
        "§2.2 budget",
    ),
    Fixture(
        "2 (restraint count)",
        "demote a restraint so a category has 0 restraints",
        corrupt_rule_2_restraints,
        "restraints",
    ),
    Fixture("3", "two plants share a plant_id", corrupt_rule_3, "duplicate plant_id"),
    Fixture("4 (category enum)", "invalid category enum", corrupt_rule_4_category, "category"),
    Fixture("4 (synthesis enum)", "invalid synthesis enum", corrupt_rule_4_synthesis, "synthesis"),
    Fixture(
        "4 (generic_kind enum)",
        "invalid generic_kind enum",
        corrupt_rule_4_generic_kind,
        "generic_kind",
    ),
    Fixture("5", "source_file path not in catalog", corrupt_rule_5, "path-existence"),
    Fixture("6", "planted_extras mismatches `_Plant_*` count", corrupt_rule_6, "planted_extras"),
    Fixture(
        "7",
        "restraint=true with no restraint_pair",
        corrupt_rule_7,
        "restraint_pair",
    ),
    Fixture(
        "8",
        "typo'd field surfaces as warning (validator still exits 0)",
        corrupt_rule_8,
        "restraintpair",
        expect_zero_exit=True,
    ),
    Fixture(
        "9a",
        "expected_substrate_signals empty",
        corrupt_rule_9a,
        "expected_substrate_signals",
    ),
    Fixture("9b", "primary_answer.category bogus", corrupt_rule_9b, "primary_answer.category"),
    Fixture(
        "9c",
        "canonical primary_answer.category = 'no-action'",
        corrupt_rule_9c,
        "no-action",
    ),
    Fixture("9d", "primary_answer.specifics empty", corrupt_rule_9d, "primary_answer.specifics"),
    Fixture(
        "9e",
        "rationale_must_cite empty",
        corrupt_rule_9e,
        "rationale_must_cite",
    ),
    Fixture("9f", "specifics_tolerance not a dict", corrupt_rule_9f, "specifics_tolerance"),
    Fixture("9g (weight)", "alternative weight out of [0,1]", corrupt_rule_9g_weight, "weight"),
    Fixture(
        "9g (non-dict entry)",
        "alternative entry is not a dict",
        corrupt_rule_9g_non_dict,
        "alternative_answers",
    ),
    Fixture(
        "9g (empty note)",
        "alternative note empty string",
        corrupt_rule_9g_empty_note,
        "note",
    ),
    Fixture("9h (empty list)", "wrong_answers empty list", corrupt_rule_9h_empty, "wrong_answers"),
    Fixture(
        "9h (bad category)",
        "wrong_answers entry category bogus",
        corrupt_rule_9h_bad_category,
        "wrong_answers",
    ),
    Fixture(
        "9i (canonical)",
        "canonical missing no-action in wrong_answers",
        corrupt_rule_9i_canonical,
        "no-action",
    ),
    Fixture(
        "9i (restraint)",
        "restraint missing canonical's category in wrong_answers",
        corrupt_rule_9i_restraint,
        "canonical's category",
    ),
    Fixture("10a", "specifics missing required key", corrupt_rule_10a, "missing required keys"),
    Fixture("10b", "specifics has unknown key (typo)", corrupt_rule_10b, "unknown keys"),
    Fixture("10c", "no-action reason_class outside enum", corrupt_rule_10c, "reason_class"),
]


def run_validator(manifest_path: Path) -> subprocess.CompletedProcess:
    """Invoke validate-manifest.py against a given manifest path."""
    return subprocess.run(
        [
            sys.executable,
            str(VALIDATOR),
            "--manifest",
            str(manifest_path),
            "--catalog-root",
            str(DEFAULT_CATALOG_ROOT),
            "--rubric",
            str(RUBRIC),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def write_corrupted_manifest(clean_doc: dict, corrupt: Callable[[dict], None], tmp_dir: Path) -> Path:
    """Deep-copy the clean doc, apply the corruption, write to tmp_dir, return path."""
    doc = copy.deepcopy(clean_doc)
    corrupt(doc)
    out = tmp_dir / "manifest.yaml"
    with out.open("w") as f:
        yaml.safe_dump(doc, f, sort_keys=False)
    return out


def main() -> int:
    if not CLEAN_MANIFEST.exists():
        print(f"error: clean manifest missing at {CLEAN_MANIFEST}", file=sys.stderr)
        return 1
    if not VALIDATOR.exists():
        print(f"error: validator missing at {VALIDATOR}", file=sys.stderr)
        return 1
    if not DEFAULT_CATALOG_ROOT.exists():
        print(
            f"error: catalog root missing at {DEFAULT_CATALOG_ROOT}; populate it before running",
            file=sys.stderr,
        )
        return 1

    with CLEAN_MANIFEST.open() as f:
        clean_doc = yaml.safe_load(f)

    passed = 0
    failed = 0

    # ─── Positive assertion: clean manifest passes ──────────────────────────
    print("=== positive control ===")
    result = run_validator(CLEAN_MANIFEST)
    if result.returncode == 0:
        print(f"  {CHECK} clean manifest passes (exit 0)")
        passed += 1
    else:
        print(f"  {CROSS} clean manifest FAILED unexpectedly")
        print(f"      stderr: {result.stderr}")
        failed += 1

    # ─── Corruption fixtures ────────────────────────────────────────────────
    print("\n=== corruption fixtures ===")
    with tempfile.TemporaryDirectory(prefix="validator-corruption-") as tmp_str:
        tmp_dir = Path(tmp_str)
        for fixture in FIXTURES:
            fixture_dir = tmp_dir / f"rule_{fixture.rule.replace(' ', '_').replace('(', '').replace(')', '')}"
            fixture_dir.mkdir(parents=True, exist_ok=True)
            try:
                manifest_path = write_corrupted_manifest(clean_doc, fixture.corrupt, fixture_dir)
            except Exception as exc:  # noqa: BLE001
                print(f"  {CROSS} rule {fixture.rule}: corruption helper crashed: {exc}")
                failed += 1
                continue

            result = run_validator(manifest_path)
            exit_ok = (result.returncode == 0) if fixture.expect_zero_exit else (result.returncode != 0)
            substr_ok = fixture.expect_substr in result.stderr

            if exit_ok and substr_ok:
                print(f"  {CHECK} rule {fixture.rule}: {fixture.description}")
                passed += 1
            else:
                print(f"  {CROSS} rule {fixture.rule}: {fixture.description}")
                if not exit_ok:
                    expected = "0" if fixture.expect_zero_exit else "non-zero"
                    print(f"      exit: got {result.returncode}, expected {expected}")
                if not substr_ok:
                    print(f"      expected substring: {fixture.expect_substr!r}")
                    print(f"      stderr (first 400 chars): {result.stderr[:400]!r}")
                # Also surface stdout when something looks off — helpful when
                # the validator exits 0 but we expected a failure.
                if result.stdout.strip():
                    print(f"      stdout: {result.stdout.strip()[:200]}")
                failed += 1

    # ─── Summary ────────────────────────────────────────────────────────────
    print("\n=== Results ===")
    print(f"Passed: {passed}")
    print(f"Failed: {failed}")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
