#!/usr/bin/env python3
"""Unit tests for parse_responses.py (Phase E PR-E1).

Covers fence extraction, well/ill-formed arrays, required-field checks,
idempotence, cluster_id round-trip, and a cross-condition real-body smoke test.

Run from repo root:
  python3 experiments/v7-refactor-recommendation/test_parse_responses.py
"""
from __future__ import annotations

import json
import random
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import parse_responses as pr  # noqa: E402


def _wrap_fenced(rec_json: str, *, lang: str = "json") -> str:
    lang_tag = lang if lang else ""
    return f"```{lang_tag}\n[\n{rec_json}\n]\n```"


def _good_rec() -> dict:
    return {
        "cluster_id": "pat-candidates:Foo",
        "category": "pat-introduction",
        "specifics": {"new_protocol": "Container", "associated_type": "Element"},
        "rationale": "Two types share a contains/count/element shape.",
        "evidence_quote": "func contains(_ x: Element) -> Bool",
        "alternative": None,
        "confidence": 0.82,
    }


def _make_raw_body(text: str) -> dict:
    """Construct the Anthropic Messages API raw-body shape the parser reads."""
    return {
        "content": [{"text": text, "type": "text"}],
        "id": "msg_test",
        "model": "claude-sonnet-4-6",
        "role": "assistant",
        "stop_reason": "end_turn",
        "type": "message",
        "usage": {"input_tokens": 0, "output_tokens": 0},
    }


class ExtractRecommendationTests(unittest.TestCase):
    """Pure parsing — no filesystem."""

    def test_fence_with_json_lang_tag(self):
        text = _wrap_fenced(json.dumps(_good_rec()), lang="json")
        rec, err = pr.extract_recommendation(text)
        self.assertIsNone(err)
        self.assertEqual(rec["category"], "pat-introduction")

    def test_fence_without_lang_tag(self):
        text = _wrap_fenced(json.dumps(_good_rec()), lang="")
        rec, err = pr.extract_recommendation(text)
        self.assertIsNone(err)
        self.assertEqual(rec["category"], "pat-introduction")

    def test_bare_array_no_fence(self):
        text = "[" + json.dumps(_good_rec()) + "]"
        rec, err = pr.extract_recommendation(text)
        self.assertIsNone(err)
        self.assertEqual(rec["category"], "pat-introduction")

    def test_well_formed_single_element(self):
        text = _wrap_fenced(json.dumps(_good_rec()))
        rec, err = pr.extract_recommendation(text)
        self.assertIsNone(err)
        self.assertEqual(rec["specifics"]["new_protocol"], "Container")

    def test_empty_array_returns_wrong_array_length(self):
        text = "```json\n[]\n```"
        rec, err = pr.extract_recommendation(text)
        self.assertIsNone(rec)
        self.assertEqual(err["class"], "wrong-array-length")

    def test_multi_element_array_returns_wrong_array_length(self):
        text = _wrap_fenced(json.dumps(_good_rec()) + "," + json.dumps(_good_rec()))
        rec, err = pr.extract_recommendation(text)
        self.assertIsNone(rec)
        self.assertEqual(err["class"], "wrong-array-length")

    def test_non_json_inside_fence_returns_json_parse_error(self):
        text = "```json\n[ not a valid json object ]\n```"
        rec, err = pr.extract_recommendation(text)
        self.assertIsNone(rec)
        self.assertEqual(err["class"], "json-parse-error")

    def test_no_array_at_all_returns_no_array(self):
        text = "I cannot help with this request."
        rec, err = pr.extract_recommendation(text)
        self.assertIsNone(rec)
        self.assertEqual(err["class"], "no-array")

    def test_missing_specifics_returns_missing_required_field(self):
        rec = _good_rec()
        del rec["specifics"]
        text = _wrap_fenced(json.dumps(rec))
        out, err = pr.extract_recommendation(text)
        self.assertIsNone(out)
        self.assertEqual(err["class"], "missing-required-field")
        self.assertIn("specifics", err["missing_fields"])

    def test_missing_category_returns_missing_required_field(self):
        rec = _good_rec()
        del rec["category"]
        text = _wrap_fenced(json.dumps(rec))
        out, err = pr.extract_recommendation(text)
        self.assertIsNone(out)
        self.assertEqual(err["class"], "missing-required-field")
        self.assertIn("category", err["missing_fields"])

    def test_missing_rationale_returns_missing_required_field(self):
        rec = _good_rec()
        del rec["rationale"]
        text = _wrap_fenced(json.dumps(rec))
        out, err = pr.extract_recommendation(text)
        self.assertIsNone(out)
        self.assertEqual(err["class"], "missing-required-field")
        self.assertIn("rationale", err["missing_fields"])

    def test_missing_confidence_is_not_an_error(self):
        rec = _good_rec()
        del rec["confidence"]
        text = _wrap_fenced(json.dumps(rec))
        out, err = pr.extract_recommendation(text)
        self.assertIsNone(err)
        self.assertEqual(out["category"], "pat-introduction")
        self.assertNotIn("confidence", out)

    def test_missing_evidence_quote_is_not_an_error(self):
        rec = _good_rec()
        del rec["evidence_quote"]
        text = _wrap_fenced(json.dumps(rec))
        out, err = pr.extract_recommendation(text)
        self.assertIsNone(err)

    def test_fence_containing_dict_falls_through_to_no_array(self):
        # The fence regex requires `[...]` inside; a fenced object (no brackets)
        # is treated as missing an array entirely. Matches extract.py behavior.
        text = "```json\n{\"category\": \"foo\"}\n```"
        rec, err = pr.extract_recommendation(text)
        self.assertIsNone(rec)
        self.assertEqual(err["class"], "no-array")


class BuildParsedRecordTests(unittest.TestCase):
    """Stitching parsed body + telemetry → output dict."""

    def _telemetry(self) -> dict:
        return {
            "cluster_id": "pat-candidates:Foo",
            "condition": "s1",
            "cost_usd": 0.01,
            "error_class": None,
            "input_tokens": 100,
            "latency_ms": 1000,
            "output_tokens": 50,
            "query": "pat-candidates",
            "raw_response_path": "raw/s1/trial1/pat-candidates_Foo.json",
            "response_id": "msg_x",
            "response_model": "claude-sonnet-4-6",
            "row_index": 0,
            "trial": 1,
        }

    def test_success_record_shape(self):
        rec = _good_rec()
        out = pr.build_parsed_record(
            telemetry=self._telemetry(), parsed_rec=rec, parse_error=None
        )
        self.assertEqual(out["cluster_id"], "pat-candidates:Foo")
        self.assertEqual(out["condition"], "s1")
        self.assertEqual(out["trial"], 1)
        self.assertEqual(out["query"], "pat-candidates")
        self.assertEqual(out["row_index"], 0)
        self.assertEqual(out["raw_response_path"], "raw/s1/trial1/pat-candidates_Foo.json")
        self.assertEqual(out["parsed"]["category"], "pat-introduction")
        self.assertEqual(out["parsed"]["confidence"], 0.82)
        self.assertEqual(out["parsed"]["specifics"], {"new_protocol": "Container", "associated_type": "Element"})
        self.assertIsNone(out["parse_error"])
        self.assertEqual(out["extraction_notes"]["parser_version"], pr.PARSER_VERSION)

    def test_confidence_absent_serializes_as_null(self):
        rec = _good_rec()
        del rec["confidence"]
        out = pr.build_parsed_record(
            telemetry=self._telemetry(), parsed_rec=rec, parse_error=None
        )
        self.assertIsNone(out["parsed"]["confidence"])

    def test_evidence_quote_absent_serializes_as_null(self):
        rec = _good_rec()
        del rec["evidence_quote"]
        out = pr.build_parsed_record(
            telemetry=self._telemetry(), parsed_rec=rec, parse_error=None
        )
        self.assertIsNone(out["parsed"]["evidence_quote"])

    def test_parse_error_stub_has_null_parsed(self):
        out = pr.build_parsed_record(
            telemetry=self._telemetry(),
            parsed_rec=None,
            parse_error={"class": "json-parse-error", "message": "boom"},
        )
        self.assertIsNone(out["parsed"])
        self.assertEqual(out["parse_error"], "json-parse-error")
        self.assertEqual(out["cluster_id"], "pat-candidates:Foo")

    def test_missing_field_records_missing_fields_in_notes(self):
        out = pr.build_parsed_record(
            telemetry=self._telemetry(),
            parsed_rec=None,
            parse_error={"class": "missing-required-field", "missing_fields": ["specifics"]},
        )
        self.assertEqual(out["parse_error"], "missing-required-field")
        self.assertEqual(out["extraction_notes"]["missing_fields"], ["specifics"])

    def test_parsed_record_is_key_sorted_for_determinism(self):
        rec = _good_rec()
        out = pr.build_parsed_record(
            telemetry=self._telemetry(), parsed_rec=rec, parse_error=None
        )
        encoded = json.dumps(out, indent=2, sort_keys=True)
        round_trip = json.loads(encoded)
        self.assertEqual(round_trip, out)


class CLITests(unittest.TestCase):
    """End-to-end against a temporary trial-logs tree."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="parse-responses-test-"))
        self.trial_logs = self.tmp / "trial-logs"
        # Two synthetic rows: one success, one json-parse-error (matches real corpus shape).
        self._write_pair(
            cond="s1",
            trial=1,
            stem="pat-candidates_Foo",
            telemetry={
                "cluster_id": "pat-candidates:Foo",
                "condition": "s1",
                "cost_usd": 0.01,
                "error_class": None,
                "input_tokens": 100,
                "latency_ms": 1000,
                "output_tokens": 50,
                "query": "pat-candidates",
                "raw_response_path": "raw/s1/trial1/pat-candidates_Foo.json",
                "response_id": "msg_a",
                "response_model": "claude-sonnet-4-6",
                "row_index": 0,
                "trial": 1,
            },
            raw_text=_wrap_fenced(json.dumps(_good_rec())),
        )
        self._write_pair(
            cond="s2",
            trial=1,
            stem="bad-row",
            telemetry={
                "cluster_id": "bad-row:Foo",
                "condition": "s2",
                "cost_usd": 0.01,
                "error_class": "json-parse-error",
                "input_tokens": 100,
                "latency_ms": 1000,
                "output_tokens": 50,
                "query": "bad-row",
                "raw_response_path": "raw/s2/trial1/bad-row.json",
                "response_id": "msg_b",
                "response_model": "claude-sonnet-4-6",
                "row_index": 0,
                "trial": 1,
            },
            raw_text="```json\n[ not valid json ]\n```",
        )

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _write_pair(self, *, cond: str, trial: int, stem: str, telemetry: dict, raw_text: str):
        raw_dir = self.trial_logs / "raw" / cond / f"trial{trial}"
        tel_dir = self.trial_logs / cond / f"trial{trial}"
        raw_dir.mkdir(parents=True, exist_ok=True)
        tel_dir.mkdir(parents=True, exist_ok=True)
        (tel_dir / f"{stem}.json").write_text(json.dumps(telemetry, indent=2))
        (raw_dir / f"{stem}.json").write_text(json.dumps(_make_raw_body(raw_text), indent=2))

    def test_parse_all_writes_parsed_tree(self):
        result = pr.parse_all(trial_logs_dir=self.trial_logs)
        parsed_dir = self.trial_logs / "parsed"
        good = parsed_dir / "s1" / "trial1" / "pat-candidates_Foo.json"
        bad = parsed_dir / "s2" / "trial1" / "bad-row.json"
        self.assertTrue(good.exists())
        self.assertTrue(bad.exists())
        good_doc = json.loads(good.read_text())
        bad_doc = json.loads(bad.read_text())
        self.assertEqual(good_doc["parsed"]["category"], "pat-introduction")
        self.assertIsNone(good_doc["parse_error"])
        self.assertEqual(bad_doc["parse_error"], "json-parse-error")
        self.assertIsNone(bad_doc["parsed"])
        self.assertEqual(result["success"], 1)
        self.assertEqual(result["parse_error"], 1)
        self.assertEqual(result["total"], 2)

    def test_parse_all_cluster_id_round_trips_against_telemetry(self):
        pr.parse_all(trial_logs_dir=self.trial_logs)
        for parsed_path in (self.trial_logs / "parsed").rglob("*.json"):
            parsed_doc = json.loads(parsed_path.read_text())
            # Locate the matching telemetry record by relative path.
            rel = parsed_path.relative_to(self.trial_logs / "parsed")
            tel_doc = json.loads((self.trial_logs / rel).read_text())
            self.assertEqual(parsed_doc["cluster_id"], tel_doc["cluster_id"])

    def test_parse_all_is_idempotent(self):
        first = pr.parse_all(trial_logs_dir=self.trial_logs)
        good_path = self.trial_logs / "parsed" / "s1" / "trial1" / "pat-candidates_Foo.json"
        first_bytes = good_path.read_bytes()
        second = pr.parse_all(trial_logs_dir=self.trial_logs)
        second_bytes = good_path.read_bytes()
        self.assertEqual(first_bytes, second_bytes)
        # Second pass should have no rewrites (skipped == total).
        self.assertEqual(second["skipped"], 2)
        self.assertEqual(second["success"], 0)
        self.assertEqual(second["parse_error"], 0)

    def test_parse_all_force_rewrites(self):
        pr.parse_all(trial_logs_dir=self.trial_logs)
        good_path = self.trial_logs / "parsed" / "s1" / "trial1" / "pat-candidates_Foo.json"
        good_path.write_text("{\"stale\": true}\n")
        result = pr.parse_all(trial_logs_dir=self.trial_logs, force=True)
        doc = json.loads(good_path.read_text())
        self.assertEqual(doc["parsed"]["category"], "pat-introduction")
        self.assertEqual(result["skipped"], 0)

    def test_parse_all_output_is_byte_identical_across_runs(self):
        """Determinism: re-running over a fresh tree produces identical bytes."""
        tmp2 = Path(tempfile.mkdtemp(prefix="parse-responses-det-"))
        try:
            # Mirror the same fixture into a second tree.
            shutil.copytree(self.trial_logs, tmp2 / "trial-logs")
            pr.parse_all(trial_logs_dir=self.trial_logs)
            pr.parse_all(trial_logs_dir=tmp2 / "trial-logs")
            for rel in [
                "parsed/s1/trial1/pat-candidates_Foo.json",
                "parsed/s2/trial1/bad-row.json",
            ]:
                a = (self.trial_logs / rel).read_bytes()
                b = (tmp2 / "trial-logs" / rel).read_bytes()
                self.assertEqual(a, b, f"non-deterministic output at {rel}")
        finally:
            shutil.rmtree(tmp2, ignore_errors=True)


class RealCorpusSmokeTests(unittest.TestCase):
    """Cross-condition smoke: parse 10 real bodies (5 S1, 5 S2) from the in-tree corpus.

    Skips silently if the corpus isn't present (e.g., during a fresh clone before raw/
    is populated). The real corpus lives at experiments/v7-refactor-recommendation/trial-logs/.
    """

    @classmethod
    def setUpClass(cls):
        cls.corpus = HERE / "trial-logs"
        if not (cls.corpus / "raw" / "s1" / "trial1").is_dir():
            raise unittest.SkipTest("real corpus not present")
        rng = random.Random(42)  # deterministic sample
        cls.samples = []
        for cond in ("s1", "s2"):
            files = sorted((cls.corpus / "raw" / cond / "trial1").glob("*.json"))
            if len(files) < 5:
                raise unittest.SkipTest(f"corpus has too few {cond} files")
            cls.samples.extend(rng.sample(files, 5))

    def test_real_bodies_parse_or_classify_known_error(self):
        ok = 0
        for raw_path in self.samples:
            tel_path = self.corpus / raw_path.relative_to(self.corpus / "raw")
            tel = json.loads(tel_path.read_text())
            raw_doc = json.loads(raw_path.read_text())
            text = raw_doc["content"][0]["text"]
            rec, err = pr.extract_recommendation(text)
            if tel.get("error_class") == "json-parse-error":
                self.assertIsNotNone(err)
                self.assertEqual(err["class"], "json-parse-error")
            else:
                self.assertIsNone(err, f"unexpected parse error for {raw_path}: {err}")
                self.assertIsNotNone(rec["category"])
                ok += 1
        self.assertGreaterEqual(ok, 8, f"expected most of 10 sampled rows to parse; got {ok}")


if __name__ == "__main__":
    unittest.main()
