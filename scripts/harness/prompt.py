"""Cluster-row normalization and prompt rendering.

Lifted verbatim from `scripts/render-prompt.py` so the harness can call these
as library functions instead of shelling out to a Python subprocess per row.
The §3 normalized shape, the §1/§2 fence-extraction, and the final user-
message assembly all live here.

The companion `scripts/render-prompt.py` re-exports these and keeps its CLI
contract so the §5.3 dry-run path continues to work.
"""

from __future__ import annotations

import json
import re


def extract_prompt_body(doc_text: str) -> tuple[str, str]:
    """Return (instructions_block, specifics_block) verbatim from agent-prompt.md.

    §1 is the first plain fenced block. §2 is the json-tagged fenced block.
    """
    plain_blocks = re.findall(r"```\n(.*?)\n```", doc_text, re.DOTALL)
    json_blocks = re.findall(r"```json\n(.*?)\n```", doc_text, re.DOTALL)
    if not plain_blocks:
        raise ValueError("§1 instructions block not found in agent-prompt.md")
    if not json_blocks:
        raise ValueError("§2 specifics block not found in agent-prompt.md")
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
    """An `a` or `b` record from a pair-shaped query (pat-candidates, etc.)."""
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


# Queries whose row carries a `decls[]` list of N members.
_LIST_SHAPED_QUERIES = {
    "exact-duplicates", "name-collisions", "subset-pairs",
    "near-duplicates", "near-duplicates-any",
    "cross-package-shadows", "cross-package-shadows-any",
    "cross-package-shape-near-duplicates",
    "cross-package-shape-near-duplicates-any",
}

# Queries whose row is a function/file duplicate cluster, with decls[] or
# functions[] or files[] holding members.
_FUNCTION_DUPLICATE_QUERIES = {
    "function-duplicates", "function-duplicates-exact", "file-duplicates",
}

# Queries whose row is a pair (a/b), with optional differing-slot evidence.
# `function-duplicates-near` lives here (not in `_FUNCTION_DUPLICATE_QUERIES`)
# because the near-duplicate function-duplicates rows have an a/b pair shape,
# not the cluster `decls[]` shape used by the exact subtype. The two subtypes
# co-exist in `function-duplicates.jsonl` (see `generate-clusters-v7.sh`).
_PAIR_SHAPED_QUERIES = {
    "pat-candidates", "protocol-inheritance-candidates",
    "generic-struct-candidates", "generic-function-candidates",
    "default-impl-candidates",
    "function-duplicates-near",
}


def normalize_row(raw: dict) -> dict:
    """Project a raw cluster row into the §3 normalized shape.

    Raises ValueError for queries the normalizer doesn't cover yet (so a new
    query type can't silently produce a malformed prompt body).
    """
    query = raw.get("query", "unknown")
    cluster_id = raw.get("cluster_id", "")

    members: list[dict] = []
    # `function-duplicates-near` emits jaccard under the short key `jacc`; keep
    # the canonical `jaccard` key on the normalized row so downstream prompt
    # rendering and analysis can compare jaccard across queries uniformly.
    structural: dict = {
        "jaccard": raw.get("jaccard", raw.get("jacc")),
        "shared_field_count": raw.get("field_count") or raw.get("shared_field_count"),
        "differing_slots": None,
        "shared_ancestor": None,
    }

    if query in _LIST_SHAPED_QUERIES:
        for decl in raw.get("decls", []):
            members.append(normalize_decl(decl))
        if "jaccard" in raw:
            structural["jaccard"] = raw["jaccard"]

    elif query in _FUNCTION_DUPLICATE_QUERIES:
        for decl in raw.get("decls", raw.get("functions", raw.get("files", []))):
            members.append(normalize_decl(decl))

    elif query in _PAIR_SHAPED_QUERIES:
        for side in ("a", "b"):
            rec = raw.get(side)
            if rec is not None:
                members.append(normalize_pair_record(rec))
        a_slots = raw.get("a_slots") or []
        b_slots = raw.get("b_slots") or []
        if a_slots or b_slots:
            structural["differing_slots"] = [{"a": a_slots, "b": b_slots}]
        structural["shared_field_count"] = raw.get("field_count") or len(raw.get("shared_member_names", []))

    else:
        raise ValueError(f"normalizer not implemented for query: {query}")

    return {
        "cluster_id": cluster_id,
        "query": query,
        "members": members,
        "structural_evidence": structural,
    }


def render(instructions: str, specifics: str, normalized_row: dict) -> str:
    """Assemble the final user message body."""
    return (
        instructions
        + "\n\nPer-category specifics schemas:\n\n"
        + specifics
        + "\n\nCluster row (single-row JSON object):\n\n"
        + json.dumps(normalized_row, indent=2, sort_keys=True)
    )
