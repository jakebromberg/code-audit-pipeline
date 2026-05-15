#!/usr/bin/env python3
"""Render the V7 agent prompt against one normalized cluster row.

CLI shim around `scripts/harness/prompt.py`. Originally a self-contained
script during the §5.2 pre-flight; the §6.2 trial harness lifted the
normalization/rendering helpers into `harness.prompt` so they can be called
in-process. This file keeps the same CLI contract so the §5.3 dry-run path
(`scripts/dry-run-cluster.sh`) continues to work unchanged.

Usage:
  render-prompt.py --query exact-duplicates --row 0 [--condition s2]
  render-prompt.py --query pat-candidates --row 0 --check-only
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Make `harness` importable when invoked as `scripts/render-prompt.py ...`.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness.prompt import extract_prompt_body, normalize_row, render

REPO_ROOT = Path(__file__).resolve().parent.parent
PROMPT_DOC = REPO_ROOT / "docs" / "refactor-recommendation-experiment-agent-prompt.md"
EXP_DIR = REPO_ROOT / "experiments" / "v7-refactor-recommendation"


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
