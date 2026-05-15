#!/usr/bin/env python3
"""Unit tests for `analyses/substrate_helped.py` and `analyses/plant_recall_extended.py`.

Co-located with the other experiment-scoped tests (`test_parse_responses.py`,
`test_validator.py`) per Phase E plan §2.2.

Run:
    python3 experiments/v7-refactor-recommendation/test_analyses.py
"""
from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "analyses"))

import plant_recall_extended  # noqa: E402
import substrate_helped  # noqa: E402


# ─── synthetic-record helpers ─────────────────────────────────────────────


def _rec(
    *,
    query: str,
    condition: str,
    cluster_id: str = "stub:cluster",
    category: str = "no-action",
    confidence: float | None = 0.5,
    trial: int = 1,
    parse_error: str | None = None,
) -> dict:
    return {
        "cluster_id": cluster_id,
        "condition": condition,
        "trial": trial,
        "query": query,
        "row_index": 0,
        "raw_response_path": f"raw/{condition}/trial{trial}/stub.json",
        "parsed": None
        if parse_error
        else {
            "category": category,
            "specifics": {},
            "rationale": "synth",
            "evidence_quote": None,
            "confidence": confidence,
        },
        "parse_error": parse_error,
        "extraction_notes": {"parser_version": "1.0"},
    }


# ─── substrate_helped ─────────────────────────────────────────────────────


class CategoryDistributionTests(unittest.TestCase):
    def test_empty(self):
        self.assertEqual(substrate_helped.compute_category_distribution([]), {})

    def test_skips_parse_errors(self):
        recs = [
            _rec(query="q", condition="s1", category="extract-to-common"),
            _rec(query="q", condition="s1", parse_error="json-parse-error"),
        ]
        dist = substrate_helped.compute_category_distribution(recs)
        self.assertEqual(dist, {"extract-to-common": 1.0})

    def test_proportions_sum_to_one(self):
        recs = [
            _rec(query="q", condition="s1", category="no-action"),
            _rec(query="q", condition="s1", category="no-action"),
            _rec(query="q", condition="s1", category="extract-to-common"),
            _rec(query="q", condition="s1", category="extract-to-common"),
        ]
        dist = substrate_helped.compute_category_distribution(recs)
        self.assertEqual(dist, {"no-action": 0.5, "extract-to-common": 0.5})


class TotalVariationDistanceTests(unittest.TestCase):
    def test_identical_distributions(self):
        d = {"a": 0.5, "b": 0.5}
        self.assertEqual(substrate_helped.total_variation_distance(d, d), 0.0)

    def test_disjoint_distributions(self):
        a = {"x": 1.0}
        b = {"y": 1.0}
        self.assertEqual(substrate_helped.total_variation_distance(a, b), 1.0)

    def test_partial_overlap(self):
        a = {"no-action": 0.9, "extract-to-common": 0.1}
        b = {"no-action": 0.7, "extract-to-common": 0.3}
        # TVD = 0.5 * (|0.9-0.7| + |0.1-0.3|) = 0.5 * 0.4 = 0.2
        self.assertAlmostEqual(
            substrate_helped.total_variation_distance(a, b), 0.2, places=6
        )

    def test_handles_missing_keys(self):
        a = {"no-action": 0.5, "extract-to-common": 0.5}
        b = {"no-action": 0.5, "pat-introduction": 0.5}
        # TVD = 0.5 * (0 + 0.5 + 0.5) = 0.5
        self.assertAlmostEqual(
            substrate_helped.total_variation_distance(a, b), 0.5, places=6
        )


class SummarizeQueryTests(unittest.TestCase):
    def test_per_query_columns_present(self):
        s1 = [_rec(query="q", condition="s1", confidence=0.4) for _ in range(6)]
        s2 = [_rec(query="q", condition="s2", confidence=0.6) for _ in range(6)]
        row = substrate_helped.summarize_query("q", s1, s2)
        for col in (
            "query",
            "n_s1",
            "n_s2",
            "n_with_confidence_s1",
            "n_with_confidence_s2",
            "confidence_coverage_s1",
            "confidence_coverage_s2",
            "mean_confidence_s1",
            "mean_confidence_s2",
            "delta_confidence",
            "delta_significant",
            "category_dist_s1",
            "category_dist_s2",
            "category_dist_distance",
            "primary_metric",
            "signature_pass",
        ):
            self.assertIn(col, row, f"missing column {col}")

    def test_confidence_present_in_majority_uses_confidence_primary(self):
        s1 = [_rec(query="q", condition="s1", confidence=0.5) for _ in range(10)]
        s2 = [_rec(query="q", condition="s2", confidence=0.5) for _ in range(10)]
        row = substrate_helped.summarize_query("q", s1, s2)
        self.assertEqual(row["primary_metric"], "confidence-delta")

    def test_confidence_below_60pct_falls_back_to_category_dist(self):
        # 5/10 = 50% coverage on s1 → below threshold → category-distribution primary
        s1 = (
            [_rec(query="q", condition="s1", confidence=0.5) for _ in range(5)]
            + [_rec(query="q", condition="s1", confidence=None) for _ in range(5)]
        )
        s2 = [_rec(query="q", condition="s2", confidence=0.5) for _ in range(10)]
        row = substrate_helped.summarize_query("q", s1, s2)
        self.assertEqual(row["primary_metric"], "category-distribution")
        self.assertEqual(row["confidence_coverage_s1"], 0.5)

    def test_delta_significant_above_threshold(self):
        s1 = [_rec(query="q", condition="s1", confidence=0.30) for _ in range(20)]
        s2 = [_rec(query="q", condition="s2", confidence=0.40) for _ in range(20)]
        row = substrate_helped.summarize_query("q", s1, s2)
        self.assertAlmostEqual(row["delta_confidence"], 0.10, places=6)
        self.assertTrue(row["delta_significant"])
        self.assertTrue(row["signature_pass"])

    def test_delta_below_threshold_not_significant(self):
        s1 = [_rec(query="q", condition="s1", confidence=0.50) for _ in range(20)]
        s2 = [_rec(query="q", condition="s2", confidence=0.52) for _ in range(20)]
        row = substrate_helped.summarize_query("q", s1, s2)
        self.assertFalse(row["delta_significant"])
        # primary is confidence and delta is sub-threshold → signature fails
        self.assertFalse(row["signature_pass"])

    def test_category_dist_primary_uses_tvd_for_signature(self):
        # Force category-distribution primary by zero-ing confidence on s1.
        s1 = (
            [
                _rec(query="q", condition="s1", confidence=None, category="no-action")
                for _ in range(8)
            ]
            + [
                _rec(
                    query="q",
                    condition="s1",
                    confidence=None,
                    category="extract-to-common",
                )
                for _ in range(2)
            ]
        )
        s2 = (
            [
                _rec(query="q", condition="s2", confidence=0.5, category="no-action")
                for _ in range(2)
            ]
            + [
                _rec(
                    query="q",
                    condition="s2",
                    confidence=0.5,
                    category="extract-to-common",
                )
                for _ in range(8)
            ]
        )
        row = substrate_helped.summarize_query("q", s1, s2)
        self.assertEqual(row["primary_metric"], "category-distribution")
        # TVD = 0.5 * (|0.8-0.2| + |0.2-0.8|) = 0.6 → > 0.05 → signature passes
        self.assertGreater(row["category_dist_distance"], 0.05)
        self.assertTrue(row["signature_pass"])

    def test_parse_errors_excluded_from_counts(self):
        s1 = [
            _rec(query="q", condition="s1", confidence=0.5),
            _rec(query="q", condition="s1", parse_error="json-parse-error"),
        ]
        s2 = [_rec(query="q", condition="s2", confidence=0.5)]
        row = substrate_helped.summarize_query("q", s1, s2)
        self.assertEqual(row["n_s1"], 1)
        self.assertEqual(row["n_s2"], 1)


class SubstrateHelpedAnalyzeTests(unittest.TestCase):
    def _twelve_recs(self):
        recs = []
        # shared query "exact-duplicates", S1=3, S2=3, no delta
        for _ in range(3):
            recs.append(
                _rec(query="exact-duplicates", condition="s1", confidence=0.5)
            )
            recs.append(
                _rec(query="exact-duplicates", condition="s2", confidence=0.5)
            )
        # shared query "function-duplicates", S1=2 at 0.3, S2=2 at 0.6 (substrate helped)
        for _ in range(2):
            recs.append(
                _rec(query="function-duplicates", condition="s1", confidence=0.3)
            )
            recs.append(
                _rec(query="function-duplicates", condition="s2", confidence=0.6)
            )
        # V7-only query "pat-candidates", S2 only
        recs.append(_rec(query="pat-candidates", condition="s2", confidence=0.7))
        recs.append(_rec(query="pat-candidates", condition="s2", confidence=0.8))
        return recs

    def test_per_query_table_has_only_shared_queries(self):
        out = substrate_helped.analyze(self._twelve_recs())
        queries = {row["query"] for row in out["per_query"]}
        self.assertEqual(queries, {"exact-duplicates", "function-duplicates"})

    def test_v7_only_queries_reported_separately(self):
        out = substrate_helped.analyze(self._twelve_recs())
        self.assertIn("pat-candidates", out["v7_only_queries"])

    def test_aggregate_signature_records_pass_count(self):
        out = substrate_helped.analyze(self._twelve_recs())
        self.assertEqual(out["aggregate"]["n_shared_queries"], 2)
        # function-duplicates has 0.30 → 0.60 delta = 0.30, passes; exact-duplicates is flat, fails
        self.assertEqual(out["aggregate"]["n_passed"], 1)
        # majority threshold: 1 of 2 < 50% strict majority → aggregate fail
        self.assertFalse(out["aggregate"]["signature_pass"])

    def test_output_is_deterministic_byte_identical(self):
        out1 = json.dumps(substrate_helped.analyze(self._twelve_recs()), sort_keys=True)
        out2 = json.dumps(substrate_helped.analyze(self._twelve_recs()), sort_keys=True)
        self.assertEqual(out1, out2)


# ─── plant_recall_extended ────────────────────────────────────────────────


class ClusterIdFilesTests(unittest.TestCase):
    def test_extracts_swift_paths_from_cluster_id(self):
        cid = (
            "function-duplicates:app:iOS:WXYC/iOS/Foo.swift:17:Foo.body"
            "+app:iOS:WXYC/iOS/Bar.swift:17:Bar.body"
        )
        files = plant_recall_extended.cluster_id_files(cid)
        self.assertEqual(
            files,
            {"WXYC/iOS/Foo.swift", "WXYC/iOS/Bar.swift"},
        )

    def test_empty_string(self):
        self.assertEqual(plant_recall_extended.cluster_id_files(""), set())

    def test_non_swift_paths_ignored(self):
        cid = "some-query:no-paths-here"
        self.assertEqual(plant_recall_extended.cluster_id_files(cid), set())


class CategoryRecallTests(unittest.TestCase):
    def _plant(self, **overrides):
        base = {
            "plant_id": "1.1",
            "category": "extract-to-common",
            "source_files": [
                "WXYC/iOS/Foo.swift",
                "WXYC/iOS/Bar.swift",
            ],
            "expected_substrate_signals": ["exact-duplicates"],
            "primary_answer": {"category": "extract-to-common"},
            "restraint": False,
            "alternative_answers": [],
        }
        base.update(overrides)
        return base

    def test_primary_category_match_marks_surfaced(self):
        plant = self._plant()
        recs = [
            _rec(
                query="exact-duplicates",
                condition="s2",
                cluster_id="exact-duplicates:app:iOS:WXYC/iOS/Foo.swift:17:Foo+app:iOS:WXYC/iOS/Bar.swift:17:Bar",
                category="extract-to-common",
                trial=1,
            )
        ]
        result = plant_recall_extended.category_recall_for_plant(plant, recs)
        self.assertTrue(result["s2"]["surfaced"])
        self.assertEqual(len(result["s2"]["matches"]), 1)
        self.assertEqual(result["s2"]["matches"][0]["match"], "primary")

    def test_no_match_when_files_unrelated(self):
        plant = self._plant()
        recs = [
            _rec(
                query="exact-duplicates",
                condition="s2",
                cluster_id="exact-duplicates:app:iOS:WXYC/iOS/Other.swift:1:Other",
                category="extract-to-common",
            )
        ]
        result = plant_recall_extended.category_recall_for_plant(plant, recs)
        self.assertFalse(result["s2"]["surfaced"])

    def test_wrong_category_does_not_surface(self):
        plant = self._plant()
        recs = [
            _rec(
                query="exact-duplicates",
                condition="s2",
                cluster_id="exact-duplicates:app:iOS:WXYC/iOS/Foo.swift:17:Foo+app:iOS:WXYC/iOS/Bar.swift:17:Bar",
                category="no-action",
            )
        ]
        result = plant_recall_extended.category_recall_for_plant(plant, recs)
        self.assertFalse(result["s2"]["surfaced"])

    def test_alternative_category_recorded_but_not_primary_surfaced(self):
        plant = self._plant(
            alternative_answers=[
                {"category": "protocol-inheritance", "weight": 0.7, "note": "alt"}
            ]
        )
        recs = [
            _rec(
                query="exact-duplicates",
                condition="s2",
                cluster_id="exact-duplicates:app:iOS:WXYC/iOS/Foo.swift:17:Foo+app:iOS:WXYC/iOS/Bar.swift:17:Bar",
                category="protocol-inheritance",
            )
        ]
        result = plant_recall_extended.category_recall_for_plant(plant, recs)
        self.assertFalse(result["s2"]["surfaced"])  # primary criterion is strict
        self.assertEqual(len(result["s2"]["matches"]), 1)
        self.assertEqual(result["s2"]["matches"][0]["match"], "alternative")

    def test_separates_conditions(self):
        plant = self._plant()
        recs = [
            _rec(
                query="exact-duplicates",
                condition="s1",
                cluster_id="exact-duplicates:app:iOS:WXYC/iOS/Foo.swift:17:Foo+app:iOS:WXYC/iOS/Bar.swift:17:Bar",
                category="extract-to-common",
            ),
        ]
        result = plant_recall_extended.category_recall_for_plant(plant, recs)
        self.assertTrue(result["s1"]["surfaced"])
        self.assertFalse(result["s2"]["surfaced"])


class PlantRecallExtendedAnalyzeTests(unittest.TestCase):
    def _plants(self):
        return [
            {
                "plant_id": "1.1",
                "category": "extract-to-common",
                "source_files": ["WXYC/iOS/Foo.swift"],
                "primary_answer": {"category": "extract-to-common"},
                "restraint": False,
                "alternative_answers": [],
                "expected_substrate_signals": ["exact-duplicates"],
            },
            {
                "plant_id": "5.3",
                "category": "generic-parameterization",
                "source_files": ["WXYC/Shared/Generic.swift"],
                "primary_answer": {"category": "generic-parameterization"},
                "restraint": False,
                "alternative_answers": [],
                "expected_substrate_signals": ["generic-function-candidates"],
            },
        ]

    def test_plant_5_3_escalates_when_not_surfaced(self):
        plants = self._plants()
        # No recs touching Generic.swift → 5.3 not surfaced
        recs = [
            _rec(
                query="exact-duplicates",
                condition="s2",
                cluster_id="exact-duplicates:app:iOS:WXYC/iOS/Foo.swift:17:Foo",
                category="extract-to-common",
            )
        ]
        out = plant_recall_extended.analyze(plants=plants, parsed_records=recs)
        plant_5_3 = next(p for p in out["plants"] if p["plant_id"] == "5.3")
        self.assertFalse(plant_5_3["recall_by_category"]["s2"]["surfaced"])
        self.assertTrue(out["plant_5_3"]["escalation_flag"])
        self.assertEqual(
            out["plant_5_3"]["escalation_action"], "file-substrate-recall-followup"
        )

    def test_plant_5_3_no_escalation_when_surfaced(self):
        plants = self._plants()
        recs = [
            _rec(
                query="generic-function-candidates",
                condition="s2",
                cluster_id="generic-function-candidates:shared:WXYC/Shared/Generic.swift:10:foo",
                category="generic-parameterization",
            )
        ]
        out = plant_recall_extended.analyze(plants=plants, parsed_records=recs)
        self.assertFalse(out["plant_5_3"]["escalation_flag"])

    def test_aggregate_recall_counts(self):
        plants = self._plants()
        recs = [
            _rec(
                query="exact-duplicates",
                condition="s2",
                cluster_id="exact-duplicates:app:iOS:WXYC/iOS/Foo.swift:17:Foo",
                category="extract-to-common",
            )
        ]
        out = plant_recall_extended.analyze(plants=plants, parsed_records=recs)
        self.assertEqual(out["aggregate"]["s2"]["surfaced_by_category"], 1)
        self.assertEqual(out["aggregate"]["s1"]["surfaced_by_category"], 0)
        self.assertEqual(out["aggregate"]["n_plants"], 2)

    def test_output_is_deterministic_byte_identical(self):
        plants = self._plants()
        recs = [
            _rec(
                query="exact-duplicates",
                condition="s2",
                cluster_id="exact-duplicates:WXYC/iOS/Foo.swift",
                category="extract-to-common",
            )
        ]
        out1 = json.dumps(
            plant_recall_extended.analyze(plants=plants, parsed_records=recs),
            sort_keys=True,
        )
        out2 = json.dumps(
            plant_recall_extended.analyze(plants=plants, parsed_records=recs),
            sort_keys=True,
        )
        self.assertEqual(out1, out2)

    def test_imports_analyzer_helpers(self):
        # Phase E plan §2.1 mandates the analyzer.py helpers be imported as a library.
        self.assertTrue(hasattr(plant_recall_extended, "_analyzer"))
        self.assertTrue(hasattr(plant_recall_extended._analyzer, "plant_hits"))
        self.assertTrue(hasattr(plant_recall_extended._analyzer, "collect_file_paths"))


# ─── CLI smoke ────────────────────────────────────────────────────────────


class CLISmokeTests(unittest.TestCase):
    """End-to-end runs through main() entry points against tiny fixture trees.

    Verifies the scripts produce a non-empty JSON output to the requested path
    and exit zero. The per-function tests above check the math; these check
    the wiring.
    """

    def test_substrate_helped_cli_writes_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            parsed_dir = tmp_path / "parsed"
            # one shared query, one rec each
            for cond in ("s1", "s2"):
                d = parsed_dir / cond / "trial1"
                d.mkdir(parents=True)
                rec = _rec(query="exact-duplicates", condition=cond, confidence=0.5)
                (d / "stub.json").write_text(
                    json.dumps(rec, indent=2, sort_keys=True) + "\n"
                )
            out_path = tmp_path / "substrate-helped.json"
            rc = substrate_helped.main(
                ["--parsed", str(parsed_dir), "--output", str(out_path)]
            )
            self.assertEqual(rc, 0)
            self.assertTrue(out_path.exists())
            doc = json.loads(out_path.read_text())
            self.assertIn("per_query", doc)

    def test_plant_recall_extended_cli_writes_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            parsed_dir = tmp_path / "parsed"
            d = parsed_dir / "s2" / "trial1"
            d.mkdir(parents=True)
            rec = _rec(
                query="exact-duplicates",
                condition="s2",
                cluster_id="exact-duplicates:app:iOS:WXYC/iOS/Foo.swift:17:Foo",
                category="extract-to-common",
            )
            (d / "stub.json").write_text(
                json.dumps(rec, indent=2, sort_keys=True) + "\n"
            )
            manifest_path = tmp_path / "plant-manifest.yaml"
            manifest_path.write_text(
                "plants:\n"
                "  - plant_id: '1.1'\n"
                "    category: extract-to-common\n"
                "    source_files: ['WXYC/iOS/Foo.swift']\n"
                "    primary_answer: {category: extract-to-common}\n"
                "    restraint: false\n"
                "    expected_substrate_signals: [exact-duplicates]\n"
            )
            out_path = tmp_path / "plant-recall-extended.json"
            rc = plant_recall_extended.main(
                [
                    "--parsed",
                    str(parsed_dir),
                    "--manifest",
                    str(manifest_path),
                    "--output",
                    str(out_path),
                ]
            )
            self.assertEqual(rc, 0)
            self.assertTrue(out_path.exists())
            doc = json.loads(out_path.read_text())
            self.assertIn("plants", doc)


if __name__ == "__main__":
    unittest.main()
