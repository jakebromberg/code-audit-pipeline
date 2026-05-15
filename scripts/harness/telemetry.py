"""Per-recommendation telemetry writer with resume support.

Layout under the output root (default
`experiments/v7-refactor-recommendation/trial-logs/`):

  <out>/<condition>/<trial>/<sanitized-cluster-id>.json   # one per row
  <out>/raw/<condition>/<trial>/<sanitized-cluster-id>.json  # full API body

Resume semantics: the harness lists `<out>/<condition>/<trial>/*.json` at
start, builds the set of sanitized cluster_ids already covered, and skips
any row whose sanitized id is in that set. So re-running with the same
out-dir continues from the first missing row.

Cluster ids carry colons and other punctuation (e.g.,
`pat-candidates:Foo:Bar:packageX`) — `sanitize_cluster_id` maps to a
filesystem-safe form by replacing every char outside `[A-Za-z0-9._-]` with
`_`. The mapping is deterministic and stable, so resume detection works
across runs.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
from typing import Iterable

_UNSAFE_RE = re.compile(r"[^A-Za-z0-9._-]+")

# macOS (APFS/HFS+) and most Linux filesystems cap a single path component at
# 255 bytes. Atomic-write uses tempfile.NamedTemporaryFile with prefix
# `.tmp-XXXXXXXX` (13 chars) + suffix `.json` (5 chars) = 18 chars of
# scaffolding, so the sanitized stem must stay below 237 to be safely
# rename-able. We pick 195 to leave a comfortable margin and to keep
# `_SAFE_STEM_LIMIT > 206` (the longest stem written before this cap was
# introduced) so already-completed telemetry files retain their original
# stems — resume detection stays valid across this fix.
_SAFE_STEM_LIMIT = 220
_TRUNCATED_PREFIX_LEN = 175  # leaves room for "__h" + 16-hex-char digest = 19


def sanitize_cluster_id(cluster_id: str) -> str:
    """Make a cluster_id safe to use as a filename. Empty → 'EMPTY'.

    Most ids fit comfortably under the filesystem's 255-byte filename limit
    once the unsafe-char remap is applied. The two-decl shape-near-duplicates
    queries are the outlier: each side carries a full file-path:line:type-name
    triple, and the spliced cluster id can run past 260 chars. For ids whose
    sanitized form exceeds `_SAFE_STEM_LIMIT`, we keep a readable prefix and
    append a stable hash so distinct overlong ids still produce distinct
    stems (resume detection requires injectivity).
    """
    cleaned = _UNSAFE_RE.sub("_", cluster_id).strip("_")
    if not cleaned:
        return "EMPTY"
    if len(cleaned) <= _SAFE_STEM_LIMIT:
        return cleaned
    digest = hashlib.sha256(cleaned.encode("utf-8")).hexdigest()[:16]
    return f"{cleaned[:_TRUNCATED_PREFIX_LEN]}__h{digest}"


def telemetry_path(out_root: Path, condition: str, trial: int, cluster_id: str) -> Path:
    """Return the per-recommendation telemetry file path."""
    return out_root / condition / f"trial{trial}" / f"{sanitize_cluster_id(cluster_id)}.json"


def raw_response_path(out_root: Path, condition: str, trial: int, cluster_id: str) -> Path:
    """Return the path for the verbatim API response dump."""
    return out_root / "raw" / condition / f"trial{trial}" / f"{sanitize_cluster_id(cluster_id)}.json"


def _atomic_write_json(path: Path, payload: dict) -> None:
    """Write `payload` to `path` atomically (tmp + rename)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", dir=path.parent, prefix=".tmp-", suffix=".json", delete=False
    ) as tmp:
        json.dump(payload, tmp, indent=2, sort_keys=True)
        tmp.write("\n")
        tmp_name = tmp.name
    os.replace(tmp_name, path)


def write_telemetry(
    out_root: Path,
    condition: str,
    trial: int,
    cluster_id: str,
    *,
    query: str,
    row_index: int,
    input_tokens: int,
    output_tokens: int,
    latency_ms: int,
    cost_usd: float,
    error_class: str | None,
    response_model: str | None,
    response_id: str | None,
    raw_response: dict | None,
) -> Path:
    """Write the per-rec telemetry JSON and (if present) the raw API body.

    Returns the path of the telemetry record.
    """
    record = {
        "cluster_id": cluster_id,
        "condition": condition,
        "trial": trial,
        "query": query,
        "row_index": row_index,
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
        "latency_ms": latency_ms,
        "cost_usd": cost_usd,
        "error_class": error_class,
        "response_model": response_model,
        "response_id": response_id,
    }
    if raw_response is not None:
        rp = raw_response_path(out_root, condition, trial, cluster_id)
        _atomic_write_json(rp, raw_response)
        try:
            record["raw_response_path"] = str(rp.relative_to(out_root))
        except ValueError:
            record["raw_response_path"] = str(rp)
    else:
        record["raw_response_path"] = None

    tp = telemetry_path(out_root, condition, trial, cluster_id)
    _atomic_write_json(tp, record)
    return tp


def list_completed_cluster_ids(out_root: Path, condition: str, trial: int) -> set[str]:
    """Return the set of sanitized cluster_ids that already have telemetry."""
    trial_dir = out_root / condition / f"trial{trial}"
    if not trial_dir.exists():
        return set()
    return {p.stem for p in trial_dir.glob("*.json") if p.is_file()}


def filter_incomplete(
    rows: Iterable[tuple[int, dict]],
    completed: set[str],
) -> list[tuple[int, dict]]:
    """Yield (row_index, raw_row) pairs whose sanitized cluster_id is NOT in `completed`."""
    out: list[tuple[int, dict]] = []
    for idx, row in rows:
        cid = row.get("cluster_id", "")
        if sanitize_cluster_id(cid) in completed:
            continue
        out.append((idx, row))
    return out
