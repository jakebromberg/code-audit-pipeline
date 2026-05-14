#!/usr/bin/env python3
"""Render the V7 agent prompt against one normalized cluster row.

Implements the minimal normalizer needed for §5.2 of the pre-flight gate:
take a raw cluster row from one of the 15 query JSONL outputs, project it
into the §3 normalized shape from docs/refactor-recommendation-experiment-agent-prompt.md,
and combine with the static §1+§2 prompt body to produce the full user message.

This is a pre-flight tool — the production normalizer for Phase D §6.2
covers all 15 queries. This one covers exact-duplicates, pat-candidates,
protocol-inheritance-candidates, default-impl-candidates, generic-struct-candidates,
generic-function-candidates, and function-duplicates — enough to exercise
the rendering pipeline against representative shapes.

Output is the rendered prompt to stdout; diagnostics to stderr.

Usage:
  render-prompt.py --query exact-duplicates --row 0 [--condition s2]
  render-prompt.py --query pat-candidates --row 0
"""

import argparse
import json
import os
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PROMPT_DOC = REPO_ROOT / "docs" / "refactor-recommendation-experiment-agent-prompt.md"
EXP_DIR = REPO_ROOT / "experiments" / "v7-refactor-recommendation"


def extract_prompt_body(doc_text: str) -> tuple[str, str]:
    """Return (instructions_block, specifics_block) verbatim from the doc.

    §1 is the first fenced block (plain). §2 is the json-tagged fenced block.
    """
    plain_blocks = re.findall(r"```\n(.*?)\n```", doc_text, re.DOTALL)
    json_blocks = re.findall(r"```json\n(.*?)\n```", doc_text, re.DOTALL)
    if not plain_blocks:
        raise SystemExit("§1 instructions block not found in agent-prompt.md")
    if not json_blocks:
        raise SystemExit("§2 specifics block not found in agent-prompt.md")
    return plain_blocks[0], json_blocks[0]


def normalize_decl(decl: dict, context_flags: dict | None = None) -> dict:
    """Map an extractor decl record to the §3 member shape."""
    return {
        "name": decl.get("name", ""),
        "kind": decl.get("kind", ""),
        "package": decl.get("package", ""),
        "file": decl.get("file", ""),
        "line": decl.get("line", 0),
        "fields_or_signature": decl.get("fields", []) or decl.get("body_lines", []),
        "context_flags": context_flags or {
            "is_test": decl.get("is_test", False),
            "is_codegen": decl.get("is_codegen", False),
            "is_sample_app": decl.get("is_sample_app", False),
            "is_mock": decl.get("is_mock", False),
        },
    }


def normalize_pair_record(rec: dict) -> dict:
    """A `a` or `b` record from a pair-shaped query (pat-candidates etc.).

    These carry conforms_to, fields, fields_structured, plus optionally
    package/file/line/name/kind embedded in the cluster_id. The pair-shaped
    rows carry their identity in cluster_id, not in `a`/`b` — extract from
    the cluster_id when needed.
    """
    return {
        "name": rec.get("name", ""),
        "kind": rec.get("kind", ""),
        "package": rec.get("package", ""),
        "file": rec.get("file", ""),
        "line": rec.get("line", 0),
        "fields_or_signature": rec.get("fields", []),
        "context_flags": {
            "is_test": rec.get("is_test", False),
            "is_codegen": rec.get("is_codegen", False),
            "is_sample_app": rec.get("is_sample_app", False),
            "is_mock": rec.get("is_mock", False),
        },
    }


def normalize_row(raw: dict) -> dict:
    """Project a raw cluster row into the §3 normalized shape.

    Per-query mapping; raises for unsupported queries (those need extending
    before Phase D §6.2).
    """
    query = raw.get("query", "unknown")
    cluster_id = raw.get("cluster_id", "")

    members: list[dict] = []
    structural: dict = {
        "jaccard": raw.get("jaccard"),
        "shared_field_count": raw.get("field_count") or raw.get("shared_field_count"),
        "differing_slots": None,
        "shared_ancestor": None,
    }

    if query in {"exact-duplicates", "name-collisions", "subset-pairs",
                 "near-duplicates", "near-duplicates-any",
                 "cross-package-shadows", "cross-package-shadows-any",
                 "cross-package-shape-near-duplicates",
                 "cross-package-shape-near-duplicates-any"}:
        for decl in raw.get("decls", []):
            members.append(normalize_decl(decl))
        if "jaccard" in raw:
            structural["jaccard"] = raw["jaccard"]

    elif query in {"function-duplicates", "function-duplicates-exact", "file-duplicates"}:
        for decl in raw.get("decls", raw.get("functions", raw.get("files", []))):
            members.append(normalize_decl(decl))

    elif query in {"pat-candidates", "protocol-inheritance-candidates",
                   "generic-struct-candidates", "generic-function-candidates",
                   "default-impl-candidates"}:
        for side in ("a", "b"):
            rec = raw.get(side)
            if rec is not None:
                members.append(normalize_pair_record(rec))
        a_slots = raw.get("a_slots") or []
        b_slots = raw.get("b_slots") or []
        if a_slots or b_slots:
            structural["differing_slots"] = [
                {"a": a_slots, "b": b_slots}
            ]
        structural["shared_field_count"] = raw.get("field_count") or len(raw.get("shared_member_names", []))

    else:
        raise SystemExit(f"normalizer not implemented for query: {query}")

    return {
        "cluster_id": cluster_id,
        "query": query,
        "members": members,
        "structural_evidence": structural,
    }


def render(instructions: str, specifics: str, normalized_row: dict) -> str:
    """Assemble the final user message."""
    return (
        instructions
        + "\n\nPer-category specifics schemas:\n\n"
        + specifics
        + "\n\nCluster row (single-row JSON object):\n\n"
        + json.dumps(normalized_row, indent=2, sort_keys=True)
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--query", required=True)
    parser.add_argument("--row", type=int, default=0,
                        help="0-indexed line number within the query JSONL")
    parser.add_argument("--condition", choices=("s1", "s2"), default="s2")
    parser.add_argument("--check-only", action="store_true",
                        help="Print diagnostics to stderr; suppress prompt on stdout.")
    args = parser.parse_args()

    cluster_path = EXP_DIR / f"clusters-{args.condition}" / f"{args.query}.jsonl"
    if not cluster_path.exists():
        print(f"ERROR: cluster file not found: {cluster_path}", file=sys.stderr)
        return 1

    lines = cluster_path.read_text().splitlines()
    if not lines:
        print(f"ERROR: empty cluster file: {cluster_path}", file=sys.stderr)
        return 1
    if args.row >= len(lines):
        print(f"ERROR: row {args.row} out of range (have {len(lines)} rows)", file=sys.stderr)
        return 1

    raw = json.loads(lines[args.row])
    normalized = normalize_row(raw)

    doc_text = PROMPT_DOC.read_text()
    instructions, specifics = extract_prompt_body(doc_text)
    rendered = render(instructions, specifics, normalized)

    placeholder_re = re.compile(r"\{\{[^{}]*\}\}|<<[A-Z_]+>>")
    unfilled = placeholder_re.findall(rendered)

    char_count = len(rendered)
    word_count = len(rendered.split())
    approx_tokens = char_count // 4

    print("=== Rendering diagnostics ===", file=sys.stderr)
    print(f"  query:             {args.query}", file=sys.stderr)
    print(f"  row index:         {args.row}", file=sys.stderr)
    print(f"  cluster_id:        {normalized['cluster_id'][:80]}...", file=sys.stderr)
    print(f"  member count:      {len(normalized['members'])}", file=sys.stderr)
    print(f"  char count:        {char_count}", file=sys.stderr)
    print(f"  word count:        {word_count}", file=sys.stderr)
    print(f"  approx tokens:     {approx_tokens} (chars/4 estimate)", file=sys.stderr)
    print(f"  context window:    200000 (Sonnet 4.6)", file=sys.stderr)
    fit = "OK" if approx_tokens < 180000 else "OVER"
    print(f"  context fit:       {fit}", file=sys.stderr)
    print(f"  unfilled placeholders: {unfilled if unfilled else 'none'}", file=sys.stderr)

    if unfilled:
        print("FAIL: unfilled template variables in rendered prompt", file=sys.stderr)
        return 1
    if approx_tokens >= 180000:
        print("FAIL: rendered prompt exceeds context window safety margin", file=sys.stderr)
        return 1

    if not args.check_only:
        print(rendered)

    return 0


if __name__ == "__main__":
    sys.exit(main())
