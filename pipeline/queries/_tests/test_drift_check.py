"""Unit tests for scripts/drift_check.py (V7 round-3 prompt-sensitivity drift check).

Covers the pure-function pieces — stratified sampler, three drift metrics,
disposition aggregator. Network calls and FS-dependent helpers are exercised
via the harness/api injectable transport in higher-level integration tests;
this file stays offline and self-contained.

Run from repo root:
  python3 pipeline/queries/_tests/test_drift_check.py
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import drift_check  # noqa: E402


def _make_rec(
    *, category: str, condition: str, trial: int, plant_id: str, cluster_id: str | None = None, score: float | str = 0.0
) -> dict:
    return {
        "plant_category": category,
        "condition": condition,
        "trial": trial,
        "plant_id": plant_id,
        "cluster_id": cluster_id or f"q:{plant_id}:{trial}",
        "score": score,
    }


def _synthetic_population(per_cell: int = 10) -> list[dict]:
    """Return a synthetic `scored` list with `per_cell` recs per (cat, cond)."""
    recs: list[dict] = []
    for cat in drift_check.PLANT_CATEGORIES:
        for cond in drift_check.CONDITIONS:
            for i in range(per_cell):
                recs.append(_make_rec(
                    category=cat, condition=cond,
                    trial=(i % 3) + 1,
                    plant_id=f"{cat[:3]}-{i:02d}",
                    cluster_id=f"q:{cat}:{cond}:{i:02d}",
                ))
    return recs


class TestStratifiedSample(unittest.TestCase):
    """Sampling determinism + stratum coverage."""

    def test_sample_returns_per_stratum_x_strata_recs(self):
        pop = _synthetic_population(per_cell=10)
        sample = drift_check.stratified_sample(pop)
        self.assertEqual(len(sample), drift_check.SAMPLE_SIZE)

    def test_sample_covers_every_stratum(self):
        pop = _synthetic_population(per_cell=10)
        sample = drift_check.stratified_sample(pop)
        strata = {(r["plant_category"], r["condition"]) for r in sample}
        expected = {(c, cond) for c in drift_check.PLANT_CATEGORIES for cond in drift_check.CONDITIONS}
        self.assertEqual(strata, expected)

    def test_each_stratum_has_exactly_per_stratum_recs(self):
        pop = _synthetic_population(per_cell=10)
        sample = drift_check.stratified_sample(pop)
        from collections import Counter
        cnt = Counter((r["plant_category"], r["condition"]) for r in sample)
        for k, v in cnt.items():
            self.assertEqual(v, drift_check.PER_STRATUM, f"stratum {k}: {v}")

    def test_same_seed_produces_identical_sample(self):
        pop = _synthetic_population(per_cell=10)
        a = drift_check.stratified_sample(pop, seed=42)
        b = drift_check.stratified_sample(pop, seed=42)
        self.assertEqual(
            [r["cluster_id"] for r in a],
            [r["cluster_id"] for r in b],
        )

    def test_different_seed_produces_different_sample(self):
        pop = _synthetic_population(per_cell=10)
        a = drift_check.stratified_sample(pop, seed=1)
        b = drift_check.stratified_sample(pop, seed=2)
        self.assertNotEqual(
            [r["cluster_id"] for r in a],
            [r["cluster_id"] for r in b],
        )

    def test_input_order_does_not_change_sample(self):
        """Shuffling the input population must not change the drawn sample;
        determinism comes from the per-stratum sort, not from input order."""
        import random as _random
        pop = _synthetic_population(per_cell=10)
        shuffled = list(pop)
        _random.Random(123).shuffle(shuffled)
        a = drift_check.stratified_sample(pop, seed=99)
        b = drift_check.stratified_sample(shuffled, seed=99)
        self.assertEqual(
            [r["cluster_id"] for r in a],
            [r["cluster_id"] for r in b],
        )

    def test_undersized_stratum_raises(self):
        """A stratum with fewer than per_stratum candidates should raise,
        not silently return a partial sample — the drift-check contract is
        30 recs or nothing."""
        pop = _synthetic_population(per_cell=2)
        with self.assertRaises(ValueError):
            drift_check.stratified_sample(pop, per_stratum=3)


class TestCategoryDisagreement(unittest.TestCase):

    def test_zero_disagreement_passes(self):
        round2 = [{"category": "default-implementation"}] * 30
        drift = [{"category": "default-implementation"}] * 30
        m = drift_check.category_disagreement(round2, drift)
        self.assertEqual(m["count"], 0)
        self.assertEqual(m["of_total"], 30)
        self.assertTrue(m["pass"])

    def test_threshold_boundary_pass(self):
        """6 of 30 disagreements is on the threshold — passes (≤ 6)."""
        round2 = [{"category": "x"}] * 30
        drift = ([{"category": "y"}] * 6) + ([{"category": "x"}] * 24)
        m = drift_check.category_disagreement(round2, drift)
        self.assertEqual(m["count"], 6)
        self.assertTrue(m["pass"])

    def test_threshold_boundary_fail(self):
        """7 of 30 disagreements is over threshold — fails."""
        round2 = [{"category": "x"}] * 30
        drift = ([{"category": "y"}] * 7) + ([{"category": "x"}] * 23)
        m = drift_check.category_disagreement(round2, drift)
        self.assertEqual(m["count"], 7)
        self.assertFalse(m["pass"])

    def test_none_recs_treated_as_no_category(self):
        round2 = [{"category": "x"}, None]
        drift = [None, {"category": "x"}]
        m = drift_check.category_disagreement(round2, drift)
        self.assertEqual(m["count"], 2)  # both disagree

    def test_length_mismatch_raises(self):
        with self.assertRaises(ValueError):
            drift_check.category_disagreement([{"category": "x"}], [])


class TestSpecificsKeyDrift(unittest.TestCase):

    def test_identical_keys_zero_drift(self):
        r = [{"specifics": {"a": 1, "b": 2}}] * 30
        d = [{"specifics": {"a": 9, "b": 9}}] * 30  # values differ but keys match
        m = drift_check.specifics_key_drift(r, d)
        self.assertEqual(m["avg_pct"], 0.0)
        self.assertTrue(m["pass"])

    def test_jaccard_symdiff_arithmetic(self):
        """{a,b,c} vs {a,d}: sym_diff = {b,c,d} (3), union = {a,b,c,d} (4) → 75%."""
        r = [{"specifics": {"a": 1, "b": 1, "c": 1}}]
        d = [{"specifics": {"a": 1, "d": 1}}]
        m = drift_check.specifics_key_drift(r, d)
        self.assertAlmostEqual(m["avg_pct"], 75.0)

    def test_threshold_boundary_pass(self):
        """30% avg drift is on the boundary — passes."""
        # 9 of 10 keys identical, 1 of 10 different keys (10% drift) × 30 = 10% avg
        r = [{"specifics": {f"k{i}": 1 for i in range(10)}} for _ in range(30)]
        d = []
        for _ in range(30):
            # Replace one key with a different one
            spec = {f"k{i}": 1 for i in range(9)}
            spec["new"] = 1
            d.append({"specifics": spec})
        m = drift_check.specifics_key_drift(r, d)
        # sym diff = {k9, new} (2), union = 11 → 18.18% per rec
        self.assertAlmostEqual(m["avg_pct"], (2 / 11) * 100.0, places=4)
        self.assertTrue(m["pass"])

    def test_empty_specifics_both_sides_zero_drift(self):
        m = drift_check.specifics_key_drift(
            [{"specifics": {}}], [{"specifics": {}}],
        )
        self.assertEqual(m["avg_pct"], 0.0)

    def test_one_side_empty_full_drift(self):
        m = drift_check.specifics_key_drift(
            [{"specifics": {"a": 1, "b": 2}}],
            [{"specifics": {}}],
        )
        self.assertEqual(m["avg_pct"], 100.0)

    def test_none_treated_as_empty(self):
        m = drift_check.specifics_key_drift([None], [None])
        self.assertEqual(m["avg_pct"], 0.0)


class TestPanelRouteDelta(unittest.TestCase):

    def test_zero_delta_passes(self):
        r = ["panel_route", "panel_route", 0.5, 1.0, 0.0]
        d = ["panel_route", "panel_route", 0.0, 1.0, 0.5]  # same panel count
        m = drift_check.panel_route_delta(r, d)
        self.assertEqual(m["delta_pp"], 0.0)
        self.assertTrue(m["pass"])

    def test_positive_delta_within_tolerance(self):
        # round-2: 5 of 30 panel; drift: 7 of 30 panel → delta = +6.67 pp
        r = (["panel_route"] * 5) + ([0.0] * 25)
        d = (["panel_route"] * 7) + ([0.0] * 23)
        m = drift_check.panel_route_delta(r, d)
        self.assertAlmostEqual(m["delta_pp"], (2 / 30) * 100.0)
        self.assertTrue(m["pass"])

    def test_negative_delta_within_tolerance(self):
        r = (["panel_route"] * 10) + ([0.0] * 20)
        d = (["panel_route"] * 8) + ([0.0] * 22)
        m = drift_check.panel_route_delta(r, d)
        self.assertAlmostEqual(m["delta_pp"], -(2 / 30) * 100.0)
        self.assertTrue(m["pass"])

    def test_threshold_boundary_pass(self):
        """+3 of 30 = +10pp, exactly on threshold (abs ≤ 10) → passes."""
        r = (["panel_route"] * 5) + ([0.0] * 25)
        d = (["panel_route"] * 8) + ([0.0] * 22)
        m = drift_check.panel_route_delta(r, d)
        self.assertAlmostEqual(m["delta_pp"], 10.0)
        self.assertTrue(m["pass"])

    def test_threshold_boundary_fail(self):
        """+4 of 30 = +13.33pp, over threshold → fails."""
        r = (["panel_route"] * 5) + ([0.0] * 25)
        d = (["panel_route"] * 9) + ([0.0] * 21)
        m = drift_check.panel_route_delta(r, d)
        self.assertGreater(m["delta_pp"], 10.0)
        self.assertFalse(m["pass"])


class TestDisposition(unittest.TestCase):

    def _pass(self): return {"pass": True}
    def _fail(self): return {"pass": False}

    def test_all_pass_proceeds(self):
        d = drift_check.decide_disposition(self._pass(), self._pass(), self._pass())
        self.assertTrue(d["all_pass"])
        self.assertEqual(d["decision"], "proceed")
        self.assertEqual(d["halt_reasons"], [])

    def test_any_fail_halts(self):
        d = drift_check.decide_disposition(self._fail(), self._pass(), self._pass())
        self.assertFalse(d["all_pass"])
        self.assertEqual(d["decision"], "halt")
        self.assertEqual(d["halt_reasons"], ["category_disagreement_exceeded"])

    def test_multiple_failures_listed(self):
        d = drift_check.decide_disposition(self._fail(), self._fail(), self._fail())
        self.assertEqual(
            sorted(d["halt_reasons"]),
            sorted([
                "category_disagreement_exceeded",
                "specifics_key_drift_exceeded",
                "panel_route_delta_exceeded",
            ]),
        )


class TestLoadClusterRow(unittest.TestCase):
    """`load_cluster_row` should find by cluster_id and raise on missing."""

    def setUp(self):
        import tempfile
        self.tmpdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tmpdir.name)
        (self.root / "clusters-s1").mkdir()
        path = self.root / "clusters-s1" / "test-query.jsonl"
        path.write_text(
            '{"cluster_id": "test-query:a", "members": [{"name": "A"}]}\n'
            '{"cluster_id": "test-query:b", "members": [{"name": "B"}]}\n'
            "\n"
            '{"cluster_id": "test-query:c", "members": [{"name": "C"}]}\n'
        )

    def tearDown(self):
        self.tmpdir.cleanup()

    def test_finds_by_cluster_id(self):
        row = drift_check.load_cluster_row("test-query:b", "test-query", "s1", self.root)
        self.assertEqual(row["members"][0]["name"], "B")

    def test_skips_blank_lines(self):
        row = drift_check.load_cluster_row("test-query:c", "test-query", "s1", self.root)
        self.assertEqual(row["members"][0]["name"], "C")

    def test_missing_cluster_id_raises_keyerror(self):
        with self.assertRaises(KeyError):
            drift_check.load_cluster_row("test-query:zzz", "test-query", "s1", self.root)


class TestStratifiedSampleAgainstRealCorpus(unittest.TestCase):
    """Smoke test against the actual auto-scores.json to confirm the strata
    have ≥ per_stratum candidates each. Skips if the file is absent (e.g.,
    in a fresh worktree before round-2 was run)."""

    def setUp(self):
        self.auto_scores = (
            REPO_ROOT / "experiments" / "v7-refactor-recommendation"
            / "analyses" / "auto-scores.json"
        )
        if not self.auto_scores.exists():
            self.skipTest("auto-scores.json absent")

    def test_real_corpus_yields_30_recs_with_pinned_seed(self):
        scored = drift_check.load_scored_records(self.auto_scores)
        sample = drift_check.stratified_sample(scored)
        self.assertEqual(len(sample), drift_check.SAMPLE_SIZE)
        # All 10 strata are represented exactly per_stratum times.
        from collections import Counter
        cnt = Counter((r["plant_category"], r["condition"]) for r in sample)
        for stratum, n in cnt.items():
            self.assertEqual(
                n, drift_check.PER_STRATUM,
                f"stratum {stratum} drew {n} recs; expected {drift_check.PER_STRATUM}",
            )


if __name__ == "__main__":
    unittest.main()
