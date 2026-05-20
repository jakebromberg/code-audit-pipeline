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


if __name__ == "__main__":
    unittest.main()
