"""Tests for regenerate_panel_scores.py.

The script consolidates per-reviewer panel-score files into the canonical
panel-scores.jsonl that score_all.py reads for Fleiss κ. These tests cover
the pure functions (consolidate, load_reviewer_file, write_consolidated)
and the CLI exit-code surface.
"""
from __future__ import annotations

import io
import json
import subprocess
import sys
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from tempfile import TemporaryDirectory

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import regenerate_panel_scores as rps


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    with path.open("w", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, separators=(",", ":")) + "\n")


class LoadReviewerFileTests(unittest.TestCase):
    def test_round_trips_valid_rows(self):
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores-reviewer-1.jsonl"
            rows = [
                {"rec_token": "pr-aaaa", "reviewer": "reviewer-1", "score": 1.0},
                {"rec_token": "pr-bbbb", "reviewer": "reviewer-1", "score": 0.5, "notes": "n"},
            ]
            _write_jsonl(path, rows)
            self.assertEqual(rps.load_reviewer_file(path), rows)

    def test_skips_blank_lines(self):
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores-reviewer-1.jsonl"
            path.write_text(
                json.dumps({"rec_token": "pr-aaaa", "reviewer": "r1", "score": 1.0})
                + "\n\n\n"
                + json.dumps({"rec_token": "pr-bbbb", "reviewer": "r1", "score": 0.5})
                + "\n"
            )
            self.assertEqual(len(rps.load_reviewer_file(path)), 2)

    def test_missing_required_field_raises(self):
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores-reviewer-1.jsonl"
            path.write_text(json.dumps({"rec_token": "pr-aaaa", "reviewer": "r1"}) + "\n")
            with self.assertRaisesRegex(ValueError, r"missing required field\(s\): score"):
                rps.load_reviewer_file(path)

    def test_invalid_json_raises_with_line_info(self):
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores-reviewer-1.jsonl"
            path.write_text('{"rec_token":"pr-aaaa","reviewer":"r1","score":1.0}\n{not json\n')
            with self.assertRaisesRegex(ValueError, r":2:.*invalid JSON"):
                rps.load_reviewer_file(path)


class ConsolidateTests(unittest.TestCase):
    def test_single_reviewer_pass_through(self):
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores-reviewer-1.jsonl"
            rows = [
                {"rec_token": "pr-aaaa", "reviewer": "r1", "score": 1.0},
                {"rec_token": "pr-bbbb", "reviewer": "r1", "score": 0.5},
            ]
            _write_jsonl(path, rows)
            kept, orphans = rps.consolidate([path], {"pr-aaaa", "pr-bbbb"})
            self.assertEqual(kept, rows)
            self.assertEqual(orphans, [])

    def test_multiple_reviewers_sorted_by_rec_then_reviewer(self):
        with TemporaryDirectory() as td:
            f1 = Path(td) / "panel-scores-reviewer-1.jsonl"
            f2 = Path(td) / "panel-scores-reviewer-2.jsonl"
            _write_jsonl(
                f1,
                [
                    {"rec_token": "pr-bbbb", "reviewer": "r1", "score": 0.5},
                    {"rec_token": "pr-aaaa", "reviewer": "r1", "score": 1.0},
                ],
            )
            _write_jsonl(
                f2,
                [
                    {"rec_token": "pr-aaaa", "reviewer": "r2", "score": 1.0},
                    {"rec_token": "pr-bbbb", "reviewer": "r2", "score": 0.7},
                ],
            )
            kept, orphans = rps.consolidate([f1, f2], {"pr-aaaa", "pr-bbbb"})
            self.assertEqual(
                [(r["rec_token"], r["reviewer"]) for r in kept],
                [("pr-aaaa", "r1"), ("pr-aaaa", "r2"), ("pr-bbbb", "r1"), ("pr-bbbb", "r2")],
            )
            self.assertEqual(orphans, [])

    def test_orphan_token_moved_to_orphans(self):
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores-reviewer-1.jsonl"
            _write_jsonl(
                path,
                [
                    {"rec_token": "pr-survivor", "reviewer": "r1", "score": 1.0},
                    {"rec_token": "pr-orphan", "reviewer": "r1", "score": 0.0},
                ],
            )
            kept, orphans = rps.consolidate([path], {"pr-survivor"})
            self.assertEqual(len(kept), 1)
            self.assertEqual(kept[0]["rec_token"], "pr-survivor")
            self.assertEqual(len(orphans), 1)
            self.assertEqual(orphans[0][1]["rec_token"], "pr-orphan")
            self.assertEqual(orphans[0][0], path.name)

    def test_duplicate_pair_across_files_raises(self):
        with TemporaryDirectory() as td:
            f1 = Path(td) / "panel-scores-reviewer-1.jsonl"
            f2 = Path(td) / "panel-scores-reviewer-1-dup.jsonl"
            _write_jsonl(f1, [{"rec_token": "pr-aaaa", "reviewer": "r1", "score": 1.0}])
            _write_jsonl(f2, [{"rec_token": "pr-aaaa", "reviewer": "r1", "score": 0.5}])
            with self.assertRaisesRegex(ValueError, r"duplicate \(rec_token, reviewer\) pair"):
                rps.consolidate([f1, f2], {"pr-aaaa"})

    def test_duplicate_pair_within_one_file_raises(self):
        with TemporaryDirectory() as td:
            path = Path(td) / "panel-scores-reviewer-1.jsonl"
            _write_jsonl(
                path,
                [
                    {"rec_token": "pr-aaaa", "reviewer": "r1", "score": 1.0},
                    {"rec_token": "pr-aaaa", "reviewer": "r1", "score": 0.5},
                ],
            )
            with self.assertRaisesRegex(ValueError, r"duplicate"):
                rps.consolidate([path], {"pr-aaaa"})


class WriteConsolidatedTests(unittest.TestCase):
    def test_emits_compact_jsonl_no_spaces(self):
        with TemporaryDirectory() as td:
            out = Path(td) / "out.jsonl"
            rps.write_consolidated(
                [{"rec_token": "pr-aaaa", "reviewer": "r1", "score": 1.0}],
                out,
            )
            text = out.read_text()
            # Compact: no spaces after separators
            self.assertIn('"rec_token":"pr-aaaa"', text)
            self.assertNotIn('"rec_token": "pr-aaaa"', text)
            self.assertTrue(text.endswith("\n"))


class MainCLITests(unittest.TestCase):
    def _set_up_fixture(self, td: Path, with_orphan: bool = False) -> Path:
        analyses = td / "analyses"
        analyses.mkdir()
        routing = [
            {"rec_token": "pr-aaaa", "plant_id": "5.1"},
            {"rec_token": "pr-bbbb", "plant_id": "5.1"},
        ]
        _write_jsonl(analyses / "panel-routing.jsonl", routing)
        reviewer_rows = [
            {"rec_token": "pr-aaaa", "reviewer": "r1", "score": 1.0},
            {"rec_token": "pr-bbbb", "reviewer": "r1", "score": 0.5},
        ]
        if with_orphan:
            reviewer_rows.append(
                {"rec_token": "pr-orphan", "reviewer": "r1", "score": 0.0}
            )
        _write_jsonl(analyses / "panel-scores-reviewer-1.jsonl", reviewer_rows)
        return analyses

    def test_returns_zero_on_clean_run(self):
        with TemporaryDirectory() as td:
            analyses = self._set_up_fixture(Path(td))
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                rc = rps.main(["--analyses", str(analyses)])
            self.assertEqual(rc, 0, msg=stderr.getvalue())
            out = analyses / "panel-scores.jsonl"
            self.assertTrue(out.exists())
            self.assertEqual(len(out.read_text().splitlines()), 2)

    def test_orphan_emits_warning_but_succeeds(self):
        with TemporaryDirectory() as td:
            analyses = self._set_up_fixture(Path(td), with_orphan=True)
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                rc = rps.main(["--analyses", str(analyses)])
            self.assertEqual(rc, 0)
            self.assertIn("orphan rec_token", stderr.getvalue())
            # Orphan dropped from output
            out = analyses / "panel-scores.jsonl"
            self.assertEqual(len(out.read_text().splitlines()), 2)

    def test_missing_panel_routing_returns_two(self):
        with TemporaryDirectory() as td:
            analyses = Path(td) / "analyses"
            analyses.mkdir()
            _write_jsonl(
                analyses / "panel-scores-reviewer-1.jsonl",
                [{"rec_token": "pr-aaaa", "reviewer": "r1", "score": 1.0}],
            )
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                rc = rps.main(["--analyses", str(analyses)])
            self.assertEqual(rc, 2)
            self.assertIn("panel-routing.jsonl not found", stderr.getvalue())

    def test_no_reviewer_files_returns_two(self):
        with TemporaryDirectory() as td:
            analyses = Path(td) / "analyses"
            analyses.mkdir()
            _write_jsonl(analyses / "panel-routing.jsonl", [{"rec_token": "pr-aaaa"}])
            stderr = io.StringIO()
            with redirect_stderr(stderr):
                rc = rps.main(["--analyses", str(analyses)])
            self.assertEqual(rc, 2)
            self.assertIn("no per-reviewer files found", stderr.getvalue())

    def test_subprocess_end_to_end(self):
        with TemporaryDirectory() as td:
            analyses = self._set_up_fixture(Path(td))
            result = subprocess.run(
                [
                    sys.executable,
                    str(HERE / "regenerate_panel_scores.py"),
                    "--analyses",
                    str(analyses),
                ],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, msg=result.stderr)
            out = analyses / "panel-scores.jsonl"
            self.assertTrue(out.exists())


if __name__ == "__main__":
    unittest.main()
