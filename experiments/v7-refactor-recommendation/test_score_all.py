#!/usr/bin/env python3
"""Tests for `score_all.py` — the Phase E PR-E3 bulk scoring runner.

Synthetic fixtures only; the real corpus lives under `trial-logs/parsed/` and
is too large for unit tests. The corpus run is exercised by the CLI smoke
tests in `CLISmokeTests.test_runs_on_synthetic_corpus`, which builds a tiny
in-tree fixture in a tempdir and confirms `score_all.py` produces non-empty
deterministic outputs end-to-end.
"""
from __future__ import annotations

import json
import subprocess
import sys
import textwrap
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import score_all  # noqa: E402


# ─── helpers ──────────────────────────────────────────────────────────────


def _plant(
    *,
    plant_id: str,
    category: str = "extract-to-common",
    restraint: bool = False,
    source_files: list[str] | None = None,
    primary_category: str | None = None,
    primary_specifics_required: list[str] | None = None,
    must_cite: list[str] | None = None,
    alternative_categories: list[str] | None = None,
    wrong_categories: list[str] | None = None,
) -> dict:
    """Build a synthetic plant entry."""
    primary_category = primary_category or ("no-action" if restraint else category)
    return {
        "plant_id": plant_id,
        "category": category,
        "restraint": restraint,
        "source_files": source_files or [f"Pkg/Sources/{plant_id}.swift"],
        "primary_answer": {
            "category": primary_category,
            "specifics": {},
            "rationale_must_cite": must_cite or [],
        },
        "alternative_answers": [{"category": c, "weight": 0.7} for c in (alternative_categories or [])],
        "wrong_answers": [{"category": c, "note": ""} for c in (wrong_categories or [])],
    }


def _rec(
    *,
    cluster_id: str,
    condition: str = "s2",
    trial: int = 1,
    query: str = "exact-duplicates",
    category: str = "no-action",
    specifics: dict | None = None,
    rationale: str = "",
    confidence: float | None = 0.8,
    parse_error: str | None = None,
) -> dict:
    """Build a synthetic parsed record matching parse_responses.py's schema."""
    return {
        "cluster_id": cluster_id,
        "condition": condition,
        "trial": trial,
        "query": query,
        "row_index": 0,
        "raw_response_path": f"raw/{condition}/trial{trial}/synthetic.json",
        "parsed": None if parse_error else {
            "category": category,
            "specifics": specifics or {},
            "rationale": rationale,
            "evidence_quote": None,
            "confidence": confidence,
        },
        "parse_error": parse_error,
        "extraction_notes": {"parser_version": "1.0"},
    }


# ─── bind_recs_to_plants ──────────────────────────────────────────────────


class BindRecsToPlantsTests(unittest.TestCase):
    def test_single_plant_substring_match(self):
        plant = _plant(plant_id="A", source_files=["Pkg/Sources/A.swift"])
        rec = _rec(cluster_id="exact-duplicates:Pkg/Sources/A.swift+Pkg/Sources/B.swift")
        bindings = score_all.bind_recs_to_plants([rec], [plant])
        self.assertEqual(bindings, [(rec, ["A"])])

    def test_no_match_returns_empty_plant_list(self):
        plant = _plant(plant_id="A", source_files=["Pkg/Sources/A.swift"])
        rec = _rec(cluster_id="exact-duplicates:Other/Sources/Z.swift")
        bindings = score_all.bind_recs_to_plants([rec], [plant])
        self.assertEqual(bindings, [(rec, [])])

    def test_multi_plant_match_returns_all(self):
        p1 = _plant(plant_id="A", source_files=["Pkg/Sources/A.swift"])
        p2 = _plant(plant_id="B", source_files=["Pkg/Sources/B.swift"])
        rec = _rec(cluster_id="exact-duplicates:Pkg/Sources/A.swift+Pkg/Sources/B.swift")
        bindings = score_all.bind_recs_to_plants([rec], [p1, p2])
        # plant_ids are sorted for determinism
        self.assertEqual(bindings[0][1], ["A", "B"])

    def test_parse_error_record_is_skipped(self):
        plant = _plant(plant_id="A", source_files=["Pkg/Sources/A.swift"])
        rec = _rec(cluster_id="exact-duplicates:Pkg/Sources/A.swift", parse_error="json-parse-error")
        bindings = score_all.bind_recs_to_plants([rec], [plant])
        # parse-error rows are returned but with an empty plant list AND flagged
        # in score_recommendations downstream — bind_recs_to_plants itself is
        # permissive (it doesn't decide what to do with parse errors).
        self.assertEqual(bindings, [(rec, ["A"])])


# ─── score_all (per-rec scoring) ──────────────────────────────────────────


class ScoreAllTests(unittest.TestCase):
    def setUp(self):
        # Minimal rubric pulled from the project's rubric.yaml shape.
        self.rubric = {
            "weak_rationale_policy": "auto-score-0.5",
            "specifics_schemas": {
                "extract-to-common": {"required": ["target_package", "type_name", "remove_from"]},
                "no-action": {"required": ["reason_class"]},
            },
            "adjacent_categories": [],
        }

    def test_primary_match_full_against_canonical_plant(self):
        plant = _plant(
            plant_id="1.1",
            category="extract-to-common",
            source_files=["Pkg/A.swift"],
            primary_category="extract-to-common",
            primary_specifics_required=["target_package", "type_name", "remove_from"],
            must_cite=["Foo"],
        )
        rec = _rec(
            cluster_id="exact-duplicates:Pkg/A.swift+Other/B.swift",
            category="extract-to-common",
            specifics={"target_package": "Shared/Core", "type_name": "Foo", "remove_from": ["Pkg/A.swift"]},
            rationale="Foo appears in both packages.",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(len(out["scored"]), 1)
        self.assertEqual(out["scored"][0]["plant_id"], "1.1")
        self.assertEqual(out["scored"][0]["score"], 1.0)
        self.assertEqual(out["scored"][0]["match"], "primary_match_full")

    def test_unplanted_rec_records_with_null_plant_id(self):
        plant = _plant(plant_id="A", source_files=["Pkg/A.swift"])
        rec = _rec(cluster_id="exact-duplicates:Other/Z.swift", category="no-action")
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(out["scored"], [])
        self.assertEqual(len(out["unmatched"]), 1)
        self.assertEqual(out["unmatched"][0]["cluster_id"], "exact-duplicates:Other/Z.swift")

    def test_parse_error_rec_is_in_parse_errors_bucket(self):
        plant = _plant(plant_id="A", source_files=["Pkg/A.swift"])
        rec = _rec(cluster_id="exact-duplicates:Pkg/A.swift", parse_error="json-parse-error")
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(out["scored"], [])
        self.assertEqual(out["unmatched"], [])
        self.assertEqual(len(out["parse_errors"]), 1)
        self.assertEqual(out["parse_errors"][0]["parse_error"], "json-parse-error")

    def test_panel_route_goes_to_panel_routing_bucket(self):
        plant = _plant(
            plant_id="3.1",
            category="default-implementation",
            source_files=["Pkg/A.swift"],
            primary_category="default-implementation",
        )
        rec = _rec(
            cluster_id="default-impl-candidates:Pkg/A.swift",
            category="other",
            specifics={"proposed_action": "Use a free function instead.", "why_no_category_fits": "Type-erased."},
            rationale="Free function is more honest.",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(len(out["scored"]), 1)
        self.assertEqual(out["scored"][0]["score"], score_all.PANEL_ROUTE)
        self.assertEqual(len(out["panel_routed"]), 1)
        self.assertTrue(out["panel_routed"][0]["rec_token"].startswith("pr-"))  # opaque token prefix

    def test_restraint_false_positive_scored_zero(self):
        plant = _plant(
            plant_id="1R",
            category="extract-to-common",
            restraint=True,
            source_files=["Pkg/R.swift"],
            primary_category="no-action",
        )
        rec = _rec(
            cluster_id="exact-duplicates:Pkg/R.swift",
            category="extract-to-common",
            specifics={"target_package": "Shared/Core", "type_name": "X", "remove_from": []},
            rationale="Extract this duplicate.",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(out["scored"][0]["score"], 0.0)
        self.assertEqual(out["scored"][0]["match"], "restraint_false_positive")


# ─── aggregate summary ────────────────────────────────────────────────────


class AggregateSummaryTests(unittest.TestCase):
    def setUp(self):
        self.plants = [
            _plant(plant_id="1.1", category="extract-to-common", source_files=["Pkg/A1.swift"]),
            _plant(plant_id="1.2", category="extract-to-common", source_files=["Pkg/A2.swift"]),
            _plant(plant_id="1R", category="extract-to-common", restraint=True, source_files=["Pkg/R.swift"], primary_category="no-action"),
        ]
        self.rubric = {
            "weak_rationale_policy": "auto-score-0.5",
            "specifics_schemas": {
                "extract-to-common": {"required": ["target_package", "type_name", "remove_from"]},
                "no-action": {"required": ["reason_class"]},
            },
            "adjacent_categories": [],
        }

    def _rec_primary(self, cluster_id, condition="s2", trial=1):
        return _rec(
            cluster_id=cluster_id,
            condition=condition,
            trial=trial,
            category="extract-to-common",
            specifics={"target_package": "Shared/Core", "type_name": "X", "remove_from": []},
            rationale="X appears in both.",
        )

    def test_per_plant_best_score_picks_max_across_recs(self):
        # Two recs match plant 1.1; one scores 1.0, the other scores 0.5.
        rec_full = self._rec_primary("exact-duplicates:Pkg/A1.swift+X")
        rec_weak = _rec(
            cluster_id="near-duplicates:Pkg/A1.swift+Y",
            category="extract-to-common",
            specifics={"target_package": "Shared/Core"},  # missing required keys
            rationale="X exists.",
        )
        out = score_all.score_recommendations([rec_full, rec_weak], self.plants, self.rubric)
        summary = score_all.aggregate_summary(out, self.plants)
        # Cell (s2, extract-to-common, trial=1) plant 1.1 should be 1.0
        cell = summary["per_plant_per_cell"]["s2"]["1"]["1.1"]
        self.assertEqual(cell["best_score"], 1.0)
        # And n_pairs == 2
        self.assertEqual(cell["n_pairs"], 2)

    def test_canonical_recall_excludes_restraint_plants(self):
        # Plant 1.1 scores 1.0; plant 1.2 has no rec (treated as missing → 0.0).
        rec = self._rec_primary("exact-duplicates:Pkg/A1.swift+X")
        out = score_all.score_recommendations([rec], self.plants, self.rubric)
        summary = score_all.aggregate_summary(out, self.plants)
        # Per (s2, extract-to-common, trial=1) canonical recall: (1.0 + 0.0) / 2 = 0.5
        cell = summary["per_category_per_cell"]["s2"]["1"]["extract-to-common"]
        self.assertAlmostEqual(cell["canonical_recall"], 0.5)
        self.assertEqual(cell["n_canonical_plants"], 2)

    def test_restraint_fpr_counts_action_recs(self):
        # rec recommends action against the restraint plant 1R
        rec_fp = self._rec_primary("exact-duplicates:Pkg/R.swift+X")
        out = score_all.score_recommendations([rec_fp], self.plants, self.rubric)
        summary = score_all.aggregate_summary(out, self.plants)
        cell = summary["per_category_per_cell"]["s2"]["1"]["extract-to-common"]
        self.assertEqual(cell["n_restraint_plants"], 1)
        self.assertEqual(cell["n_restraint_fp"], 1)
        self.assertAlmostEqual(cell["restraint_fpr"], 1.0)

    def test_headline_2d_point_combines_recall_and_fpr(self):
        # 1.1 scores 1.0, 1.2 has no rec (0.0), 1R has no action recs (FPR=0)
        rec = self._rec_primary("exact-duplicates:Pkg/A1.swift+X")
        out = score_all.score_recommendations([rec], self.plants, self.rubric)
        summary = score_all.aggregate_summary(out, self.plants)
        headline = summary["headline"]["s2"]
        # canonical recall = (1.0 + 0.0)/2 = 0.5; FPR = 0/1 = 0; 1-FPR = 1.0
        self.assertAlmostEqual(headline["canonical_recall"], 0.5)
        self.assertAlmostEqual(headline["one_minus_fpr"], 1.0)

    def test_panel_route_rate_recorded_per_condition(self):
        rec_panel = _rec(
            cluster_id="exact-duplicates:Pkg/A1.swift+X",
            category="other",
            specifics={"proposed_action": "x", "why_no_category_fits": "y"},
            rationale="other",
        )
        rec_scored = self._rec_primary("exact-duplicates:Pkg/A2.swift+X")
        out = score_all.score_recommendations([rec_panel, rec_scored], self.plants, self.rubric)
        summary = score_all.aggregate_summary(out, self.plants)
        # 1 of 2 planted recs went to panel
        rate = summary["panel_route_rate"]["s2"]
        self.assertAlmostEqual(rate["fraction"], 0.5)
        self.assertEqual(rate["n_panel"], 1)
        self.assertEqual(rate["n_planted"], 2)

    def test_panel_route_rate_preserved_after_promotion(self):
        """Regression: panel_route_rate measures the auto-scorer's punt rate,
        which must not collapse to zero after promote_panel_scores rewrites
        the PANEL_ROUTE sentinels in scored_doc["scored"]. The §14.3 ≤50%
        acceptance check depends on this surviving promotion.
        """
        with TemporaryDirectory() as td:
            rec_panel = _rec(
                cluster_id="exact-duplicates:Pkg/A1.swift+X",
                category="other",
                specifics={"proposed_action": "x", "why_no_category_fits": "y"},
                rationale="other",
            )
            rec_scored = self._rec_primary("exact-duplicates:Pkg/A2.swift+X")
            out = score_all.score_recommendations([rec_panel, rec_scored], self.plants, self.rubric)
            # Promote the lone panel-routed pair to a numeric score.
            token = out["panel_routed"][0]["rec_token"]
            scores_path = Path(td) / "panel-scores.jsonl"
            scores_path.write_text(json.dumps(
                {"rec_token": token, "reviewer": "r1", "score": 0.5}
            ) + "\n")
            score_all.promote_panel_scores(out, scores_path)
            summary = score_all.aggregate_summary(out, self.plants)
            rate = summary["panel_route_rate"]["s2"]
            # n_panel still 1 because the pair was originally panel-routed —
            # promotion doesn't rewrite the audit-trail count.
            self.assertEqual(rate["n_panel"], 1)
            self.assertAlmostEqual(rate["fraction"], 0.5)
            self.assertTrue(rate["passes_threshold"])


# ─── Fleiss κ ─────────────────────────────────────────────────────────────


class FleissKappaTests(unittest.TestCase):
    def test_perfect_agreement_kappa_one(self):
        # 3 raters, 4 items, all rate identically → κ = 1.0
        # ratings[i] = list of category counts for item i across raters
        ratings = [
            {"a": 3, "b": 0, "c": 0},
            {"a": 0, "b": 3, "c": 0},
            {"a": 0, "b": 0, "c": 3},
            {"a": 3, "b": 0, "c": 0},
        ]
        self.assertAlmostEqual(score_all.fleiss_kappa(ratings, m=3), 1.0)

    def test_no_agreement_handles_gracefully(self):
        # 3 raters split across 3 categories per item → near-zero κ
        ratings = [
            {"a": 1, "b": 1, "c": 1},
            {"a": 1, "b": 1, "c": 1},
        ]
        kappa = score_all.fleiss_kappa(ratings, m=3)
        # Disagreement → κ should be negative or near-zero
        self.assertLess(kappa, 0.5)

    def test_single_rater_raises_value_error(self):
        # m < 2 is undefined for Fleiss κ (P_i denominator m*(m-1) → 0 at m=1
        # and the metric has no meaning at m=0). The function must raise
        # rather than emit an undefined number.
        ratings = [{"a": 1, "b": 0}]
        with self.assertRaises(ValueError):
            score_all.fleiss_kappa(ratings, m=1)

    def test_known_reference_value(self):
        # Worked example from Fleiss 1971 (paraphrased): 10 items, 4 raters,
        # 3 categories. We use a small construction whose κ we can compute by
        # hand:
        #
        # 4 items, 3 raters, 2 categories. Item 1: 3/0; Item 2: 0/3; Item 3:
        # 2/1; Item 4: 1/2.
        # P_i = (sum(n_ij^2) - m) / (m * (m-1)) for m=3:
        #   item 1: (9+0 - 3)/(3*2) = 6/6 = 1.0
        #   item 2: (0+9 - 3)/(3*2) = 6/6 = 1.0
        #   item 3: (4+1 - 3)/(3*2) = 2/6 = 0.333…
        #   item 4: (1+4 - 3)/(3*2) = 2/6 = 0.333…
        # P_bar = (1 + 1 + 0.333 + 0.333) / 4 = 0.666…
        # p_a = (3+0+2+1)/(4*3) = 6/12 = 0.5; p_b = 0.5
        # P_e = 0.25 + 0.25 = 0.5
        # κ = (0.666 - 0.5) / (1 - 0.5) = 0.166/0.5 = 0.333…
        ratings = [
            {"a": 3, "b": 0},
            {"a": 0, "b": 3},
            {"a": 2, "b": 1},
            {"a": 1, "b": 2},
        ]
        kappa = score_all.fleiss_kappa(ratings, m=3)
        self.assertAlmostEqual(kappa, 1.0 / 3.0, places=4)


# ─── attach_panel_kappa (jsonl → summary integration) ────────────────────


class AttachPanelKappaTests(unittest.TestCase):
    def test_missing_file_emits_panel_pending_sentinel(self):
        summary = {}
        score_all.attach_panel_kappa(summary, Path("/nonexistent/path.jsonl"))
        block = summary["inter_rater"]
        self.assertIsNone(block["fleiss_kappa"])
        self.assertEqual(block["n_items"], 0)
        self.assertIsNone(block["n_raters"])
        self.assertIn("not present", block["note"])

    def test_three_reviewers_populates_kappa(self):
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores.jsonl"
            # 2 items × 3 reviewers, with split agreement on item 2.
            rows = [
                {"rec_token": "pr-aaaa", "reviewer": "alice", "score": 1.0},
                {"rec_token": "pr-aaaa", "reviewer": "bob",   "score": 1.0},
                {"rec_token": "pr-aaaa", "reviewer": "carol", "score": 1.0},
                {"rec_token": "pr-bbbb", "reviewer": "alice", "score": 0.5},
                {"rec_token": "pr-bbbb", "reviewer": "bob",   "score": 0.7},
                {"rec_token": "pr-bbbb", "reviewer": "carol", "score": 0.5},
            ]
            path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            summary = {}
            score_all.attach_panel_kappa(summary, path)
            block = summary["inter_rater"]
            self.assertIsNotNone(block["fleiss_kappa"])
            self.assertEqual(block["n_items"], 2)
            self.assertEqual(block["n_raters"], 3)
            # Score buckets are stringified for the dict keys
            self.assertIn("1.0", block["score_buckets"])

    def test_single_reviewer_emits_panel_pending_sentinel(self):
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores.jsonl"
            path.write_text(json.dumps(
                {"rec_token": "pr-aaaa", "reviewer": "alice", "score": 1.0}
            ) + "\n")
            summary = {}
            score_all.attach_panel_kappa(summary, path)
            block = summary["inter_rater"]
            self.assertIsNone(block["fleiss_kappa"])
            self.assertEqual(block["n_raters"], 1)
            self.assertIn("requires ≥2", block["note"])

    def test_empty_file_emits_panel_pending_sentinel(self):
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores.jsonl"
            path.write_text("")
            summary = {}
            score_all.attach_panel_kappa(summary, path)
            block = summary["inter_rater"]
            self.assertIsNone(block["fleiss_kappa"])
            self.assertEqual(block["n_items"], 0)


# ─── promote_panel_scores ─────────────────────────────────────────────────


def _scored_entry(
    *,
    cluster_id: str = "cluster-1",
    condition: str = "s1",
    trial: int = 1,
    plant_id: str = "1.1",
    score=None,
    match: str = "auto",
    notes: list[str] | None = None,
) -> dict:
    """Build a synthetic scored entry shaped like score_recommendations emits."""
    return {
        "cluster_id": cluster_id,
        "condition": condition,
        "trial": trial,
        "query": "exact-duplicates",
        "plant_id": plant_id,
        "plant_category": "extract-to-common",
        "plant_restraint": False,
        "rec_category": "other",
        "rec_confidence": 0.7,
        "score": score,
        "match": match,
        "notes": list(notes or []),
    }


def _token_for(scored_entry: dict) -> str:
    return score_all._opaque_token(*score_all._token_parts(
        scored_entry.get("cluster_id"),
        scored_entry.get("condition"),
        scored_entry.get("trial"),
        scored_entry.get("plant_id"),
    ))


class PromotePanelScoresTests(unittest.TestCase):
    def test_replaces_panel_route_with_single_reviewer_score(self):
        with TemporaryDirectory() as td:
            entry = _scored_entry(score=score_all.PANEL_ROUTE, match="other_routes_to_panel")
            token = _token_for(entry)
            doc = {"scored": [entry]}
            path = Path(td) / "panel-scores.jsonl"
            path.write_text(json.dumps(
                {"rec_token": token, "reviewer": "r1", "score": 0.3}
            ) + "\n")
            score_all.promote_panel_scores(doc, path)
            self.assertEqual(doc["scored"][0]["score"], 0.3)
            self.assertEqual(doc["scored"][0]["match"], "panel_promoted")
            self.assertTrue(any("panel_promoted_from_other_routes_to_panel" in n
                                for n in doc["scored"][0]["notes"]))

    def test_uses_median_across_multiple_reviewers(self):
        with TemporaryDirectory() as td:
            entry = _scored_entry(score=score_all.PANEL_ROUTE)
            token = _token_for(entry)
            doc = {"scored": [entry]}
            path = Path(td) / "panel-scores.jsonl"
            rows = [
                {"rec_token": token, "reviewer": "r1", "score": 0.0},
                {"rec_token": token, "reviewer": "r2", "score": 0.5},
                {"rec_token": token, "reviewer": "r3", "score": 1.0},
            ]
            path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            score_all.promote_panel_scores(doc, path)
            # Median of {0.0, 0.5, 1.0} is 0.5
            self.assertEqual(doc["scored"][0]["score"], 0.5)

    def test_even_count_reviewers_averages_middle_two(self):
        with TemporaryDirectory() as td:
            entry = _scored_entry(score=score_all.PANEL_ROUTE)
            token = _token_for(entry)
            doc = {"scored": [entry]}
            path = Path(td) / "panel-scores.jsonl"
            rows = [
                {"rec_token": token, "reviewer": "r1", "score": 0.3},
                {"rec_token": token, "reviewer": "r2", "score": 0.7},
            ]
            path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            score_all.promote_panel_scores(doc, path)
            # Median of {0.3, 0.7} averages to 0.5
            self.assertAlmostEqual(doc["scored"][0]["score"], 0.5)

    def test_panel_route_without_matching_token_stays_deferred(self):
        with TemporaryDirectory() as td:
            entry = _scored_entry(score=score_all.PANEL_ROUTE, match="other_routes_to_panel")
            doc = {"scored": [entry]}
            path = Path(td) / "panel-scores.jsonl"
            # A score for an unrelated token; the entry's token won't match.
            path.write_text(json.dumps(
                {"rec_token": "pr-unrelated", "reviewer": "r1", "score": 1.0}
            ) + "\n")
            score_all.promote_panel_scores(doc, path)
            self.assertEqual(doc["scored"][0]["score"], score_all.PANEL_ROUTE)
            self.assertEqual(doc["scored"][0]["match"], "other_routes_to_panel")

    def test_missing_panel_scores_file_is_no_op(self):
        entry = _scored_entry(score=score_all.PANEL_ROUTE)
        doc = {"scored": [entry]}
        score_all.promote_panel_scores(doc, Path("/nonexistent/path.jsonl"))
        self.assertEqual(doc["scored"][0]["score"], score_all.PANEL_ROUTE)

    def test_empty_panel_scores_file_is_no_op(self):
        with TemporaryDirectory() as td:
            entry = _scored_entry(score=score_all.PANEL_ROUTE)
            doc = {"scored": [entry]}
            path = Path(td) / "panel-scores.jsonl"
            path.write_text("")
            score_all.promote_panel_scores(doc, path)
            self.assertEqual(doc["scored"][0]["score"], score_all.PANEL_ROUTE)

    def test_numeric_entries_are_not_touched(self):
        with TemporaryDirectory() as td:
            numeric_entry = _scored_entry(score=0.7, match="primary_match_full")
            panel_entry = _scored_entry(
                plant_id="2.1", score=score_all.PANEL_ROUTE, match="other_routes_to_panel"
            )
            token = _token_for(panel_entry)
            doc = {"scored": [numeric_entry, panel_entry]}
            path = Path(td) / "panel-scores.jsonl"
            # Even if a panel score row collides with the numeric entry's token,
            # promote_panel_scores must only rewrite PANEL_ROUTE entries.
            numeric_token = _token_for(numeric_entry)
            rows = [
                {"rec_token": numeric_token, "reviewer": "r1", "score": 1.0},
                {"rec_token": token, "reviewer": "r1", "score": 0.3},
            ]
            path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            score_all.promote_panel_scores(doc, path)
            self.assertEqual(doc["scored"][0]["score"], 0.7)
            self.assertEqual(doc["scored"][0]["match"], "primary_match_full")
            self.assertEqual(doc["scored"][1]["score"], 0.3)
            self.assertEqual(doc["scored"][1]["match"], "panel_promoted")
            # Tighten: the appended note should record the exact reviewer count.
            self.assertIn(
                "panel_promoted_from_other_routes_to_panel_n_reviewers_1",
                doc["scored"][1]["notes"],
            )

    def test_string_score_in_panel_file_is_ignored(self):
        """Defensive: a panel-scores row whose `score` field is a string
        (reviewer wrote text instead of a number, or the bucket name leaked
        through) must not promote — the isinstance guard keeps the entry at
        PANEL_ROUTE so a later round can supply a real numeric score.
        """
        with TemporaryDirectory() as td:
            entry = _scored_entry(score=score_all.PANEL_ROUTE, match="other_routes_to_panel")
            token = _token_for(entry)
            doc = {"scored": [entry]}
            path = Path(td) / "panel-scores.jsonl"
            path.write_text(json.dumps(
                {"rec_token": token, "reviewer": "r1", "score": "0.3"}
            ) + "\n")
            score_all.promote_panel_scores(doc, path)
            self.assertEqual(doc["scored"][0]["score"], score_all.PANEL_ROUTE)
            self.assertEqual(doc["scored"][0]["match"], "other_routes_to_panel")

    def test_null_score_in_panel_file_is_ignored(self):
        """Defensive: a panel-scores row whose `score` field is JSON null
        (Python None — e.g. a reviewer left a row in-progress) must not
        promote.
        """
        with TemporaryDirectory() as td:
            entry = _scored_entry(score=score_all.PANEL_ROUTE, match="other_routes_to_panel")
            token = _token_for(entry)
            doc = {"scored": [entry]}
            path = Path(td) / "panel-scores.jsonl"
            path.write_text(json.dumps(
                {"rec_token": token, "reviewer": "r1", "score": None}
            ) + "\n")
            score_all.promote_panel_scores(doc, path)
            self.assertEqual(doc["scored"][0]["score"], score_all.PANEL_ROUTE)
            self.assertEqual(doc["scored"][0]["match"], "other_routes_to_panel")

    def test_bool_score_in_panel_file_is_ignored(self):
        """Defensive: Python's bool is a subclass of int, so a stray `True`
        would silently promote to score=1.0 (and `False` to 0.0 — arguably
        the worse failure mode since 0.0 is a valid bucket) without the
        bool-exclusion guard. Confirm the guard keeps both at PANEL_ROUTE.
        """
        for bool_value in (True, False):
            with self.subTest(bool_value=bool_value):
                with TemporaryDirectory() as td:
                    entry = _scored_entry(
                        score=score_all.PANEL_ROUTE, match="other_routes_to_panel"
                    )
                    token = _token_for(entry)
                    doc = {"scored": [entry]}
                    path = Path(td) / "panel-scores.jsonl"
                    path.write_text(json.dumps(
                        {"rec_token": token, "reviewer": "r1", "score": bool_value}
                    ) + "\n")
                    score_all.promote_panel_scores(doc, path)
                    self.assertEqual(doc["scored"][0]["score"], score_all.PANEL_ROUTE)

    def test_tokens_align_with_score_recommendations(self):
        """Integration: tokens produced by score_recommendations for panel-
        routed pairs must be recoverable from scored entries via the same
        _opaque_token call promote_panel_scores uses."""
        plants = [_plant(plant_id="1.1", source_files=["Pkg/A.swift"])]
        rubric = {
            "weak_rationale_policy": "auto-score-0.5",
            "specifics_schemas": {
                "other": {"required": ["proposed_action", "why_no_category_fits"]},
            },
            "adjacent_categories": [],
        }
        rec = _rec(
            cluster_id="exact-duplicates:Pkg/A.swift+X",
            condition="s2",
            trial=1,
            category="other",
            specifics={"proposed_action": "...", "why_no_category_fits": "..."},
            rationale="x",
        )
        out = score_all.score_recommendations([rec], plants, rubric)
        panel_tokens = [p["rec_token"] for p in out["panel_routed"]]
        self.assertEqual(len(panel_tokens), 1)
        # The corresponding scored entry must recompute the same token.
        panel_scored = [s for s in out["scored"] if s["score"] == score_all.PANEL_ROUTE]
        self.assertEqual(len(panel_scored), 1)
        recomputed = _token_for(panel_scored[0])
        self.assertEqual(recomputed, panel_tokens[0])

    def test_token_parts_normalize_none_to_empty_string(self):
        """The writer (score_recommendations) and the reader (promote_panel_
        scores) must agree on how to stringify a None/missing field. If they
        diverge, the promoter recomputes a token the writer never emitted and
        the panel-supplied score silently fails to promote. The shared
        `_token_parts` helper is the single point of truth — assert it
        normalizes None to the empty string, which matches how an empty
        identity field round-trips through JSON.
        """
        # Direct: None and missing-key both normalize to "".
        self.assertEqual(
            score_all._token_parts(None, None, None, None),
            ("", "", "", ""),
        )
        # Numbers (e.g. YAML-parsed trial ints, float plant_ids) stringify normally.
        self.assertEqual(
            score_all._token_parts("c", "s1", 1, "5.1"),
            ("c", "s1", "1", "5.1"),
        )
        # End-to-end: a hypothetical scored entry with all-None identity fields
        # still produces a token that round-trips through _token_for.
        entry_with_nones = {
            "cluster_id": None,
            "condition": None,
            "trial": None,
            "plant_id": None,
        }
        token_a = score_all._opaque_token(*score_all._token_parts(
            entry_with_nones["cluster_id"],
            entry_with_nones["condition"],
            entry_with_nones["trial"],
            entry_with_nones["plant_id"],
        ))
        token_b = _token_for(entry_with_nones)
        self.assertEqual(token_a, token_b)


# ─── determinism ──────────────────────────────────────────────────────────


class DeterminismTests(unittest.TestCase):
    def test_byte_identical_output_on_rerun(self):
        plants = [_plant(plant_id="1.1", source_files=["Pkg/A.swift"])]
        rubric = {
            "weak_rationale_policy": "auto-score-0.5",
            "specifics_schemas": {
                "extract-to-common": {"required": ["target_package", "type_name", "remove_from"]},
                "no-action": {"required": ["reason_class"]},
            },
            "adjacent_categories": [],
        }
        recs = [
            _rec(
                cluster_id="exact-duplicates:Pkg/A.swift+X",
                condition=cond,
                trial=t,
                category="extract-to-common",
                specifics={"target_package": "Shared/Core", "type_name": "X", "remove_from": []},
                rationale="X.",
            )
            for cond in ("s1", "s2") for t in (1, 2, 3)
        ]
        out_a = score_all.score_recommendations(recs, plants, rubric)
        out_b = score_all.score_recommendations(recs, plants, rubric)
        # JSON-serialized form must be byte-identical (lists sorted, dicts key-sorted)
        a = json.dumps(out_a, indent=2, sort_keys=True)
        b = json.dumps(out_b, indent=2, sort_keys=True)
        self.assertEqual(a, b)


# ─── CLI smoke ────────────────────────────────────────────────────────────


class CLISmokeTests(unittest.TestCase):
    def test_help_exits_zero(self):
        result = subprocess.run(
            [sys.executable, str(HERE / "score_all.py"), "--help"],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertIn("--parsed", result.stdout)
        self.assertIn("--manifest", result.stdout)
        self.assertIn("--rubric", result.stdout)

    def test_runs_on_synthetic_corpus(self):
        # Build a tiny in-tree fixture in a tempdir and confirm score_all.py
        # produces non-empty deterministic outputs.
        with TemporaryDirectory() as td:
            tdir = Path(td)
            # parsed-cache layout: parsed/<cond>/trial<n>/<name>.json
            parsed = tdir / "parsed"
            for cond in ("s1", "s2"):
                trial_dir = parsed / cond / "trial1"
                trial_dir.mkdir(parents=True)
                (trial_dir / "rec.json").write_text(json.dumps(_rec(
                    cluster_id=f"exact-duplicates:Pkg/A.swift+Other/B.swift",
                    condition=cond,
                    trial=1,
                    category="extract-to-common",
                    specifics={"target_package": "Shared/Core", "type_name": "X", "remove_from": ["Pkg/A.swift"]},
                    rationale="X.",
                )))
            manifest = tdir / "plant-manifest.yaml"
            manifest.write_text(textwrap.dedent("""
                plants:
                  - plant_id: A
                    category: extract-to-common
                    source_files: ["Pkg/A.swift"]
                    primary_answer:
                      category: extract-to-common
                      specifics: {}
                      rationale_must_cite: []
                    alternative_answers: []
                    wrong_answers: []
                    restraint: false
                """))
            rubric = tdir / "rubric.yaml"
            rubric.write_text(textwrap.dedent("""
                weak_rationale_policy: auto-score-0.5
                specifics_schemas:
                  extract-to-common:
                    required: [target_package, type_name, remove_from]
                  no-action:
                    required: [reason_class]
                adjacent_categories: []
                """))
            outdir = tdir / "out"
            outdir.mkdir()
            result = subprocess.run(
                [
                    sys.executable, str(HERE / "score_all.py"),
                    "--parsed", str(parsed),
                    "--manifest", str(manifest),
                    "--rubric", str(rubric),
                    "--auto-scores-out", str(outdir / "auto-scores.json"),
                    "--summary-out", str(outdir / "score-summary.json"),
                    "--panel-routing-out", str(outdir / "panel-routing.jsonl"),
                    # Override --panel-unblind-out and --panel-scores so the
                    # smoke test never reads from or writes to the production
                    # `analyses/` directory under this repo. Without these,
                    # the test clobbered `analyses/panel-unblind.json` with
                    # synthetic empty data and silently read whichever
                    # `analyses/panel-scores.jsonl` happened to be present.
                    "--panel-unblind-out", str(outdir / "panel-unblind.json"),
                    "--panel-scores", str(outdir / "panel-scores.jsonl"),
                ],
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            self.assertTrue((outdir / "auto-scores.json").exists())
            self.assertTrue((outdir / "score-summary.json").exists())
            self.assertTrue((outdir / "panel-routing.jsonl").exists())
            doc = json.loads((outdir / "auto-scores.json").read_text())
            self.assertEqual(len(doc["scored"]), 2)  # one per condition


if __name__ == "__main__":
    unittest.main()
