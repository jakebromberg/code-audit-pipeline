#!/usr/bin/env python3
"""Check v2 worked-example identifiers don't overlap with manifest content.

Per the prompt-sensitivity sub-experiment plan §3.1(b), the v2 worked examples
must be drawn from a synthetic toy refactor with zero overlap against the
25-plant V7 manifest. This script extracts identifier candidates from the v2
prompt's §2.1 worked-examples block and tests each as a substring (both
directions) against string values in the manifest under the in-scope fields:

  - source_type
  - source_files
  - expected_cluster_symbols
  - primary_answer.specifics.*       (every leaf string under specifics)
  - alternative_answers[*].specifics.* (every leaf string under each alt's specifics)

Exits non-zero if any substring match >= MIN_MATCH_LEN is found, with a
per-match diagnostic. Exits zero with a clean banner otherwise — paste the
clean output into PR 1's review comment to satisfy the plan §5 acceptance
criterion ("Overlap review verifies, in PR review comments: (1) no v2-example
identifier ... appears as a key or value in plant-manifest.yaml; (2) no
v2-example identifier is a substring of any plant's expected_cluster_symbols
list entry; (3) reviewer approval comment explicitly attached before merge").

Usage:
  scripts/check_example_overlap.py
  scripts/check_example_overlap.py --prompt docs/refactor-recommendation-experiment-agent-prompt-v2.md
  scripts/check_example_overlap.py --manifest experiments/v7-refactor-recommendation/plant-manifest.yaml
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PROMPT = REPO_ROOT / "docs" / "refactor-recommendation-experiment-agent-prompt-v2.md"
DEFAULT_MANIFEST = REPO_ROOT / "experiments" / "v7-refactor-recommendation" / "plant-manifest.yaml"

# Substring matches below this length are treated as English-word noise rather
# than corpus leakage (e.g., "Item", "Util", "Type"). The plan's overlap-review
# concern is identifier-level leakage; raise this floor if false positives flood
# the output and the plan can document the new threshold.
MIN_MATCH_LEN = 5

# Swift stdlib + language-primitive vocabulary that any worked example will
# reference (type constraints, schema enum values, etc.). These are universal
# background knowledge for an agent reviewing Swift code; their appearance in
# both the v2 prompt and the manifest is not corpus leakage — the agent already
# knows these names exist as part of Swift, not because they were planted.
# Matches involving ONLY these tokens are suppressed. Keep this list tight:
# anything project-local (framework names, third-party libraries) belongs in
# the manifest's identifier space, not here.
STDLIB_ALLOWLIST = frozenset({
    # Swift stdlib value types
    "String", "Int", "Bool", "Double", "Float", "Character", "Optional",
    "Array", "Dictionary", "Set",
    # Swift stdlib protocols
    "Hashable", "Equatable", "Comparable", "Codable", "Encodable", "Decodable",
    "Sendable", "Identifiable", "Iterable", "Sequence", "Collection",
    "CustomStringConvertible",
    # Language / framework names (the agent will mention these in any review)
    "Swift",
    # Schema enum values that recur as literal strings in both the v2 prompt
    # and the manifest specifics blocks
    "function", "struct", "class", "protocol", "enum", "extension",
})

# In-scope manifest fields per plan §3.1(b). Only these scalar/list fields and
# the nested `primary_answer.specifics.*` / `alternative_answers[*].specifics.*`
# leaf strings are considered.
SCALAR_OR_LIST_FIELDS = ("source_type", "source_files", "expected_cluster_symbols")


def _extract_worked_examples_block(doc_text: str, prompt_path: Path) -> str:
    """Return the §2.1 worked-examples block — between the §2.1 header and the next ## header."""
    start_re = re.compile(r"^## 2\.1\b[^\n]*$", re.MULTILINE)
    next_h2 = re.compile(r"^## ", re.MULTILINE)
    start = start_re.search(doc_text)
    if not start:
        raise SystemExit(f"ERROR: §2.1 header not found in {prompt_path}")
    end_match = next_h2.search(doc_text, start.end())
    if not end_match:
        raise SystemExit(f"ERROR: no terminating ## header after §2.1 in {prompt_path}")
    return doc_text[start.end():end_match.start()]


def _extract_identifiers(block: str) -> set[str]:
    """Extract identifier candidates from the worked-examples block.

    Three sources:
      (a) every backtick-quoted token (inline code in Markdown)
      (b) every CamelCase token >= 4 chars
      (c) every camelCase token >= 4 chars

    Identifier candidates are conservative — false positives in this set are
    safe (they just produce louder output); false negatives are dangerous (a
    leaked identifier slips into the experiment).
    """
    backtick = set(re.findall(r"`([^`]+)`", block))
    camel = set(re.findall(r"\b[A-Z][a-z][A-Za-z0-9_]{2,}\b", block))
    lower_camel = set(re.findall(r"\b[a-z]+[A-Z][A-Za-z0-9_]+\b", block))
    return backtick | camel | lower_camel


def _flatten_strings(node, prefix: str) -> list[tuple[str, str]]:
    """Yield (path, value) pairs for every string leaf under `node`."""
    out: list[tuple[str, str]] = []
    if isinstance(node, str):
        out.append((prefix, node))
    elif isinstance(node, dict):
        for k, v in node.items():
            out.extend(_flatten_strings(v, f"{prefix}.{k}"))
    elif isinstance(node, list):
        for i, item in enumerate(node):
            out.extend(_flatten_strings(item, f"{prefix}[{i}]"))
    return out


def _walk_manifest_strings(manifest: dict) -> list[tuple[str, str]]:
    """Yield (path, value) pairs for every in-scope manifest string."""
    out: list[tuple[str, str]] = []
    for plant in manifest.get("plants", []):
        pid = plant.get("plant_id", "?")
        for field in SCALAR_OR_LIST_FIELDS:
            v = plant.get(field)
            if isinstance(v, str):
                out.append((f"plants[{pid}].{field}", v))
            elif isinstance(v, list):
                for i, item in enumerate(v):
                    if isinstance(item, str):
                        out.append((f"plants[{pid}].{field}[{i}]", item))
        primary = plant.get("primary_answer") or {}
        specifics = primary.get("specifics") or {}
        out.extend(_flatten_strings(
            specifics, f"plants[{pid}].primary_answer.specifics"
        ))
        for j, alt in enumerate(plant.get("alternative_answers") or []):
            alt_specifics = (alt or {}).get("specifics") or {}
            out.extend(_flatten_strings(
                alt_specifics, f"plants[{pid}].alternative_answers[{j}].specifics"
            ))
    return out


def _substring_overlap(ident: str, value: str) -> str | None:
    """Return the matched substring if `ident` and `value` overlap >= MIN_MATCH_LEN.

    Checks both directions: `ident in value` and `value in ident`. The shorter
    string is the matched substring. Returns None if no overlap, if the matched
    substring is below MIN_MATCH_LEN, or if the matched substring is in the
    Swift-stdlib allowlist (universal background vocabulary, not corpus leakage).
    """
    matched: str | None = None
    if ident == value:
        matched = ident
    elif ident in value:
        matched = ident
    elif value in ident:
        matched = value
    if matched is None or len(matched) < MIN_MATCH_LEN:
        return None
    if matched in STDLIB_ALLOWLIST:
        return None
    return matched


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--prompt", type=Path, default=DEFAULT_PROMPT,
        help=f"v2 prompt path (default: {DEFAULT_PROMPT.relative_to(REPO_ROOT)})",
    )
    parser.add_argument(
        "--manifest", type=Path, default=DEFAULT_MANIFEST,
        help=f"plant manifest path (default: {DEFAULT_MANIFEST.relative_to(REPO_ROOT)})",
    )
    args = parser.parse_args()

    prompt_path: Path = args.prompt
    manifest_path: Path = args.manifest

    if not prompt_path.exists():
        print(f"ERROR: prompt not found: {prompt_path}", file=sys.stderr)
        return 2
    if not manifest_path.exists():
        print(f"ERROR: manifest not found: {manifest_path}", file=sys.stderr)
        return 2

    doc_text = prompt_path.read_text()
    block = _extract_worked_examples_block(doc_text, prompt_path)
    ids = _extract_identifiers(block)
    print(f"Loaded v2 prompt: {prompt_path}")
    print(f"  §2.1 block: {len(block)} chars, {len(ids)} identifier candidates")

    manifest = yaml.safe_load(manifest_path.read_text())
    haystack = _walk_manifest_strings(manifest)
    print(f"Loaded manifest: {manifest_path}")
    print(f"  in-scope string values: {len(haystack)}")
    print(f"  scanning under: source_type / source_files / expected_cluster_symbols / "
          f"primary_answer.specifics.* / alternative_answers[*].specifics.*")
    print(f"  min match length: {MIN_MATCH_LEN}")

    matches: list[tuple[str, str, str, str]] = []
    for ident in sorted(ids):
        for path, value in haystack:
            matched = _substring_overlap(ident, value)
            if matched is not None:
                matches.append((ident, path, value, matched))

    if matches:
        print(f"\nOVERLAP DETECTED — {len(matches)} match(es):")
        for ident, path, value, matched in matches:
            print(f"  identifier {ident!r} overlaps {path}: {value!r} (matched substring: {matched!r})")
        print("\nResolve by renaming the v2 worked-example identifiers before commit.")
        return 1

    print("\nOK — no overlap between v2 worked-example identifiers and in-scope manifest fields.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
