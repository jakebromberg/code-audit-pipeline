"""Cost-control gates for Phase D trial execution.

Implements the §6.3 controls inline (not as a separate post-pass):

  1. Per-rec token cap (50K combined input+output). Recommendations whose
     usage crosses the cap are recorded with `error_class: "trial-overrun"`
     and the loop continues with the next row.

  2. Per-condition $-budget: $3.50 envelope. The harness alerts (logs a
     warning) at 80% of envelope and halts at 100%. The budget state is per
     condition (s1 vs s2), so a halt in one condition doesn't stop the other.

  3. Pricing snapshot ($3.00/$15.00 per MTok in/out for Sonnet 4.6, per
     `reproducibility.yaml > execution.api_pricing_snapshot`).

The §14.1 / §14.4 mid-run signature checks live in `checks.py`; this module
is purely about token+cost accounting.
"""

from __future__ import annotations

from dataclasses import dataclass, field

# Per-rec combined token cap. Crossings produce `error_class: "trial-overrun"`.
PER_REC_TOKEN_CAP = 50_000

# Per-condition $-budget envelope. Alert fires at fraction; halt fires at 1.0.
PER_CONDITION_BUDGET_USD = 3.50
BUDGET_ALERT_FRACTION = 0.80

# Pricing per `reproducibility.yaml > execution.api_pricing_snapshot`. The
# field name is unindexed because there's only one model in the pin matrix.
PRICE_INPUT_PER_MTOK_USD = 3.00
PRICE_OUTPUT_PER_MTOK_USD = 15.00


def cost_for_usage(input_tokens: int, output_tokens: int) -> float:
    """Compute USD cost from a (input, output) token pair at the pinned rates."""
    return (
        input_tokens / 1_000_000 * PRICE_INPUT_PER_MTOK_USD
        + output_tokens / 1_000_000 * PRICE_OUTPUT_PER_MTOK_USD
    )


@dataclass
class BudgetState:
    """Running cost tally for one (condition, trial) pair.

    `add(...)` returns one of:
      - "ok"        : under both thresholds; continue.
      - "alert"     : crossed the 80% alert line on this call; log a warning
                      and continue. Fires exactly once per state instance.
      - "halt"      : crossed (or already past) 100%; caller should stop the
                      run for this condition. Idempotent — subsequent calls
                      after a halt also return "halt".
    """

    budget_usd: float = PER_CONDITION_BUDGET_USD
    alert_fraction: float = BUDGET_ALERT_FRACTION
    spent_usd: float = 0.0
    alerted: bool = field(default=False)

    @property
    def alert_threshold_usd(self) -> float:
        return self.budget_usd * self.alert_fraction

    @property
    def is_halted(self) -> bool:
        return self.spent_usd >= self.budget_usd

    def add(self, cost_usd: float) -> str:
        if self.is_halted:
            return "halt"
        self.spent_usd += cost_usd
        if self.spent_usd >= self.budget_usd:
            return "halt"
        if not self.alerted and self.spent_usd >= self.alert_threshold_usd:
            self.alerted = True
            return "alert"
        return "ok"


def is_token_overrun(input_tokens: int, output_tokens: int) -> bool:
    """True if the combined token count exceeds the per-rec cap."""
    return (input_tokens + output_tokens) > PER_REC_TOKEN_CAP
