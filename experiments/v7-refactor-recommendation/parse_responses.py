#!/usr/bin/env python3
"""Phase E PR-E1 — response-body parser + parsed-fields cache.

Reads raw `/v1/messages` response bodies under
`experiments/v7-refactor-recommendation/trial-logs/raw/<cond>/trial<n>/*.json`
and writes a parallel parsed cache to `trial-logs/parsed/<cond>/trial<n>/*.json`.

One parsed file per raw file. The 2 corpus rows with `error_class:
"json-parse-error"` in their telemetry produce a stub with `parsed: null` and
`parse_error: "json-parse-error"`.

The parser is intentionally minimal — no scoring, no analysis, no validation
against `rubric.specifics_schemas`. It records what the model emitted,
verbatim, so downstream PRs (E2 substrate-helped, E3 auto-scorer) can read a
stable cache instead of re-doing fence extraction.

Run from repo root:
  python3 experiments/v7-refactor-recommendation/parse_responses.py
  python3 experiments/v7-refactor-recommendation/parse_responses.py --force

Parse-error namespace
---------------------
`parse_error` is `null` on success or one of these discriminator strings on
failure (a superset that aligns with `scripts/harness/extract.py`'s
`ExtractError.error_class` namespace where they overlap):

  - `no-array`              — no JSON array found in the response text.
  - `not-a-list`            — fenced block contained a JSON value but not a list.
  - `json-parse-error`      — array text is not valid JSON. Reused verbatim from
                              the harness extractor so telemetry's `error_class`
                              and the parsed cache never disagree on the 2
                              corpus rows that already failed there.
  - `wrong-array-length`    — array is empty or has length != 1.
                              (Harness expects single-rec arrays per Phase D
                              §5.3; multi-element arrays violate that contract.)
  - `missing-required-field`— required key (`category`, `specifics`, or
                              `rationale`) missing from the rec dict. The
                              field names are recorded in
                              `extraction_notes.missing_fields`.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

PARSER_VERSION = "1.0"

REQUIRED_REC_FIELDS = ("category", "specifics", "rationale")
NULLABLE_REC_FIELDS = ("evidence_quote",)
OPTIONAL_REC_FIELDS = ("confidence",)

_FENCED_RE = re.compile(r"```(?:[a-zA-Z]*)\s*(\[.*?\])\s*```", re.DOTALL)
_BARE_RE = re.compile(r"\[.*\]", re.DOTALL)


def extract_recommendation(text: str) -> tuple[dict | None, dict | None]:
    """Parse a single recommendation from a response body's text field.

    Returns `(rec, None)` on success or `(None, error)` where `error` is
    a dict with at least `{"class": <discriminator>}` plus optional details.
    See module docstring for the discriminator namespace.
    """
    fenced = _FENCED_RE.search(text)
    if fenced:
        array_text = fenced.group(1)
    else:
        m = _BARE_RE.search(text)
        if not m:
            return None, {"class": "no-array", "message": "response does not contain a JSON array"}
        array_text = m.group(0)

    try:
        arr = json.loads(array_text)
    except json.JSONDecodeError as e:
        return None, {"class": "json-parse-error", "message": f"response array is not valid JSON: {e}"}

    if not isinstance(arr, list):
        return None, {"class": "not-a-list", "message": f"expected list, got {type(arr).__name__}"}

    if len(arr) != 1:
        return None, {"class": "wrong-array-length", "message": f"expected length 1, got {len(arr)}"}

    rec = arr[0]
    if not isinstance(rec, dict):
        return None, {"class": "not-a-list", "message": f"expected rec dict, got {type(rec).__name__}"}

    missing = [f for f in REQUIRED_REC_FIELDS if f not in rec]
    if missing:
        return None, {
            "class": "missing-required-field",
            "message": f"missing required fields: {missing}",
            "missing_fields": missing,
        }

    return rec, None


def build_parsed_record(
    *,
    telemetry: dict,
    parsed_rec: dict | None,
    parse_error: dict | None,
) -> dict:
    """Stitch a telemetry record + parsed rec (or parse error) into the cache schema.

    Schema: see Phase E plan §1.1. Keys are produced in a stable order; the
    caller writes the result with `sort_keys=True` for byte-deterministic
    output.
    """
    extraction_notes: dict = {"parser_version": PARSER_VERSION}
    if parse_error and parse_error.get("class") == "missing-required-field":
        extraction_notes["missing_fields"] = list(parse_error.get("missing_fields", []))

    if parsed_rec is not None:
        parsed_field: dict | None = {
            "category": parsed_rec["category"],
            "specifics": parsed_rec["specifics"],
            "rationale": parsed_rec["rationale"],
            "evidence_quote": parsed_rec.get("evidence_quote"),
            "confidence": parsed_rec.get("confidence"),
        }
    else:
        parsed_field = None

    return {
        "cluster_id": telemetry["cluster_id"],
        "condition": telemetry["condition"],
        "trial": telemetry["trial"],
        "query": telemetry["query"],
        "row_index": telemetry["row_index"],
        "raw_response_path": telemetry["raw_response_path"],
        "parsed": parsed_field,
        "parse_error": parse_error["class"] if parse_error else None,
        "extraction_notes": extraction_notes,
    }


def _extract_text_from_raw_body(raw_doc: dict) -> str | None:
    """Pull `content[0].text` from an Anthropic Messages API response body."""
    content = raw_doc.get("content")
    if not isinstance(content, list) or not content:
        return None
    first = content[0]
    if not isinstance(first, dict):
        return None
    text = first.get("text")
    return text if isinstance(text, str) else None


def parse_one(*, raw_path: Path, telemetry: dict) -> dict:
    """Parse a single raw response file into a parsed-cache record."""
    raw_doc = json.loads(raw_path.read_text())
    text = _extract_text_from_raw_body(raw_doc)
    if text is None:
        return build_parsed_record(
            telemetry=telemetry,
            parsed_rec=None,
            parse_error={"class": "no-array", "message": "raw response has no content[0].text"},
        )
    rec, err = extract_recommendation(text)
    return build_parsed_record(telemetry=telemetry, parsed_rec=rec, parse_error=err)


def _iter_telemetry_files(trial_logs_dir: Path):
    """Yield (telemetry_path, raw_path) pairs for every telemetry record.

    Walks `trial-logs/<cond>/trial<n>/*.json`, skipping `raw/` and `parsed/`.
    The corresponding raw path is `trial-logs/raw/<cond>/trial<n>/<basename>`.
    """
    for child in sorted(trial_logs_dir.iterdir()):
        if not child.is_dir() or child.name in ("raw", "parsed"):
            continue
        for trial_dir in sorted(child.iterdir()):
            if not trial_dir.is_dir():
                continue
            for tel_path in sorted(trial_dir.glob("*.json")):
                rel = tel_path.relative_to(trial_logs_dir)
                raw_path = trial_logs_dir / "raw" / rel
                yield tel_path, raw_path


def parse_all(*, trial_logs_dir: Path, force: bool = False) -> dict:
    """Walk every telemetry record under `trial_logs_dir` and populate `parsed/`.

    Idempotent: skips records whose parsed file already exists unless `force`.
    Returns a dict with counts: total, skipped, success, parse_error.
    """
    parsed_root = trial_logs_dir / "parsed"
    counts = {"total": 0, "skipped": 0, "success": 0, "parse_error": 0}

    for tel_path, raw_path in _iter_telemetry_files(trial_logs_dir):
        counts["total"] += 1
        rel = tel_path.relative_to(trial_logs_dir)
        out_path = parsed_root / rel
        if out_path.exists() and not force:
            counts["skipped"] += 1
            continue
        if not raw_path.exists():
            print(f"warn: raw file missing for {tel_path}", file=sys.stderr)
            continue
        telemetry = json.loads(tel_path.read_text())
        record = parse_one(raw_path=raw_path, telemetry=telemetry)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
        if record["parse_error"] is None:
            counts["success"] += 1
        else:
            counts["parse_error"] += 1

    return counts


def main(argv: list[str] | None = None) -> int:
    here = Path(__file__).resolve().parent
    default_trial_logs = here / "trial-logs"

    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--trial-logs",
        type=Path,
        default=default_trial_logs,
        help="Path to the trial-logs/ directory (default: alongside this script).",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Re-parse and overwrite even if a parsed file already exists.",
    )
    args = ap.parse_args(argv)

    if not args.trial_logs.is_dir():
        print(f"error: --trial-logs path is not a directory: {args.trial_logs}", file=sys.stderr)
        return 2

    counts = parse_all(trial_logs_dir=args.trial_logs, force=args.force)
    print(
        f"total={counts['total']} skipped={counts['skipped']} "
        f"success={counts['success']} parse_error={counts['parse_error']}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
