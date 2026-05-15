"""Phase D trial-harness internals.

Imported by `scripts/phase-d-harness.py` (CLI entry) and by the existing
`scripts/render-prompt.py` (which re-exports the normalization/rendering
helpers from `harness.prompt` to keep its CLI contract intact). Also imported
directly by the test suite in `pipeline/queries/_tests/`.

The modules split deliberately:
  - prompt.py     : extract / normalize / render. Pure functions.
  - extract.py    : fence-aware JSON-array extraction. Pure functions.
  - api.py        : Messages-API HTTP wrapper. Injectable transport.
  - gates.py      : per-rec token cap, per-condition $-budget, halt semantics.
  - checks.py     : §14.1 / §14.4 mid-run signature checks.
  - telemetry.py  : per-rec JSON writer, atomic, resume detection.

The CLI does the orchestration; everything testable lives behind pure
function boundaries so the bash/python tests can drive them without HTTP.
"""

from .extract import extract_recommendation_array
from .gates import (
    BudgetState,
    PER_REC_TOKEN_CAP,
    PER_CONDITION_BUDGET_USD,
    BUDGET_ALERT_FRACTION,
    cost_for_usage,
)
from .prompt import (
    extract_prompt_body,
    normalize_decl,
    normalize_pair_record,
    normalize_row,
    render,
)
from .telemetry import (
    sanitize_cluster_id,
    telemetry_path,
    write_telemetry,
    list_completed_cluster_ids,
)

__all__ = [
    "BudgetState",
    "PER_REC_TOKEN_CAP",
    "PER_CONDITION_BUDGET_USD",
    "BUDGET_ALERT_FRACTION",
    "cost_for_usage",
    "extract_prompt_body",
    "extract_recommendation_array",
    "list_completed_cluster_ids",
    "normalize_decl",
    "normalize_pair_record",
    "normalize_row",
    "render",
    "sanitize_cluster_id",
    "telemetry_path",
    "write_telemetry",
]
