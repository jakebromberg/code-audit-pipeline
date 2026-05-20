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
from harness import prompt  # noqa: E402
from harness.checks import (  # noqa: E402
    check_batching_variance,
    check_substrate_helped,
    should_run_midrun_checks,
)


class TestExtractPromptBody(unittest.TestCase):
    """`extract_prompt_body` returns (§1 instructions, §2+§2.1 specifics).

    v1 has no §2.1 — specifics is byte-identical to the §2 JSON block.
    v2 has §2.1 worked-example prose — appended to specifics under a
    "Worked examples (synthetic, illustrative):" header so render() carries
    them into the user-message body the agent sees at trial time. Without
    this, the §2.1 pre-registered manipulation never reaches the agent.
    """

    DOC_V1 = (
        "preamble\n"
        "```\nINSTR\n```\n"
        "between\n"
        "```json\n{\"k\": \"v\"}\n```\n"
        "## 3. Next\nfoo\n"
    )
    DOC_V2 = (
        "preamble\n"
        "```\nINSTR\n```\n"
        "## 2. Schemas\n"
        "```json\n{\"k\": \"v\"}\n```\n"
        "## 2.1 Worked examples (synthetic, illustrative)\n\n"
        "Example body paragraph.\n\n"
        "## 3. Next\nfoo\n"
    )

    def test_v1_specifics_is_just_json_block(self):
        instr, spec = prompt.extract_prompt_body(self.DOC_V1)
        self.assertEqual(instr, "INSTR")
        self.assertEqual(spec, '{"k": "v"}')
        self.assertNotIn("Worked examples", spec)

    def test_v2_specifics_appends_section_2_1(self):
        instr, spec = prompt.extract_prompt_body(self.DOC_V2)
        self.assertEqual(instr, "INSTR")
        self.assertTrue(spec.startswith('{"k": "v"}'))
        self.assertIn("Worked examples (synthetic, illustrative):", spec)
        self.assertIn("Example body paragraph.", spec)

    def test_v1_file_byte_identical_section_1(self):
        v1 = (REPO_ROOT / "docs" / "refactor-recommendation-experiment-agent-prompt.md").read_text()
        v2 = (REPO_ROOT / "docs" / "refactor-recommendation-experiment-agent-prompt-v2.md").read_text()
        v1_instr, _ = prompt.extract_prompt_body(v1)
        v2_instr, _ = prompt.extract_prompt_body(v2)
        self.assertEqual(v1_instr, v2_instr,
                         "v2 §1 must be byte-identical to v1 per the pre-registration")

    def test_v2_file_carries_worked_example_identifiers(self):
        v2 = (REPO_ROOT / "docs" / "refactor-recommendation-experiment-agent-prompt-v2.md").read_text()
        _, spec = prompt.extract_prompt_body(v2)
        # Sentinels from the five §2.1 worked examples (one per action category).
        for sentinel in (
            "BridgeFoundation",     # extract-to-common
            "MathReducer",          # protocol-inheritance
            "BridgeTransport",      # default-implementation
            "ScopedVault",          # pat-introduction
            "MergeableMetric",      # generic-parameterization
        ):
            self.assertIn(sentinel, spec,
                          f"{sentinel!r} from §2.1 must reach the rendered prompt")


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

    def test_budget_flag_envelope_thresholds(self):
        """Non-default --budget-usd values must shift alert/halt thresholds linearly.

        Locks the contract the `--budget-usd` CLI flag relies on: BudgetState's
        80%/100% thresholds scale with the supplied envelope. The §6.3 all-rows
        run uses `--budget-usd 12` (alert at $9.60, halt at $12.00); regressing
        this would cause the production run to halt or alert at the wrong cost.
        """
        s = gates.BudgetState(budget_usd=12.0, alert_fraction=0.80)
        self.assertAlmostEqual(s.alert_threshold_usd, 9.60)
        # Just under the alert:
        self.assertEqual(s.add(9.00), "ok")
        self.assertFalse(s.alerted)
        # Cross alert at $9.60:
        self.assertEqual(s.add(1.00), "alert")
        self.assertTrue(s.alerted)
        # Still under halt:
        self.assertEqual(s.add(1.00), "ok")
        self.assertFalse(s.is_halted)
        # Cross halt at $12.00:
        self.assertEqual(s.add(1.50), "halt")
        self.assertTrue(s.is_halted)


class TestNormalizer(unittest.TestCase):
    """Regression coverage: function-duplicates.jsonl contains both
    `function-duplicates-exact` (list-shaped) and `function-duplicates-near`
    (pair-shaped) rows. The §6.3 production run surfaced that the near rows
    were taking the `normalizer-unsupported` exit, losing ~25% of the
    function-duplicates signal across all 6 trials."""

    def test_function_duplicates_exact_list_shape(self):
        row = {
            "cluster_id": "function-duplicates-exact:Foo+Bar+Baz",
            "query": "function-duplicates-exact",
            "decls": [
                {"name": "f", "kind": "method", "package": "p",
                 "file": "x.swift", "line": 10, "body_lines": ["a()", "b()"]},
                {"name": "g", "kind": "method", "package": "p",
                 "file": "y.swift", "line": 20, "body_lines": ["a()", "b()"]},
            ],
        }
        out = prompt.normalize_row(row)
        self.assertEqual(out["query"], "function-duplicates-exact")
        self.assertEqual(len(out["members"]), 2)

    def test_function_duplicates_near_pair_shape(self):
        row = {
            "cluster_id": "function-duplicates-near:Foo+Bar",
            "query": "function-duplicates-near",
            "jacc": 0.85,
            "a": {"name": "f", "kind": "method", "package": "pkgA",
                  "file": "a.swift", "line": 10, "fields": ["a()", "b()"]},
            "b": {"name": "g", "kind": "method", "package": "pkgB",
                  "file": "b.swift", "line": 20, "fields": ["a()", "c()"]},
            "intersection": ["a()"],
            "union": ["a()", "b()", "c()"],
        }
        out = prompt.normalize_row(row)
        self.assertEqual(out["query"], "function-duplicates-near")
        self.assertEqual(len(out["members"]), 2)
        self.assertEqual(out["members"][0]["name"], "f")
        self.assertEqual(out["members"][1]["name"], "g")
        # `jacc` is the extractor's field name for jaccard similarity on
        # function-duplicates-near; downstream prompt callers compare across
        # queries via `structural_evidence.jaccard`, so the normalizer must
        # surface it under that canonical key.
        self.assertAlmostEqual(out["structural_evidence"]["jaccard"], 0.85)


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

    def test_sanitize_long_id_truncated_under_fs_limit(self):
        # Real-world: cross-package shape-near-duplicate cluster ids splice two
        # full file-path:line:type-name triples and routinely cross macOS's
        # 255-byte filename limit (PATH_MAX-derived). Sanitize must cap them.
        long_id = "x" * 400
        out = telemetry.sanitize_cluster_id(long_id)
        # Filename including ".json" suffix plus tempfile prefix ".tmp-XXXXXXXX"
        # (13 chars) must fit in 255 bytes; 195 stem keeps total ≤ 213.
        self.assertLessEqual(len(out), 195)

    def test_sanitize_long_distinct_inputs_remain_distinct(self):
        a = "cross-package-shape-near-duplicates-any:" + "A" * 300
        b = "cross-package-shape-near-duplicates-any:" + "B" * 300
        self.assertNotEqual(
            telemetry.sanitize_cluster_id(a),
            telemetry.sanitize_cluster_id(b),
        )

    def test_sanitize_existing_long_stem_preserved(self):
        # Backward compat: the longest stems written before the truncation fix
        # were ~206 chars. Re-sanitizing those ids must return the same stem so
        # resume detection doesn't re-do completed rows.
        prior_safe = "cross-package-shadows-any:" + "Foo." * 45  # ~206 char stem
        out1 = telemetry.sanitize_cluster_id(prior_safe)
        out2 = telemetry.sanitize_cluster_id(prior_safe)
        self.assertEqual(out1, out2)
        # And under the 220-char no-truncation threshold:
        self.assertLessEqual(len(out1), 220)
        self.assertNotIn("__h", out1)  # hash-suffix only appears on truncation

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
    """Records every call and returns the next canned response in `responses`.

    An entry of the form `(EXC, exc_instance)` raises `exc_instance` instead
    of returning — this simulates a transport-layer failure (timeout, DNS,
    connection reset) the way the real urllib transport surfaces it.
    """

    EXC = object()  # sentinel marking an exception entry

    def __init__(self, responses: list[tuple[int, dict]]):
        self.responses = list(responses)
        self.calls: list[tuple[str, dict, bytes]] = []

    def __call__(self, url: str, headers: dict, body: bytes) -> tuple[int, bytes]:
        self.calls.append((url, dict(headers), body))
        entry = self.responses.pop(0)
        if entry[0] is self.EXC:
            raise entry[1]
        status, payload = entry
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

    def test_retries_on_transport_timeout_then_succeeds(self):
        # Regression: an unhandled TimeoutError from `urlopen(..., timeout=N)`
        # crashed the harness mid-run. The retry loop must treat transport-level
        # failures the same as 5xx — retry with backoff.
        ok_body = {"id": "ok", "model": "claude-sonnet-4-6",
                   "content": [{"type": "text", "text": "[]"}],
                   "usage": {"input_tokens": 1, "output_tokens": 1}}
        transport = MockTransport([
            (MockTransport.EXC, TimeoutError("read timed out")),
            (200, ok_body),
        ])
        resp = api.call_messages(
            api.build_payload("hi"),
            api_key="sk-test",
            transport=transport,
            retries=2,
            backoff_base_s=0.001,
        )
        self.assertEqual(resp.status, 200)
        self.assertEqual(len(transport.calls), 2)

    def test_transport_error_exhausted_returns_status_zero(self):
        # When all retries fail at the transport layer, return a sentinel
        # status=0 ApiResponse rather than raising — the harness logs the
        # row as `api-status-0` and continues; one network blip shouldn't
        # abort a 444-row run.
        transport = MockTransport([
            (MockTransport.EXC, TimeoutError("t1")),
            (MockTransport.EXC, TimeoutError("t2")),
            (MockTransport.EXC, TimeoutError("t3")),
        ])
        resp = api.call_messages(
            api.build_payload("hi"),
            api_key="sk-test",
            transport=transport,
            retries=2,
            backoff_base_s=0.001,
        )
        self.assertEqual(resp.status, 0)
        self.assertEqual(len(transport.calls), 3)  # initial + 2 retries
        # Body carries the failure repr so post-mortem analysis can find it:
        self.assertIn("error", resp.body)


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


class TestLoadRowsTolerates(unittest.TestCase):
    """Regression test for the malformed-JSONL-line abort bug.

    `_load_rows` reads each line from `clusters-<cond>/*.jsonl`. A single
    corrupt line — partial write, manual edit, encoding glitch — should not
    abort the whole condition before any telemetry has been written. The
    harness logs and skips, preserving forward progress on the remaining
    rows so resume semantics can pick up where the run left off.
    """

    def _run_load_rows_against(self, cluster_dir: Path) -> list[tuple[str, int, dict]]:
        # The CLI lives at scripts/phase-d-harness.py; import its `_load_rows`
        # but rebind EXP_DIR to our fixture cluster root.
        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "_phd_for_test", REPO_ROOT / "scripts" / "phase-d-harness.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        # Point EXP_DIR at the test fixture so the function's cluster-dir
        # lookup resolves to <fixture>/clusters-<cond>/.
        mod.EXP_DIR = cluster_dir
        return mod._load_rows("s2", None)

    def test_skips_malformed_line_and_keeps_valid_neighbors(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "clusters-s2").mkdir(parents=True)
            jsonl = root / "clusters-s2" / "exact-duplicates.jsonl"
            jsonl.write_text(
                '{"cluster_id": "ok:1", "query": "exact-duplicates"}\n'
                '{not valid json at all\n'
                '\n'  # blank line, should also be skipped (not as malformed)
                '{"cluster_id": "ok:2", "query": "exact-duplicates"}\n'
            )
            rows = self._run_load_rows_against(root)
        self.assertEqual(len(rows), 2)
        self.assertEqual([r["cluster_id"] for _, _, r in rows], ["ok:1", "ok:2"])

    def test_all_malformed_is_empty_not_crash(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "clusters-s2").mkdir(parents=True)
            (root / "clusters-s2" / "x.jsonl").write_text(
                "not json\nstill not json\n"
            )
            rows = self._run_load_rows_against(root)
        self.assertEqual(rows, [])


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
