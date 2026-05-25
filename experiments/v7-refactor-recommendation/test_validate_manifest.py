#!/usr/bin/env python3
"""Unit tests for validate-manifest.py's helper functions.

The end-to-end corruption-fixture runner lives in `test_validator.py` (it
shells out to the script and asserts errors on perturbed manifests). This
file complements it with direct-call unit tests for helpers that benefit
from focused exercise — currently the round-2 `cluster_lens` check 11
machinery (#33).

Imported via importlib because `validate-manifest.py` has a hyphen in its
filename and is not directly importable as a Python module.
"""
from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
VALIDATOR_SCRIPT = HERE / "validate-manifest.py"


def _load_validator_module():
    spec = importlib.util.spec_from_file_location("validate_manifest", VALIDATOR_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load spec for {VALIDATOR_SCRIPT}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["validate_manifest"] = mod
    spec.loader.exec_module(mod)
    return mod


vm = _load_validator_module()


def _plant(
    plant_id: str,
    *,
    category: str = "extract-to-common",
    source_files: list[str] | None = None,
    expected_cluster_symbols: list[str] | None = None,
    cluster_lens: str | None = None,
) -> dict:
    """Minimal plant dict for sharing-group tests. Fields read by
    `_sharing_groups` (plant_id, category, source_files,
    expected_cluster_symbols) plus the field under test (`cluster_lens`).

    Default `category` is `extract-to-common`. Sharing-group tests that
    cover the cross-lens (different-category) condition pass distinct
    categories; same-category tests use the default for both plants.
    """
    plant: dict = {
        "plant_id": plant_id,
        "category": category,
        "source_files": source_files if source_files is not None else [f"{plant_id}.swift"],
        "expected_cluster_symbols": (
            expected_cluster_symbols
            if expected_cluster_symbols is not None
            else [plant_id]
        ),
    }
    if cluster_lens is not None:
        plant["cluster_lens"] = cluster_lens
    return plant


class SharingGroupsTests(unittest.TestCase):
    """Unit tests for `_sharing_groups` — the §3.4 heuristic for detecting
    cross-lens cluster-sharing among plants. A pair shares iff their
    source_files overlap AND their expected_cluster_symbols overlap (the
    §9 condition, encoded structurally without running the substrate)."""

    def test_singleton_plant_produces_no_group(self):
        plants = [_plant("A")]
        self.assertEqual(vm._sharing_groups(plants), [])

    def test_two_plants_with_no_overlap_produce_no_group(self):
        plants = [
            _plant("A", source_files=["a.swift"], expected_cluster_symbols=["sym-a"]),
            _plant("B", source_files=["b.swift"], expected_cluster_symbols=["sym-b"]),
        ]
        self.assertEqual(vm._sharing_groups(plants), [])

    def test_two_plants_overlap_on_both_dimensions_distinct_categories_group(self):
        plants = [
            _plant(
                "A",
                category="default-implementation",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
            _plant(
                "B",
                category="generic-parameterization",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
        ]
        groups = vm._sharing_groups(plants)
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0], {"A", "B"})

    def test_two_plants_overlap_on_both_dimensions_same_category_no_group(self):
        """Same-category cluster-sharing is outside the §9 cross-lens
        scope (e.g., Plants 2.3/2.4 both protocol-inheritance). The
        cluster_lens routing rule cannot disambiguate same-lens plants;
        the auto-scorer's existing per-plant independent scoring handles
        them correctly under the canonical rubric. Excluding them from
        sharing-groups keeps #33's scope tight."""
        plants = [
            _plant(
                "A",
                category="protocol-inheritance",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
            _plant(
                "B",
                category="protocol-inheritance",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
        ]
        self.assertEqual(vm._sharing_groups(plants), [])

    def test_source_files_overlap_symbols_disjoint_no_group(self):
        """The §9 heuristic requires BOTH overlaps. Source files shared but
        cluster symbols disjoint → no sharing-group (substrate's symbol
        gate at bind-time filters these plants apart anyway)."""
        plants = [
            _plant("A", source_files=["x.swift"], expected_cluster_symbols=["sym-a"]),
            _plant("B", source_files=["x.swift"], expected_cluster_symbols=["sym-b"]),
        ]
        self.assertEqual(vm._sharing_groups(plants), [])

    def test_symbols_overlap_source_files_disjoint_no_group(self):
        """Symmetric to the source-files-overlap-symbols-disjoint case."""
        plants = [
            _plant("A", source_files=["a.swift"], expected_cluster_symbols=["sym1"]),
            _plant("B", source_files=["b.swift"], expected_cluster_symbols=["sym1"]),
        ]
        self.assertEqual(vm._sharing_groups(plants), [])

    def test_transitive_chain_three_plants_one_group(self):
        """A ↔ B ↔ C via union-find: all three end up in one group even
        though A and C don't pairwise overlap. Tests the transitive closure.
        Each pairwise edge must cross categories — A/B differ, B/C differ."""
        plants = [
            _plant(
                "A",
                category="default-implementation",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
            _plant(
                "B",
                category="generic-parameterization",
                source_files=["x.swift", "y.swift"],
                expected_cluster_symbols=["sym1", "sym2"],
            ),
            _plant(
                "C",
                category="pat-introduction",
                source_files=["y.swift"],
                expected_cluster_symbols=["sym2"],
            ),
        ]
        groups = vm._sharing_groups(plants)
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0], {"A", "B", "C"})

    def test_two_independent_groups(self):
        """Two distinct sharing-groups in one manifest. Validates that
        the algorithm doesn't accidentally collapse unrelated groups.
        Each pair has distinct categories (cross-lens)."""
        plants = [
            _plant(
                "A",
                category="default-implementation",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
            _plant(
                "B",
                category="generic-parameterization",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
            _plant(
                "C",
                category="extract-to-common",
                source_files=["y.swift"],
                expected_cluster_symbols=["sym2"],
            ),
            _plant(
                "D",
                category="pat-introduction",
                source_files=["y.swift"],
                expected_cluster_symbols=["sym2"],
            ),
        ]
        groups = vm._sharing_groups(plants)
        self.assertEqual(len(groups), 2)
        # Order-insensitive check via set-of-frozensets
        as_frozensets = {frozenset(g) for g in groups}
        self.assertEqual(
            as_frozensets,
            {frozenset({"A", "B"}), frozenset({"C", "D"})},
        )

    def test_singletons_elided_from_output(self):
        """A manifest with two sharing-group plants and one unrelated plant:
        the singleton is not reported as a group of size 1."""
        plants = [
            _plant(
                "A",
                category="default-implementation",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
            _plant(
                "B",
                category="generic-parameterization",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
            _plant(
                "C",
                category="extract-to-common",
                source_files=["z.swift"],
                expected_cluster_symbols=["sym-z"],
            ),
        ]
        groups = vm._sharing_groups(plants)
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0], {"A", "B"})


class ValidateClusterLensTests(unittest.TestCase):
    """Unit tests for the round-2 `cluster_lens` validator check (#33).
    Three branches under test: (11a) value enum, (11b) sharing-group
    presence, (11c) sharing-group uniqueness."""

    def test_singleton_no_lens_required(self):
        plants = [_plant("A")]
        errors: list[str] = []
        vm._validate_cluster_lens(plants, errors)
        self.assertEqual(errors, [])

    def test_sharing_group_with_distinct_lenses_passes(self):
        plants = [
            _plant(
                "A",
                category="default-implementation",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
                cluster_lens="default-implementation",
            ),
            _plant(
                "B",
                category="generic-parameterization",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
                cluster_lens="generic-parameterization",
            ),
        ]
        errors: list[str] = []
        vm._validate_cluster_lens(plants, errors)
        self.assertEqual(errors, [])

    def test_sharing_group_missing_lens_on_one_member_errors(self):
        plants = [
            _plant(
                "A",
                category="default-implementation",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
            _plant(
                "B",
                category="generic-parameterization",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
                cluster_lens="generic-parameterization",
            ),
        ]
        errors: list[str] = []
        vm._validate_cluster_lens(plants, errors)
        self.assertEqual(len(errors), 1)
        self.assertIn("cluster_lens", errors[0])
        self.assertIn("A", errors[0])

    def test_sharing_group_missing_lens_on_both_members_errors(self):
        plants = [
            _plant(
                "A",
                category="default-implementation",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
            _plant(
                "B",
                category="generic-parameterization",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
            ),
        ]
        errors: list[str] = []
        vm._validate_cluster_lens(plants, errors)
        self.assertEqual(len(errors), 2)
        self.assertTrue(all("cluster_lens" in e for e in errors))

    def test_sharing_group_duplicate_lens_errors(self):
        plants = [
            _plant(
                "A",
                category="default-implementation",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
                cluster_lens="default-implementation",
            ),
            _plant(
                "B",
                category="generic-parameterization",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
                cluster_lens="default-implementation",
            ),
        ]
        errors: list[str] = []
        vm._validate_cluster_lens(plants, errors)
        self.assertEqual(len(errors), 1)
        # Error message names the sharing group and the duplicate lens value.
        self.assertIn("distinct", errors[0])
        self.assertIn("default-implementation", errors[0])

    def test_invalid_lens_value_errors(self):
        plants = [
            _plant(
                "A",
                category="default-implementation",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
                cluster_lens="not-a-real-category",
            ),
            _plant(
                "B",
                category="generic-parameterization",
                source_files=["x.swift"],
                expected_cluster_symbols=["sym1"],
                cluster_lens="generic-parameterization",
            ),
        ]
        errors: list[str] = []
        vm._validate_cluster_lens(plants, errors)
        # Two errors expected: the invalid value AND the broken uniqueness
        # invariant doesn't fire because the invalid value still counts
        # as distinct from the other. Just check the invalid-value error
        # is present.
        self.assertTrue(any("not-a-real-category" in e for e in errors))

    def test_invalid_lens_value_on_singleton_still_errors(self):
        """The enum check (11a) fires on any plant that declares
        cluster_lens, not only sharing-group members. A singleton with a
        bogus value should still trip the validator — the field is
        optional on singletons but if declared, must be valid."""
        plants = [_plant("A", cluster_lens="not-a-real-category")]
        errors: list[str] = []
        vm._validate_cluster_lens(plants, errors)
        self.assertEqual(len(errors), 1)
        self.assertIn("not-a-real-category", errors[0])

    def test_lens_not_required_when_source_files_overlap_but_symbols_disjoint(self):
        """The heuristic edge case: plants share source_files but not
        symbols. No sharing-group → no cluster_lens required → no errors."""
        plants = [
            _plant("A", source_files=["x.swift"], expected_cluster_symbols=["sym-a"]),
            _plant("B", source_files=["x.swift"], expected_cluster_symbols=["sym-b"]),
        ]
        errors: list[str] = []
        vm._validate_cluster_lens(plants, errors)
        self.assertEqual(errors, [])

    def test_lens_not_required_when_symbols_overlap_but_source_files_disjoint(self):
        """Symmetric edge case: shared symbols, disjoint source_files."""
        plants = [
            _plant("A", source_files=["a.swift"], expected_cluster_symbols=["sym1"]),
            _plant("B", source_files=["b.swift"], expected_cluster_symbols=["sym1"]),
        ]
        errors: list[str] = []
        vm._validate_cluster_lens(plants, errors)
        self.assertEqual(errors, [])


def _plant_with_alternatives(
    plant_id: str,
    *,
    specifics: dict,
    alternatives: dict | None = None,
    rationale: dict | None = None,
) -> dict:
    """Minimal plant dict for `_validate_specifics_alternatives` unit tests."""
    primary: dict = {"specifics": specifics}
    if alternatives is not None:
        primary["specifics_alternatives"] = alternatives
    if rationale is not None:
        primary["specifics_alternatives_rationale"] = rationale
    return {
        "plant_id": plant_id,
        "primary_answer": primary,
    }


class SpecificsAlternativesValidatorTests(unittest.TestCase):
    """Unit tests for `_validate_specifics_alternatives`."""

    def test_absent_fields_pass(self):
        """Both fields are optional; an opted-out plant produces no errors."""
        plant = _plant_with_alternatives("A", specifics={"key1": "canonical-v1"})
        errors: list[str] = []
        vm._validate_specifics_alternatives(plant, "plant A", errors)
        self.assertEqual(errors, [])

    def test_validator_rejects_oversized_alternative_list(self):
        """Plan §3.2 cap: alternatives list per (plant, key) > 3 is hard-fail."""
        plant = _plant_with_alternatives(
            "A",
            specifics={"key1": "canonical-v1"},
            alternatives={"key1": ["alt-1", "alt-2", "alt-3", "alt-4"]},
            rationale={"key1": ["r1", "r2", "r3", "r4"]},
        )
        errors: list[str] = []
        vm._validate_specifics_alternatives(plant, "plant A", errors)
        self.assertTrue(
            any("exceeds cap of 3" in e for e in errors),
            f"expected cap-exceeded error, got {errors!r}",
        )

    def test_validator_rejects_canonical_duplicate_in_alternatives(self):
        """An alternative that equals the canonical value is hard-fail — the
        primary-match path already scores verbatim matches; duplicating inflates
        alternative-usage telemetry without changing scoring."""
        plant = _plant_with_alternatives(
            "B",
            specifics={"protocol": "BlendMode"},
            alternatives={"protocol": ["BlendMode"]},
            rationale={"protocol": ["this duplicates the canonical and should fail"]},
        )
        errors: list[str] = []
        vm._validate_specifics_alternatives(plant, "plant B", errors)
        self.assertTrue(
            any("duplicates the canonical" in e for e in errors),
            f"expected canonical-duplicate error, got {errors!r}",
        )

    def test_validator_rejects_rationale_length_mismatch(self):
        """Per-alternative rationale grounding: rationale list length must equal
        the corresponding alternatives list length."""
        plant = _plant_with_alternatives(
            "C",
            specifics={"key1": "canonical"},
            alternatives={"key1": ["alt-1", "alt-2"]},
            rationale={"key1": ["only-one-rationale"]},
        )
        errors: list[str] = []
        vm._validate_specifics_alternatives(plant, "plant C", errors)
        self.assertTrue(
            any("rationale list has 1 entries but alternatives list has 2" in e for e in errors),
            f"expected rationale-length mismatch error, got {errors!r}",
        )

    def test_validator_rejects_in_list_duplicate(self):
        """Duplicate entries within one key's alternatives list are rejected."""
        plant = _plant_with_alternatives(
            "D",
            specifics={"key1": "canonical"},
            alternatives={"key1": ["alt-a", "alt-a"]},
            rationale={"key1": ["r1", "r2"]},
        )
        errors: list[str] = []
        vm._validate_specifics_alternatives(plant, "plant D", errors)
        self.assertTrue(
            any("duplicated within the list" in e for e in errors),
            f"expected in-list duplicate error, got {errors!r}",
        )

    def test_validator_rejects_orphan_alternative_key(self):
        """Alternatives for a key not present in primary_answer.specifics are
        orphans — the auto-scorer never reaches the loosening path."""
        plant = _plant_with_alternatives(
            "E",
            specifics={"key1": "canonical"},
            alternatives={"missing_key": ["alt-1"]},
            rationale={"missing_key": ["r1"]},
        )
        errors: list[str] = []
        vm._validate_specifics_alternatives(plant, "plant E", errors)
        self.assertTrue(
            any("orphan alternative" in e for e in errors),
            f"expected orphan-key error, got {errors!r}",
        )

    def test_validator_rejects_non_list_value(self):
        """Each per-key value must be a list (not a scalar, not a dict)."""
        plant = _plant_with_alternatives(
            "F",
            specifics={"key1": "canonical"},
            alternatives={"key1": "not-a-list"},
            rationale={"key1": ["r1"]},
        )
        errors: list[str] = []
        vm._validate_specifics_alternatives(plant, "plant F", errors)
        self.assertTrue(
            any("must be a list of strings" in e for e in errors),
            f"expected non-list-value error, got {errors!r}",
        )

    def test_validator_rejects_rationale_without_alternatives(self):
        """Rationale declared standalone (no alternatives) is hard-fail — rationale must accompany alternatives."""
        plant = _plant_with_alternatives(
            "G",
            specifics={"key1": "canonical"},
            rationale={"key1": ["r1"]},
        )
        errors: list[str] = []
        vm._validate_specifics_alternatives(plant, "plant G", errors)
        self.assertTrue(
            any("rationale declared without specifics_alternatives" in e for e in errors),
            f"expected rationale-without-alts error, got {errors!r}",
        )

    def test_validator_accepts_well_formed_alternatives(self):
        """A correct shape produces no errors. Single alternative under cap, with
        a same-length rationale list and no canonical duplicate."""
        plant = _plant_with_alternatives(
            "H",
            specifics={"protocol": "BlendMode"},
            alternatives={"protocol": ["BlendModeProtocol", "Blendable"]},
            rationale={"protocol": [
                "adds the conventional Protocol suffix; same refactor under criterion (a)",
                "renames to verb-form Blendable; conformer set unchanged",
            ]},
        )
        errors: list[str] = []
        vm._validate_specifics_alternatives(plant, "plant H", errors)
        self.assertEqual(errors, [])

    def test_validator_rejects_empty_rationale_string(self):
        """Empty / whitespace-only rationale strings fail — each alternative needs grounded text."""
        plant = _plant_with_alternatives(
            "I",
            specifics={"key1": "canonical"},
            alternatives={"key1": ["alt-1"]},
            rationale={"key1": [""]},
        )
        errors: list[str] = []
        vm._validate_specifics_alternatives(plant, "plant I", errors)
        self.assertTrue(
            any("rationale entry must be non-empty" in e for e in errors),
            f"expected empty-rationale error, got {errors!r}",
        )


if __name__ == "__main__":
    unittest.main()
