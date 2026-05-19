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
    expected_substrate_signals: list[str] | None = None,
    expected_cluster_symbols: list[str] | None = None,
    primary_category: str | None = None,
    primary_specifics_required: list[str] | None = None,
    primary_specifics: dict | None = None,
    specifics_tolerance: dict | None = None,
    must_cite: list[str] | None = None,
    alternative_categories: list[str] | None = None,
    wrong_categories: list[str] | None = None,
) -> dict:
    """Build a synthetic plant entry.

    SYNC: when changing this helper's schema, also update the baseline-
    corruption pattern in test_validator.py so the two test suites continue
    to agree on what a well-formed plant looks like.

    `primary_specifics` populates `primary_answer.specifics`. If left as None,
    defaults to an empty dict — the value-comparison path in auto-scorer.py
    treats a missing manifest value as "manifest doesn't constrain this key,"
    so legacy tests that pre-date round-2 value-aware matching keep working
    without populating values. New tests exercising value-aware comparison
    should pass `primary_specifics` explicitly.
    """
    primary_category = primary_category or ("no-action" if restraint else category)
    # Default signals align with `_rec`'s default `query="exact-duplicates"` so
    # existing tests keep binding through the §3.4 signal-list gate. Use an
    # `is None` check rather than `or` so an explicit empty list is preserved
    # (the gate's defense-in-depth path tests this case).
    if expected_substrate_signals is None:
        expected_substrate_signals = ["exact-duplicates"]
    # Resolve source_files first so the default expected_cluster_symbols can
    # reference whichever path the plant actually owns.
    resolved_source_files = source_files or [f"Pkg/Sources/{plant_id}.swift"]
    # Default cluster symbols: use the first source_file path. Cluster_ids
    # constructed to substring-match source_files therefore also pass the
    # symbol gate, making most tests transparent to the round-2 symbol gate.
    # Tests that want to exercise the symbol-gate semantics override this
    # parameter explicitly. `is None` check preserves explicit empty lists
    # for defense-in-depth tests.
    if expected_cluster_symbols is None:
        expected_cluster_symbols = [resolved_source_files[0]]
    return {
        "plant_id": plant_id,
        "category": category,
        "restraint": restraint,
        "source_files": resolved_source_files,
        "expected_substrate_signals": expected_substrate_signals,
        "expected_cluster_symbols": expected_cluster_symbols,
        "primary_answer": {
            "category": primary_category,
            "specifics": primary_specifics if primary_specifics is not None else {},
            "rationale_must_cite": must_cite or [],
        },
        "specifics_tolerance": specifics_tolerance or {},
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
        # not in the parse_error business.
        self.assertEqual(bindings[0][1], ["A"])  # plant binding preserved on parse_error rec

    def test_signal_match_wins_when_plants_compete(self):
        # Motivating round-1 case: an HSBColor `pat-candidates` cluster
        # substring-matched BOTH Plant 3.1 (signals exclude pat-candidates) and
        # Plant 5.1 (signals include pat-candidates). Old logic bound to both.
        # New logic recognizes Plant 5.1's signal-match as a claim and binds
        # only there — Plant 3.1's spurious co-binding drops out.
        plant_31 = _plant(
            plant_id="3.1",
            source_files=["Shared/Color/Sources/Color/HSBColor.swift"],
            expected_substrate_signals=["function-duplicates", "default-impl-candidates"],
            expected_cluster_symbols=["HSBColor"],
        )
        plant_51 = _plant(
            plant_id="5.1",
            source_files=["Shared/Color/Sources/Color/HSBColor.swift"],
            expected_substrate_signals=["pat-candidates"],
            expected_cluster_symbols=["HSBColor"],
        )
        rec = _rec(
            cluster_id="pat-candidates:Shared/Color/Sources/Color/HSBColor.swift",
            query="pat-candidates",
        )
        bindings = score_all.bind_recs_to_plants([rec], [plant_31, plant_51])
        self.assertEqual(bindings, [(rec, ["5.1"])])

    def test_uncontested_substring_match_binds_even_without_signal(self):
        # The Plant 1R case: the cluster substring-matches only one plant, but
        # the rec's query isn't in that plant's signal list. The fallback
        # branch binds anyway — uncontested matches survive so the restraint
        # specificity signal isn't suppressed by binding logic.
        plant = _plant(
            plant_id="1R",
            source_files=["Shared/DebugPanel/Sources/DebugPanel/DebugHUD.swift"],
            expected_substrate_signals=["exact-duplicates", "cross-package-shape-near-duplicates-any"],
            expected_cluster_symbols=["MetricRow"],
        )
        rec = _rec(
            cluster_id="function-duplicates-exact:Shared/DebugPanel/Sources/DebugPanel/DebugHUD.swift:57:MetricRow.body+...",
            query="function-duplicates",
        )
        bindings = score_all.bind_recs_to_plants([rec], [plant])
        self.assertEqual(bindings, [(rec, ["1R"])])

    def test_signal_match_admits_when_only_one_plant(self):
        # Single plant whose signals include the rec's query — straightforward
        # case, signal_match populates and substring match alone would have
        # bound anyway. Pinning the no-regression behavior.
        plant = _plant(
            plant_id="3.1",
            source_files=["Shared/Color/Sources/Color/HSBColor.swift"],
            expected_substrate_signals=["function-duplicates", "default-impl-candidates"],
            expected_cluster_symbols=["HSBColor"],
        )
        rec = _rec(
            cluster_id="function-duplicates:Shared/Color/Sources/Color/HSBColor.swift",
            query="function-duplicates",
        )
        bindings = score_all.bind_recs_to_plants([rec], [plant])
        self.assertEqual(bindings, [(rec, ["3.1"])])

    def test_missing_rec_query_falls_back_to_substring(self):
        # Recs without a usable `query` field can't populate signal_matches,
        # so the fallback substring-match branch governs. Three input shapes
        # exercise the `rec.get("query") or ""` normalization: key missing,
        # explicit None, empty string.
        plant = _plant(
            plant_id="A",
            source_files=["Pkg/Sources/A.swift"],
            expected_substrate_signals=["function-duplicates"],
        )
        cluster_id = "exact-duplicates:Pkg/Sources/A.swift+Other/B.swift"
        cases: list[tuple[str, dict]] = [
            ("key-missing", {k: v for k, v in _rec(cluster_id=cluster_id).items() if k != "query"}),
            ("explicit-None", {**_rec(cluster_id=cluster_id), "query": None}),
            ("empty-string", {**_rec(cluster_id=cluster_id), "query": ""}),
        ]
        for case_name, rec in cases:
            with self.subTest(case=case_name):
                bindings = score_all.bind_recs_to_plants([rec], [plant])
                self.assertEqual(bindings, [(rec, ["A"])], msg=f"case={case_name}")

    def test_empty_signal_list_falls_back_to_substring(self):
        # Defense-in-depth: a plant with an empty expected_substrate_signals
        # list still binds via the substring fallback (signal_matches stays
        # empty so it's the fallback path). The manifest validator rejects
        # empty lists, so this is unreachable in production — but the
        # fallback semantic is pinned here in case the validator is bypassed.
        plant = _plant(
            plant_id="A",
            source_files=["Pkg/Sources/A.swift"],
            expected_substrate_signals=[],
        )
        rec = _rec(cluster_id="exact-duplicates:Pkg/Sources/A.swift", query="exact-duplicates")
        bindings = score_all.bind_recs_to_plants([rec], [plant])
        self.assertEqual(bindings, [(rec, ["A"])])

    # ─── Round-2 symbol gate (#86) ─────────────────────────────────────

    def test_symbol_gate_blocks_incidental_bindings(self):
        # Motivating Plant 1R case: cluster_id contains the plant's source
        # file (DebugHUD.swift) but none of the plant's expected_cluster_symbols
        # (MetricRow) — the cluster is about a different DebugHUD symbol
        # (DebugMetricsProvider.updateMetrics).  The incidental binding is
        # blocked by the symbol gate; rec goes to unmatched.
        plant = _plant(
            plant_id="1R",
            source_files=["Shared/DebugPanel/Sources/DebugPanel/DebugHUD.swift"],
            expected_cluster_symbols=["MetricRow"],
        )
        # Cluster_id includes Plant 1R's source file (substring matches) but
        # mentions a different symbol that's not in expected_cluster_symbols.
        rec = _rec(
            cluster_id="subset-pairs:DebugPanel:Shared/DebugPanel/Sources/DebugPanel/DebugHUD.swift:200:DebugMetricsProvider.updateMetrics+...",
            query="function-duplicates",
        )
        bindings = score_all.bind_recs_to_plants([rec], [plant])
        self.assertEqual(bindings, [(rec, [])])

    def test_symbol_gate_admits_legitimate_binding(self):
        # Same Plant 1R, but the cluster genuinely mentions MetricRow.
        plant = _plant(
            plant_id="1R",
            source_files=["Shared/DebugPanel/Sources/DebugPanel/DebugHUD.swift"],
            expected_cluster_symbols=["MetricRow"],
        )
        rec = _rec(
            cluster_id="exact-duplicates:MetricRow+MetricRow",
            query="exact-duplicates",
        )
        # Note: this cluster_id doesn't contain DebugHUD.swift, so substring
        # path match fails. The binding shouldn't fire even with symbol match.
        # We test the AND-gate by constructing a cluster_id with BOTH the
        # path and the symbol.
        rec_with_path = _rec(
            cluster_id="function-duplicates-exact:Shared/DebugPanel/Sources/DebugPanel/DebugHUD.swift:57:MetricRow.body+...",
            query="function-duplicates",
        )
        bindings = score_all.bind_recs_to_plants([rec_with_path], [plant])
        self.assertEqual(bindings, [(rec_with_path, ["1R"])])

    def test_symbol_disambiguates_shared_source_file(self):
        # Plant 3.1 vs 5.1: both have HSBColor.swift in source_files, both
        # list function-duplicates in signals. Pre-round-2 they'd both bind
        # to the same cluster. The symbol gate disambiguates: only the
        # plant whose symbol appears in cluster_id binds.
        plant_31 = _plant(
            plant_id="3.1",
            source_files=["Shared/ColorPalette/Sources/ColorPalette/HSBColor.swift"],
            expected_substrate_signals=["function-duplicates"],
            expected_cluster_symbols=["HSBColor.init", "AccentColor.init", "HSBOffset.init"],
        )
        plant_51 = _plant(
            plant_id="5.1",
            source_files=["Shared/ColorPalette/Sources/ColorPalette/HSBColor.swift"],
            expected_substrate_signals=["function-duplicates"],
            expected_cluster_symbols=["HSBColor.uiColor", "HSBColor.nsColor"],
        )
        # The panel-routed HSBColor cluster from round 1.
        rec = _rec(
            cluster_id="function-duplicates-near:Shared/ColorPalette/Sources/ColorPalette/HSBColor.swift:53:HSBColor.uiColor+Shared/ColorPalette/Sources/ColorPalette/HSBColor.swift:63:HSBColor.nsColor",
            query="function-duplicates",
        )
        bindings = score_all.bind_recs_to_plants([rec], [plant_31, plant_51])
        self.assertEqual(bindings, [(rec, ["5.1"])])

    def test_no_symbol_match_no_binding(self):
        # Cluster substring-matches a single plant's source_file but none of
        # the plant's symbols appear → no binding.
        plant = _plant(
            plant_id="A",
            source_files=["Pkg/Sources/A.swift"],
            expected_cluster_symbols=["VeryUniqueSymbol"],
        )
        rec = _rec(
            cluster_id="exact-duplicates:Pkg/Sources/A.swift+Other/B.swift",
            query="exact-duplicates",
        )
        bindings = score_all.bind_recs_to_plants([rec], [plant])
        self.assertEqual(bindings, [(rec, [])])

    def test_symbol_gate_with_empty_signals_falls_back_to_substring_when_symbol_matches(self):
        # Layered fallback: when expected_substrate_signals is empty (defense-
        # in-depth path) but expected_cluster_symbols matches, the binding
        # fires via the symbol_matches fallback inside the signal-prefer rule.
        plant = _plant(
            plant_id="A",
            source_files=["Pkg/Sources/A.swift"],
            expected_substrate_signals=[],
            expected_cluster_symbols=["A.swift"],
        )
        rec = _rec(
            cluster_id="exact-duplicates:Pkg/Sources/A.swift+...",
            query="exact-duplicates",
        )
        bindings = score_all.bind_recs_to_plants([rec], [plant])
        self.assertEqual(bindings, [(rec, ["A"])])

    def test_cross_lens_restraints_both_bind(self):
        # Cross-lens restraints (Plants 3R and 5R) share both source_files
        # and expected_cluster_symbols (both point at PlaylistStubs). The
        # symbol gate admits both plants — methodology §9 says both score
        # identically on any given rec, so cross-lens parity is preserved.
        shared_symbols = ["Breakpoint.stub", "Talkset.stub", "_Plant_PlaycutStub", "PlaylistStubs"]
        shared_signals = ["function-duplicates"]
        shared_source = "Shared/Playlist/Sources/PlaylistTesting/PlaylistStubs.swift"
        plant_3r = _plant(
            plant_id="3R",
            category="default-implementation",
            restraint=True,
            source_files=[shared_source],
            expected_substrate_signals=shared_signals,
            expected_cluster_symbols=shared_symbols,
        )
        plant_5r = _plant(
            plant_id="5R",
            category="generic-parameterization",
            restraint=True,
            source_files=[shared_source],
            expected_substrate_signals=shared_signals,
            expected_cluster_symbols=shared_symbols,
        )
        rec = _rec(
            cluster_id=f"function-duplicates-near:Playlist:{shared_source}:58:Breakpoint.stub+Playlist:{shared_source}:75:Talkset.stub",
            query="function-duplicates",
        )
        bindings = score_all.bind_recs_to_plants([rec], [plant_3r, plant_5r])
        self.assertEqual(bindings, [(rec, ["3R", "5R"])])

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


# ─── value-aware specifics matching (round 2, issue #35) ──────────────────


class ValueAwareSpecificsTests(unittest.TestCase):
    """Methodology §8 lines 626–631: outside-tolerance specifics route to panel,
    not auto-0.5. The auto-scorer's MVP key-only matching over-credited agents
    whose specifics aligned in shape but disagreed in content. Round 2 adds
    verbatim value comparison; mismatches route to panel with the manifest's
    `specifics_tolerance` flags surfaced as panel guidance notes.
    """

    def setUp(self):
        self.rubric = {
            "weak_rationale_policy": "auto-score-0.5",
            "specifics_schemas": {
                "extract-to-common": {"required": ["target_package", "type_name", "remove_from"]},
                "pat-introduction": {"required": ["new_protocol", "associated_type", "constraints", "replaces"]},
                "no-action": {"required": ["reason_class"]},
            },
            "adjacent_categories": [],
        }

    def _pat_plant(self, *, primary_specifics, specifics_tolerance=None):
        return _plant(
            plant_id="4.1",
            category="pat-introduction",
            source_files=["Pkg/Container.swift"],
            primary_category="pat-introduction",
            primary_specifics_required=["new_protocol", "associated_type", "constraints", "replaces"],
            primary_specifics=primary_specifics,
            specifics_tolerance=specifics_tolerance,
            must_cite=["TrackContainer", "ShowContainer"],
        )

    def test_primary_match_full_preserved_on_verbatim_value_match(self):
        """Plan §4 test #1: verbatim match still scores 1.0 (regression guard)."""
        plant = self._pat_plant(
            primary_specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            }
        )
        rec = _rec(
            cluster_id="pat-candidates:Pkg/Container.swift+TrackContainer",
            category="pat-introduction",
            specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            rationale="TrackContainer and ShowContainer differ at Item.",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(out["scored"][0]["score"], 1.0)
        self.assertEqual(out["scored"][0]["match"], "primary_match_full")

    def test_outside_tolerance_on_scalar_value_mismatch(self):
        """Plan §4 test #2: wrong scalar value → panel_route."""
        plant = self._pat_plant(
            primary_specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            }
        )
        rec = _rec(
            cluster_id="pat-candidates:Pkg/Container.swift+TrackContainer",
            category="pat-introduction",
            specifics={
                "new_protocol": "Wrong",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            rationale="TrackContainer and ShowContainer differ at Item.",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(out["scored"][0]["score"], score_all.PANEL_ROUTE)
        self.assertEqual(out["scored"][0]["match"], "primary_match_specifics_outside_tolerance")
        notes_blob = " ".join(out["scored"][0]["notes"])
        self.assertIn("new_protocol", notes_blob)
        self.assertIn("Container", notes_blob)
        self.assertIn("Wrong", notes_blob)

    def test_outside_tolerance_on_list_element_mismatch(self):
        """Plan §4 test #3: wrong list element → panel_route."""
        plant = self._pat_plant(
            primary_specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            }
        )
        rec = _rec(
            cluster_id="pat-candidates:Pkg/Container.swift+TrackContainer",
            category="pat-introduction",
            specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "Other"],
            },
            rationale="TrackContainer and ShowContainer differ at Item.",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(out["scored"][0]["score"], score_all.PANEL_ROUTE)
        self.assertEqual(out["scored"][0]["match"], "primary_match_specifics_outside_tolerance")

    def test_list_set_equality_treats_reversed_order_as_match(self):
        """Plan §4 test #4: list comparison is order-independent."""
        plant = self._pat_plant(
            primary_specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            }
        )
        rec = _rec(
            cluster_id="pat-candidates:Pkg/Container.swift+TrackContainer",
            category="pat-introduction",
            specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["ShowContainer", "TrackContainer"],  # reversed
            },
            rationale="TrackContainer and ShowContainer differ at Item.",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(out["scored"][0]["score"], 1.0)
        self.assertEqual(out["scored"][0]["match"], "primary_match_full")

    def test_missing_required_key_panel_routes(self):
        """Plan §4 test #5: missing required key → panel_route (was 0.5 in round 1)."""
        plant = self._pat_plant(
            primary_specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            }
        )
        rec = _rec(
            cluster_id="pat-candidates:Pkg/Container.swift+TrackContainer",
            category="pat-introduction",
            specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                # `replaces` deliberately omitted
            },
            rationale="TrackContainer and ShowContainer differ at Item.",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(out["scored"][0]["score"], score_all.PANEL_ROUTE)
        self.assertEqual(out["scored"][0]["match"], "primary_match_specifics_missing_keys")

    def test_tolerance_flag_notes_attached_to_scored_entry(self):
        """Plan §4 test #6 (scored view): scored entry carries the manifest's tolerance flags."""
        plant = self._pat_plant(
            primary_specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            specifics_tolerance={
                "associated_type_named_Item_or_synonym": True,
                "type_slot_at_item_must_be_identified": True,
            },
        )
        rec = _rec(
            cluster_id="pat-candidates:Pkg/Container.swift+TrackContainer",
            category="pat-introduction",
            specifics={
                "new_protocol": "Wrong",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            rationale="...",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        notes = out["scored"][0]["notes"]
        flag_notes = [n for n in notes if n.startswith("tolerance_flag:")]
        self.assertEqual(
            flag_notes,
            [
                "tolerance_flag: associated_type_named_Item_or_synonym=True",
                "tolerance_flag: type_slot_at_item_must_be_identified=True",
            ],
        )

    def test_tolerance_flag_notes_carried_into_panel_routed_view(self):
        """Regression: panel-routing.jsonl (built from `panel_routed`) must
        carry the same `notes` as the scored view. Reviewers reading
        `panel-routing.jsonl` per `panel-instructions.md` §3 case 2 rely on
        these notes to apply the manifest's tolerance flags during rating;
        if the notes are stripped from this view, the panel-routing artifact
        becomes opaque to reviewers despite carrying a `match_reason`.
        """
        plant = self._pat_plant(
            primary_specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            specifics_tolerance={
                "associated_type_named_Item_or_synonym": True,
                "type_slot_at_item_must_be_identified": True,
            },
        )
        rec = _rec(
            cluster_id="pat-candidates:Pkg/Container.swift+TrackContainer",
            category="pat-introduction",
            specifics={
                "new_protocol": "Wrong",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            rationale="...",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(len(out["panel_routed"]), 1)
        panel_notes = out["panel_routed"][0]["notes"]
        # The per-key mismatch description is present.
        self.assertTrue(any("new_protocol" in n and "Wrong" in n for n in panel_notes))
        # The plant's tolerance flags are present, sorted alphabetically.
        flag_notes = [n for n in panel_notes if n.startswith("tolerance_flag:")]
        self.assertEqual(
            flag_notes,
            [
                "tolerance_flag: associated_type_named_Item_or_synonym=True",
                "tolerance_flag: type_slot_at_item_must_be_identified=True",
            ],
        )

    def test_restraint_plants_unaffected_by_value_comparison(self):
        """Plan §4 test #7: restraint scoring is independent of the new path."""
        plant = _plant(
            plant_id="1R",
            category="extract-to-common",
            restraint=True,
            source_files=["Pkg/R.swift"],
            primary_category="no-action",
            primary_specifics={"reason_class": "sample-app-mirror"},
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

    def test_empty_tolerance_flag_dict_emits_no_flag_notes(self):
        """Plan §4 test #8: plant without tolerance flags → no flag notes in panel-routing."""
        plant = self._pat_plant(
            primary_specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            specifics_tolerance={},
        )
        rec = _rec(
            cluster_id="pat-candidates:Pkg/Container.swift+TrackContainer",
            category="pat-introduction",
            specifics={
                "new_protocol": "Wrong",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            rationale="...",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        flag_notes = [n for n in out["scored"][0]["notes"] if n.startswith("tolerance_flag:")]
        self.assertEqual(flag_notes, [])
        # But the mismatch note should still be present.
        self.assertTrue(any("new_protocol" in n for n in out["scored"][0]["notes"]))

    def test_type_mismatch_routes_to_panel(self):
        """Plan §4 test #9: list-vs-string type mismatch → panel_route."""
        plant = self._pat_plant(
            primary_specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            }
        )
        rec = _rec(
            cluster_id="pat-candidates:Pkg/Container.swift+TrackContainer",
            category="pat-introduction",
            specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": "TrackContainer",  # string where list expected
            },
            rationale="...",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(out["scored"][0]["score"], score_all.PANEL_ROUTE)
        self.assertEqual(out["scored"][0]["match"], "primary_match_specifics_outside_tolerance")

    def test_extras_in_specifics_still_tolerated(self):
        """Plan §4 test #10: superset-key semantics preserved; extras don't break value-match."""
        plant = self._pat_plant(
            primary_specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            }
        )
        rec = _rec(
            cluster_id="pat-candidates:Pkg/Container.swift+TrackContainer",
            category="pat-introduction",
            specifics={
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
                "notes": "extra commentary the scorer should ignore",
            },
            rationale="TrackContainer and ShowContainer differ at Item.",
        )
        out = score_all.score_recommendations([rec], [plant], self.rubric)
        self.assertEqual(out["scored"][0]["score"], 1.0)
        self.assertEqual(out["scored"][0]["match"], "primary_match_full")


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


def _routing_row(rec_token: str, plant_id: str, cluster_id: str,
                 condition: str = "s1", trial: int = 1) -> dict:
    """Build a synthetic panel-routing row matching the shape
    `score_recommendations` produces for `scored["panel_routed"]`.
    `attach_collapsed_panel_kappa` reads only `rec_token`, `plant_id`, and
    `unblind.cluster_id`; the rest of the fields are present for fidelity
    with the real shape so the fixture exercises the contract `main()` uses.
    """
    return {
        "rec_token": rec_token,
        "plant_id": plant_id,
        "plant_category": "default-implementation",
        "plant_restraint": False,
        "query": "function-duplicates",
        "rec_category": "other",
        "rec_specifics": {},
        "rec_rationale": "",
        "rec_evidence_quote": "",
        "rec_confidence": 0.5,
        "match_reason": "other_routes_to_panel",
        "unblind": {"cluster_id": cluster_id, "condition": condition, "trial": trial},
    }


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")


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

    def test_orphan_token_filtered_when_panel_routed_supplied(self):
        # Round-2 binding-artifact v2 (#86) regenerates panel-routing.jsonl
        # against the symbol gate. Round-1 panel-scores-reviewer-1.jsonl
        # still contains tokens for dropped (rec, plant) pairs. Those tokens
        # MUST be skipped, otherwise a Fleiss κ computed across m round-2
        # reviewers would silently mis-compute on orphan items (which only
        # have the round-1 reviewer's score and so don't sum to m).
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores.jsonl"
            rows = [
                # Two surviving tokens, fully covered by 2 reviewers.
                {"rec_token": "pr-survivor1", "reviewer": "alice", "score": 1.0},
                {"rec_token": "pr-survivor1", "reviewer": "bob",   "score": 1.0},
                {"rec_token": "pr-survivor2", "reviewer": "alice", "score": 0.5},
                {"rec_token": "pr-survivor2", "reviewer": "bob",   "score": 0.5},
                # Orphan token only has the round-1 reviewer's score; if
                # counted as an item, it'd have m=1 ratings against an
                # observed m=2, breaking the Fleiss precondition.
                {"rec_token": "pr-orphan", "reviewer": "alice", "score": 0.0},
            ]
            path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            panel_routed = [
                _routing_row("pr-survivor1", "5.1", "c1"),
                _routing_row("pr-survivor2", "5.1", "c2"),
            ]
            summary = {}
            score_all.attach_panel_kappa(summary, path, panel_routed)
            block = summary["inter_rater"]
            # Orphan dropped → 2 items, 2 raters. κ is computable.
            self.assertEqual(block["n_items"], 2)
            self.assertEqual(block["n_raters"], 2)
            self.assertIsNotNone(block["fleiss_kappa"])
            self.assertIn("1 orphan rec_token", block["note"])

    def test_orphan_skip_surfaces_in_panel_pending_note(self):
        # When the surviving rec_tokens are below the m≥2 threshold (only
        # one reviewer), the orphan count must still surface in the note —
        # methodology discipline says any data drop is reported.
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores.jsonl"
            rows = [
                {"rec_token": "pr-survivor", "reviewer": "alice", "score": 1.0},
                {"rec_token": "pr-orphan", "reviewer": "alice", "score": 0.0},
            ]
            path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            panel_routed = [_routing_row("pr-survivor", "5.1", "c1")]
            summary = {}
            score_all.attach_panel_kappa(summary, path, panel_routed)
            block = summary["inter_rater"]
            self.assertIsNone(block["fleiss_kappa"])
            self.assertEqual(block["n_items"], 1)
            self.assertEqual(block["n_raters"], 1)
            self.assertIn("requires ≥2", block["note"])
            self.assertIn("1 orphan rec_token", block["note"])

    def test_panel_routed_none_preserves_legacy_no_filter_behavior(self):
        # When `panel_routed` is None (default), no orphan-filtering happens
        # — preserves the legacy contract for callers that don't have the
        # in-memory list available (or want the unfiltered count).
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores.jsonl"
            rows = [
                {"rec_token": "pr-aaaa", "reviewer": "alice", "score": 1.0},
                {"rec_token": "pr-aaaa", "reviewer": "bob",   "score": 1.0},
                # Same shape that would be "orphan" if filtering were on.
                {"rec_token": "pr-orphan", "reviewer": "alice", "score": 0.0},
                {"rec_token": "pr-orphan", "reviewer": "bob",   "score": 0.0},
            ]
            path.write_text("\n".join(json.dumps(r) for r in rows) + "\n")
            summary = {}
            score_all.attach_panel_kappa(summary, path)  # no panel_routed arg
            block = summary["inter_rater"]
            # Both tokens kept → 2 items.
            self.assertEqual(block["n_items"], 2)
            self.assertEqual(block["n_raters"], 2)
            self.assertIsNotNone(block["fleiss_kappa"])
            self.assertIsNone(block.get("note"))


# ─── attach_collapsed_panel_kappa (judgment-level κ) ──────────────────────


class AttachCollapsedPanelKappaTests(unittest.TestCase):
    """Round-1's 12 panel-routed pairs are actually 2 distinct cluster-plant
    judgments duplicated across 3 trials × 2 conditions. inter_rater κ on
    12 items is inflated relative to κ on 2 distinct judgments. The
    `attach_collapsed_panel_kappa` function reduces each reviewer's set of
    scores per (plant_id, cluster_id) judgment to a median and computes κ
    over those reduced judgments.
    """

    def test_missing_panel_scores_emits_sentinel(self):
        panel_routed = [_routing_row("pr-aaaa", "1.1", "c1")]
        summary = {}
        score_all.attach_collapsed_panel_kappa(
            summary,
            Path("/nonexistent/scores.jsonl"),
            panel_routed,
        )
        block = summary["inter_rater_collapsed"]
        self.assertIsNone(block["fleiss_kappa"])
        self.assertEqual(block["n_judgments"], 0)
        self.assertIsNone(block["n_raters"])
        self.assertIn("not present", block["note"])

    def test_empty_panel_routed_emits_sentinel(self):
        with TemporaryDirectory() as td:
            scores = Path(td) / "panel-scores.jsonl"
            _write_jsonl(scores, [{"rec_token": "pr-aaaa", "reviewer": "alice", "score": 1.0}])
            summary = {}
            score_all.attach_collapsed_panel_kappa(summary, scores, [])
            block = summary["inter_rater_collapsed"]
            self.assertIsNone(block["fleiss_kappa"])
            self.assertEqual(block["n_judgments"], 0)
            self.assertIn("no panel-routed", block["note"])

    def test_single_reviewer_emits_sentinel(self):
        with TemporaryDirectory() as td:
            scores = Path(td) / "panel-scores.jsonl"
            panel_routed = [_routing_row("pr-aaaa", "1.1", "c1")]
            _write_jsonl(scores, [{"rec_token": "pr-aaaa", "reviewer": "alice", "score": 0.3}])
            summary = {}
            score_all.attach_collapsed_panel_kappa(summary, scores, panel_routed)
            block = summary["inter_rater_collapsed"]
            self.assertIsNone(block["fleiss_kappa"])
            self.assertEqual(block["n_raters"], 1)
            self.assertIn("requires ≥2", block["note"])

    def test_two_judgments_perfect_agreement(self):
        """Two reviewers, two judgments (plant 3.1 / plant 5.1 on the same
        HSBColor cluster), each reviewer gives identical score across the
        3 duplicates of each judgment, and both reviewers agree on each
        judgment's score → Fleiss κ ≈ 1.0.
        """
        with TemporaryDirectory() as td:
            scores = Path(td) / "panel-scores.jsonl"
            # 2 judgments × 3 duplicates = 6 rec_tokens
            panel_routed = []
            score_rows = []
            for plant_id, score in [("3.1", 0.0), ("5.1", 0.3)]:
                for trial in (1, 2, 3):
                    token = f"pr-{plant_id.replace('.', '')}t{trial}"
                    panel_routed.append(_routing_row(token, plant_id, "hsbcolor", trial=trial))
                    for reviewer in ("alice", "bob"):
                        score_rows.append({"rec_token": token, "reviewer": reviewer, "score": score})
            _write_jsonl(scores, score_rows)
            summary = {}
            score_all.attach_collapsed_panel_kappa(summary, scores, panel_routed)
            block = summary["inter_rater_collapsed"]
            self.assertEqual(block["n_judgments"], 2)
            self.assertEqual(block["n_raters"], 2)
            self.assertAlmostEqual(block["fleiss_kappa"], 1.0)
            self.assertEqual(block["within_reviewer_inconsistency_count"], 0)
            judgments = sorted(block["judgments"], key=lambda j: j["plant_id"])
            self.assertEqual(judgments[0]["plant_id"], "3.1")
            self.assertEqual(judgments[0]["reviewer_medians"]["alice"], 0.0)
            self.assertEqual(judgments[0]["reviewer_medians"]["bob"], 0.0)
            self.assertEqual(judgments[0]["n_duplicates_per_reviewer"]["alice"], 3)
            self.assertEqual(judgments[0]["n_duplicates_per_reviewer"]["bob"], 3)

    def test_two_judgments_disagreement_yields_low_kappa(self):
        """Reviewers consistently disagree on every judgment → κ ≤ 0."""
        with TemporaryDirectory() as td:
            scores = Path(td) / "panel-scores.jsonl"
            panel_routed = []
            score_rows = []
            # Plant 3.1: alice=0.0, bob=1.0; Plant 5.1: alice=0.3, bob=0.5
            for plant_id, alice_s, bob_s in [("3.1", 0.0, 1.0), ("5.1", 0.3, 0.5)]:
                for trial in (1, 2, 3):
                    token = f"pr-{plant_id.replace('.', '')}t{trial}"
                    panel_routed.append(_routing_row(token, plant_id, "hsbcolor", trial=trial))
                    score_rows.append({"rec_token": token, "reviewer": "alice", "score": alice_s})
                    score_rows.append({"rec_token": token, "reviewer": "bob", "score": bob_s})
            _write_jsonl(scores, score_rows)
            summary = {}
            score_all.attach_collapsed_panel_kappa(summary, scores, panel_routed)
            block = summary["inter_rater_collapsed"]
            self.assertIsNotNone(block["fleiss_kappa"])
            self.assertLessEqual(block["fleiss_kappa"], 0.0)

    def test_three_reviewers_partial_agreement(self):
        """Three reviewers across two judgments where 2/3 agree on each
        judgment and the third deviates. Exercises the non-degenerate Fleiss κ
        arithmetic path (κ neither perfectly 1.0 nor at-or-below 0)."""
        with TemporaryDirectory() as td:
            scores = Path(td) / "panel-scores.jsonl"
            panel_routed = []
            score_rows = []
            # Plant 3.1: alice=0.0, bob=0.0, carol=0.3 (carol deviates)
            # Plant 5.1: alice=0.5, bob=0.5, carol=0.0 (carol deviates again)
            judgment_scores = [
                ("3.1", {"alice": 0.0, "bob": 0.0, "carol": 0.3}),
                ("5.1", {"alice": 0.5, "bob": 0.5, "carol": 0.0}),
            ]
            for plant_id, by_rev in judgment_scores:
                for trial in (1, 2, 3):
                    token = f"pr-{plant_id.replace('.', '')}t{trial}"
                    panel_routed.append(_routing_row(token, plant_id, "hsbcolor", trial=trial))
                    for reviewer, s in by_rev.items():
                        score_rows.append({"rec_token": token, "reviewer": reviewer, "score": s})
            _write_jsonl(scores, score_rows)
            summary = {}
            score_all.attach_collapsed_panel_kappa(summary, scores, panel_routed)
            block = summary["inter_rater_collapsed"]
            self.assertEqual(block["n_judgments"], 2)
            self.assertEqual(block["n_raters"], 3)
            self.assertIsNotNone(block["fleiss_kappa"])
            # Category counts per item: item1 {0.0:2, 0.3:1}, item2 {0.0:1, 0.5:2}.
            # P_i per item = (sum c² - m) / (m(m-1)) = (4+1-3)/6 = 1/3.
            # P_bar = 1/3.
            # p_j over all 6 ratings: 0.0=3/6, 0.3=1/6, 0.5=2/6.
            # P_e = (3/6)² + (1/6)² + (2/6)² = 14/36 = 7/18.
            # κ = (1/3 − 7/18) / (1 − 7/18) = (−1/18) / (11/18) = −1/11.
            self.assertAlmostEqual(block["fleiss_kappa"], -1.0 / 11.0, places=6)

    def test_median_reduction_across_duplicates(self):
        """A reviewer scoring [0.0, 0.3, 0.5] across 3 duplicates of one
        judgment has median 0.3. With 2 reviewers and 1 judgment, the κ is
        defined (single-judgment κ is 1.0 if both agree, but here both
        agree on the median 0.3)."""
        with TemporaryDirectory() as td:
            scores = Path(td) / "panel-scores.jsonl"
            panel_routed = [_routing_row(f"pr-t{i}", "3.1", "hsbcolor", trial=i) for i in (1, 2, 3)]
            # Both reviewers score [0.0, 0.3, 0.5] across the 3 duplicates →
            # both medians collapse to 0.3.
            score_rows = []
            for token, s in zip(("pr-t1", "pr-t2", "pr-t3"), (0.0, 0.3, 0.5)):
                score_rows.append({"rec_token": token, "reviewer": "alice", "score": s})
                score_rows.append({"rec_token": token, "reviewer": "bob", "score": s})
            _write_jsonl(scores, score_rows)
            summary = {}
            score_all.attach_collapsed_panel_kappa(summary, scores, panel_routed)
            block = summary["inter_rater_collapsed"]
            self.assertEqual(block["n_judgments"], 1)
            judgment = block["judgments"][0]
            self.assertEqual(judgment["reviewer_medians"]["alice"], 0.3)
            self.assertEqual(judgment["reviewer_medians"]["bob"], 0.3)
            # 3 distinct scores per reviewer = nonzero within-reviewer variance.
            self.assertGreater(judgment["reviewer_variance"]["alice"], 0)
            self.assertGreater(judgment["reviewer_variance"]["bob"], 0)
            self.assertEqual(block["within_reviewer_inconsistency_count"], 2)

    def test_within_reviewer_consistency_zero_when_uniform(self):
        """If every reviewer gives the same score across all duplicates of a
        judgment, within-reviewer variance is 0 and the inconsistency count
        is 0."""
        with TemporaryDirectory() as td:
            scores = Path(td) / "panel-scores.jsonl"
            panel_routed = [_routing_row(f"pr-t{i}", "3.1", "hsbcolor", trial=i) for i in (1, 2)]
            score_rows = []
            for token in ("pr-t1", "pr-t2"):
                score_rows.append({"rec_token": token, "reviewer": "alice", "score": 0.0})
                score_rows.append({"rec_token": token, "reviewer": "bob", "score": 0.5})
            _write_jsonl(scores, score_rows)
            summary = {}
            score_all.attach_collapsed_panel_kappa(summary, scores, panel_routed)
            block = summary["inter_rater_collapsed"]
            judgment = block["judgments"][0]
            self.assertEqual(judgment["reviewer_variance"]["alice"], 0.0)
            self.assertEqual(judgment["reviewer_variance"]["bob"], 0.0)
            self.assertEqual(block["within_reviewer_inconsistency_count"], 0)

    def test_orphan_token_is_skipped_with_note(self):
        """A panel-scores row whose rec_token isn't in panel-routing.jsonl
        can't be mapped to a judgment; skip it and surface a note."""
        with TemporaryDirectory() as td:
            scores = Path(td) / "panel-scores.jsonl"
            # routing has only pr-aaaa; panel-scores has pr-aaaa AND pr-orphan
            panel_routed = [_routing_row("pr-aaaa", "3.1", "hsbcolor")]
            _write_jsonl(scores, [
                {"rec_token": "pr-aaaa", "reviewer": "alice", "score": 0.3},
                {"rec_token": "pr-aaaa", "reviewer": "bob", "score": 0.3},
                {"rec_token": "pr-orphan", "reviewer": "alice", "score": 1.0},
            ])
            summary = {}
            score_all.attach_collapsed_panel_kappa(summary, scores, panel_routed)
            block = summary["inter_rater_collapsed"]
            self.assertEqual(block["n_judgments"], 1)
            self.assertIn("orphan", (block.get("note") or "").lower())

    def test_uneven_reviewer_duplicate_coverage(self):
        """Reviewers may cover different numbers of duplicates per judgment.
        n_duplicates_per_reviewer is a per-reviewer dict so this stays legible.
        As long as every reviewer covers the judgment at all, Fleiss κ stays
        defined (it operates on the collapsed median, not the raw counts)."""
        with TemporaryDirectory() as td:
            scores = Path(td) / "panel-scores.jsonl"
            panel_routed = [_routing_row(f"pr-t{i}", "3.1", "hsbcolor", trial=i) for i in (1, 2, 3)]
            # alice covers all 3, bob covers 2 (skips pr-t3).
            score_rows = [
                {"rec_token": "pr-t1", "reviewer": "alice", "score": 0.3},
                {"rec_token": "pr-t2", "reviewer": "alice", "score": 0.3},
                {"rec_token": "pr-t3", "reviewer": "alice", "score": 0.3},
                {"rec_token": "pr-t1", "reviewer": "bob", "score": 0.5},
                {"rec_token": "pr-t2", "reviewer": "bob", "score": 0.5},
            ]
            _write_jsonl(scores, score_rows)
            summary = {}
            score_all.attach_collapsed_panel_kappa(summary, scores, panel_routed)
            block = summary["inter_rater_collapsed"]
            self.assertEqual(block["n_judgments"], 1)
            judgment = block["judgments"][0]
            self.assertEqual(judgment["n_duplicates_per_reviewer"]["alice"], 3)
            self.assertEqual(judgment["n_duplicates_per_reviewer"]["bob"], 2)

    def test_uneven_reviewer_judgment_coverage_emits_sentinel(self):
        """Fleiss κ requires every item rated by exactly m raters. If reviewer
        coverage is uneven at the judgment level (alice scores both, bob only
        one), the canonical κ denominator is undefined; surface a sentinel
        rather than emit a silently-wrong number."""
        with TemporaryDirectory() as td:
            scores = Path(td) / "panel-scores.jsonl"
            # 2 judgments, alice covers both, bob covers only plant 3.1
            panel_routed = []
            score_rows = []
            for plant_id in ("3.1", "5.1"):
                token = f"pr-{plant_id.replace('.', '')}"
                panel_routed.append(_routing_row(token, plant_id, "hsbcolor"))
                score_rows.append({"rec_token": token, "reviewer": "alice", "score": 0.3})
            # bob only scores plant 3.1
            score_rows.append({"rec_token": "pr-31", "reviewer": "bob", "score": 0.3})
            _write_jsonl(scores, score_rows)
            summary = {}
            score_all.attach_collapsed_panel_kappa(summary, scores, panel_routed)
            block = summary["inter_rater_collapsed"]
            self.assertIsNone(block["fleiss_kappa"])
            self.assertEqual(block["n_judgments"], 2)
            self.assertEqual(block["n_raters"], 2)
            self.assertIn("missing", block["note"])


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
                    expected_substrate_signals: ["exact-duplicates"]
                    expected_cluster_symbols: ["Pkg/A.swift"]
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
