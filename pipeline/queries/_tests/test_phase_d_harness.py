"""Unit tests for the Phase D trial harness (V7 §6.2).

These tests exercise the harness modules directly with a mocked HTTP
transport — no live API calls. The cost-gate, token-cap, fence-extraction,
resume, and signature-check logic are all covered here so the production
run in §6.3 only has to trust well-tested primitives.

Run from repo root:
  python3 pipeline/queries/_tests/test_phase_d_harness.py
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from harness import api, extract, gates, telemetry  # noqa: E402
from harness.checks import (  # noqa: E402
    check_batching_variance,
    check_substrate_helped,
    should_run_midrun_checks,
)


class TestFenceExtraction(unittest.TestCase):
    def test_bare_array(self):
        text = '[{"cluster_id": "x", "category": "no-action"}]'
        arr = extract.extract_recommendation_array(text)
        self.assertEqual(len(arr), 1)
        self.assertEqual(arr[0]["cluster_id"], "x")

    def test_fenced_array(self):
        text = 'Some preamble.\n```json\n[{"cluster_id": "y"}]\n```\nTrailing prose.'
        arr = extract.extract_recommendation_array(text)
        self.assertEqual(len(arr), 1)
        self.assertEqual(arr[0]["cluster_id"], "y")

    def test_plain_fence_no_lang(self):
        text = '```\n[{"cluster_id": "z"}]\n```'
        arr = extract.extract_recommendation_array(text)
        self.assertEqual(arr[0]["cluster_id"], "z")

    def test_no_array_raises(self):
        with self.assertRaises(extract.ExtractError) as cm:
            extract.extract_recommendation_array("no array here")
        self.assertEqual(cm.exception.error_class, "no-array")

    def test_malformed_json_raises(self):
        with self.assertRaises(extract.ExtractError) as cm:
            extract.extract_recommendation_array("[not, valid, json,]")
        self.assertEqual(cm.exception.error_class, "json-parse-error")


class TestCostGates(unittest.TestCase):
    def test_cost_for_usage(self):
        cost = gates.cost_for_usage(1_000_000, 1_000_000)
        self.assertAlmostEqual(cost, 3.00 + 15.00)

    def test_token_overrun_just_under_cap(self):
        self.assertFalse(gates.is_token_overrun(25_000, 25_000))

    def test_token_overrun_over_cap(self):
        self.assertTrue(gates.is_token_overrun(25_000, 25_001))

    def test_budget_state_ok_alert_halt(self):
        # $3.50 budget; 80% = $2.80; 100% = $3.50
        s = gates.BudgetState(budget_usd=3.50, alert_fraction=0.80)
        self.assertEqual(s.add(2.00), "ok")    # spent 2.00
        self.assertEqual(s.add(0.50), "ok")    # spent 2.50, still under alert
        self.assertEqual(s.add(0.40), "alert") # spent 2.90, crosses 2.80 alert
        self.assertEqual(s.add(0.30), "ok")    # spent 3.20, no re-alert
        self.assertEqual(s.add(0.40), "halt")  # spent 3.60, crosses budget
        self.assertTrue(s.is_halted)
        # Idempotent halt:
        self.assertEqual(s.add(0.01), "halt")
        self.assertAlmostEqual(s.spent_usd, 3.60)

    def test_alert_fires_exactly_once(self):
        s = gates.BudgetState(budget_usd=10.0, alert_fraction=0.80)
        states = [s.add(2.0), s.add(2.0), s.add(2.0), s.add(2.0), s.add(0.5)]
        self.assertEqual(states.count("alert"), 1, f"alert should fire once, got {states}")

    def test_halt_when_already_past_at_call(self):
        s = gates.BudgetState(budget_usd=1.0)
        # First add overshoots:
        self.assertEqual(s.add(2.0), "halt")
        self.assertEqual(s.add(0.01), "halt")


class TestSignatureChecks(unittest.TestCase):
    def test_should_run_midrun_at_quarter_mark(self):
        # 100 rows, 25% = row 25
        self.assertFalse(should_run_midrun_checks(24, 100))
        self.assertTrue(should_run_midrun_checks(25, 100))
        self.assertFalse(should_run_midrun_checks(26, 100))

    def test_should_run_midrun_handles_tiny_runs(self):
        # 4 rows, 25% → target=1; fires on row 1.
        self.assertTrue(should_run_midrun_checks(1, 4))
        self.assertFalse(should_run_midrun_checks(2, 4))

    def test_batching_variance_stable(self):
        # 3 trials, all agree on every cluster → fraction_stable=1.0 → no fire
        data = {"c1": ["a", "a", "a"], "c2": ["b", "b", "b"]}
        r = check_batching_variance(data)
        self.assertFalse(r.fired)

    def test_batching_variance_unstable(self):
        # No cluster has 2/3 agreement
        data = {"c1": ["a", "b", "c"], "c2": ["a", "b", "c"]}
        r = check_batching_variance(data)
        self.assertTrue(r.fired)

    def test_substrate_helped_self_skips_on_empty(self):
        r = check_substrate_helped([], [0.5, 0.6])
        self.assertFalse(r.fired)
        self.assertIn("skipped", r.reason)

    def test_substrate_helped_fires_when_no_delta(self):
        r = check_substrate_helped([0.8, 0.8, 0.8], [0.79, 0.80, 0.81])
        self.assertTrue(r.fired)

    def test_substrate_helped_passes_with_margin(self):
        r = check_substrate_helped([0.5, 0.5, 0.5], [0.7, 0.7, 0.7])
        self.assertFalse(r.fired)


class TestTelemetry(unittest.TestCase):
    def test_sanitize_cluster_id_round(self):
        self.assertEqual(telemetry.sanitize_cluster_id("pat:Foo:Bar"), "pat_Foo_Bar")
        self.assertEqual(telemetry.sanitize_cluster_id("foo/bar baz!"), "foo_bar_baz")
        # Already-safe stays put:
        self.assertEqual(telemetry.sanitize_cluster_id("abc-123_def.json"), "abc-123_def.json")

    def test_sanitize_empty(self):
        self.assertEqual(telemetry.sanitize_cluster_id(""), "EMPTY")
        self.assertEqual(telemetry.sanitize_cluster_id("///"), "EMPTY")

    def test_write_and_list_completed(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            telemetry.write_telemetry(
                root, "s2", 1, "cluster:abc",
                query="exact-duplicates", row_index=0,
                input_tokens=100, output_tokens=20, latency_ms=2000,
                cost_usd=0.001, error_class=None,
                response_model="claude-sonnet-4-6", response_id="msg_xyz",
                raw_response={"id": "msg_xyz", "content": [{"type": "text", "text": "[]"}]},
            )
            completed = telemetry.list_completed_cluster_ids(root, "s2", 1)
            self.assertEqual(completed, {"cluster_abc"})
            # Empty for the other trial:
            self.assertEqual(telemetry.list_completed_cluster_ids(root, "s2", 2), set())
            # Raw response also written:
            raw_path = telemetry.raw_response_path(root, "s2", 1, "cluster:abc")
            self.assertTrue(raw_path.exists())
            raw = json.loads(raw_path.read_text())
            self.assertEqual(raw["id"], "msg_xyz")

    def test_filter_incomplete_skips_completed(self):
        completed = {"cluster_abc", "cluster_def"}
        rows = [
            (0, {"cluster_id": "cluster:abc"}),
            (1, {"cluster_id": "cluster:def"}),
            (2, {"cluster_id": "cluster:ghi"}),
        ]
        pending = telemetry.filter_incomplete(iter(rows), completed)
        self.assertEqual([idx for idx, _ in pending], [2])


class MockTransport:
    """Records every call and returns the next canned response in `responses`."""

    def __init__(self, responses: list[tuple[int, dict]]):
        self.responses = list(responses)
        self.calls: list[tuple[str, dict, bytes]] = []

    def __call__(self, url: str, headers: dict, body: bytes) -> tuple[int, bytes]:
        self.calls.append((url, dict(headers), body))
        status, payload = self.responses.pop(0)
        return status, json.dumps(payload).encode("utf-8")


class TestApiTransport(unittest.TestCase):
    def test_successful_call_records_latency(self):
        canned_body = {
            "id": "msg_abc",
            "model": "claude-sonnet-4-6",
            "content": [{"type": "text", "text": '[{"cluster_id": "x"}]'}],
            "usage": {"input_tokens": 2500, "output_tokens": 200},
        }
        transport = MockTransport([(200, canned_body)])
        resp = api.call_messages(
            api.build_payload("hello"),
            api_key="sk-test",
            transport=transport,
        )
        self.assertEqual(resp.status, 200)
        self.assertEqual(resp.body["id"], "msg_abc")
        self.assertGreaterEqual(resp.latency_ms, 0)
        # Headers passed correctly:
        headers = transport.calls[0][1]
        self.assertEqual(headers["x-api-key"], "sk-test")
        self.assertEqual(headers["anthropic-version"], "2023-06-01")

    def test_retries_on_500_then_succeeds(self):
        ok_body = {"id": "ok", "model": "claude-sonnet-4-6",
                   "content": [{"type": "text", "text": "[]"}],
                   "usage": {"input_tokens": 1, "output_tokens": 1}}
        transport = MockTransport([(500, {"error": "boom"}), (200, ok_body)])
        resp = api.call_messages(
            api.build_payload("hi"),
            api_key="sk-test",
            transport=transport,
            retries=2,
            backoff_base_s=0.001,  # keep test fast
        )
        self.assertEqual(resp.status, 200)
        self.assertEqual(len(transport.calls), 2)

    def test_no_retry_on_400(self):
        bad = {"error": {"type": "invalid_request_error", "message": "bad"}}
        transport = MockTransport([(400, bad)])
        resp = api.call_messages(
            api.build_payload("hi"),
            api_key="sk-test",
            transport=transport,
            retries=3,
            backoff_base_s=0.001,
        )
        self.assertEqual(resp.status, 400)
        self.assertEqual(len(transport.calls), 1)

    def test_extract_text(self):
        body = {"content": [
            {"type": "text", "text": "hello "},
            {"type": "text", "text": "world"},
        ]}
        self.assertEqual(api.extract_text(body), "hello world")


class TestEndToEndOneRowWithMockedTransport(unittest.TestCase):
    """Verify the full pipeline: payload → mock → parse → telemetry write."""

    def test_one_row_round_trip(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)

            # Canned successful API response:
            rec_payload = [{"cluster_id": "exact:foo",
                            "category": "no-action",
                            "specifics": {},
                            "rationale": "test-fixture",
                            "evidence_quote": "is_test=true",
                            "confidence": 0.9}]
            body = {
                "id": "msg_test123",
                "model": "claude-sonnet-4-6",
                "content": [{"type": "text", "text": json.dumps(rec_payload)}],
                "usage": {"input_tokens": 3000, "output_tokens": 250},
            }
            transport = MockTransport([(200, body)])

            payload = api.build_payload("test prompt body")
            resp = api.call_messages(payload, api_key="sk-test", transport=transport)
            self.assertEqual(resp.status, 200)

            text = api.extract_text(resp.body)
            arr = extract.extract_recommendation_array(text)
            self.assertEqual(len(arr), 1)
            self.assertEqual(arr[0]["category"], "no-action")

            cost = gates.cost_for_usage(3000, 250)
            self.assertFalse(gates.is_token_overrun(3000, 250))

            telemetry.write_telemetry(
                root, "s2", 1, "exact:foo",
                query="exact-duplicates", row_index=0,
                input_tokens=3000, output_tokens=250,
                latency_ms=resp.latency_ms, cost_usd=cost,
                error_class=None,
                response_model=resp.body["model"],
                response_id=resp.body["id"],
                raw_response=resp.body,
            )

            written = json.loads((root / "s2" / "trial1" / "exact_foo.json").read_text())
            self.assertEqual(written["response_model"], "claude-sonnet-4-6")
            self.assertEqual(written["response_id"], "msg_test123")
            self.assertEqual(written["error_class"], None)
            self.assertEqual(written["raw_response_path"], "raw/s2/trial1/exact_foo.json")


class TestCliResumeFilterPreservesQuery(unittest.TestCase):
    """Regression test for the per-file row-index collision bug.

    `_load_rows` enumerates each JSONL file from 0, so the same `row_index`
    appears in multiple (query, row_index, raw) tuples. The resume filter in
    the CLI must NOT key its `query`-recovery off `row_index` alone — that
    silently mis-labels rows whose indices collide between query files. The
    fix keeps `(query, row_index, raw)` triples intact through filtering.
    """

    def test_filter_does_not_collide_on_per_file_indices(self):
        # Two query files, each with row_index=0 and row_index=1.
        all_rows = [
            ("exact-duplicates", 0, {"cluster_id": "exact:A"}),
            ("exact-duplicates", 1, {"cluster_id": "exact:B"}),
            ("pat-candidates", 0, {"cluster_id": "pat:C"}),
            ("pat-candidates", 1, {"cluster_id": "pat:D"}),
        ]
        completed: set[str] = set()  # nothing completed yet
        # Mirror the CLI's inline filter:
        pending_full = [
            (q, idx, raw)
            for (q, idx, raw) in all_rows
            if telemetry.sanitize_cluster_id(raw.get("cluster_id", "")) not in completed
        ]
        # Every row keeps its original query — no collision-driven re-labeling.
        self.assertEqual(
            sorted((q, raw["cluster_id"]) for q, _, raw in pending_full),
            sorted([
                ("exact-duplicates", "exact:A"),
                ("exact-duplicates", "exact:B"),
                ("pat-candidates", "pat:C"),
                ("pat-candidates", "pat:D"),
            ]),
        )

    def test_filter_drops_completed_by_sanitized_id(self):
        all_rows = [
            ("exact-duplicates", 0, {"cluster_id": "exact:A"}),
            ("pat-candidates", 0, {"cluster_id": "pat:C"}),
        ]
        completed = {"exact_A"}  # sanitized form of "exact:A"
        pending_full = [
            (q, idx, raw)
            for (q, idx, raw) in all_rows
            if telemetry.sanitize_cluster_id(raw.get("cluster_id", "")) not in completed
        ]
        self.assertEqual(len(pending_full), 1)
        self.assertEqual(pending_full[0][0], "pat-candidates")


if __name__ == "__main__":
    unittest.main(verbosity=2)
