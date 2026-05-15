"""Mid-run §14.1 / §14.4 signature checks.

The methodology doc defines two failure-mode signatures that should be caught
mid-run rather than at Phase E:

  §14.1 — "substrate didn't help": the categorical distribution of agent
          recommendations doesn't materially differ between S1 and S2, OR the
          per-cluster S2 confidence is no higher than S1 confidence. Fires
          when both S1 and S2 partial logs are present.

  §14.4 — "batching variance": across trials of the same (condition, cluster)
          pair, the agent picks different categories more than a threshold of
          the time. Indicates the recommendation isn't stable under the
          temperature=0 pin and the experiment can't draw conclusions from
          single-trial counts.

Both checks run at the 25% completion mark of a (condition, trial) run. The
harness pauses for human review on a fire unless `--no-pause` is set.

The check thresholds and the exact distributions used are intentionally
conservative defaults — Phase E may re-calibrate after pilot data lands.
This module's contract is the function signature, not the threshold values.
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass


@dataclass
class CheckResult:
    signature: str  # "§14.1" or "§14.4"
    fired: bool
    reason: str


# §14.4: if across-trial category agreement is below this for the same cluster,
# fire the batching-variance signature. 0.67 means "at least two of three trials
# agree on category" when n_trials=3.
TRIAL_AGREEMENT_FLOOR = 0.67

# §14.1: if S2 mean confidence is no higher than S1 mean confidence by at least
# this margin, fire the substrate-didn't-help signature.
S2_OVER_S1_CONFIDENCE_FLOOR = 0.03


def check_batching_variance(
    per_cluster_categories: dict[str, list[str]],
    *,
    agreement_floor: float = TRIAL_AGREEMENT_FLOOR,
) -> CheckResult:
    """§14.4: cross-trial category-agreement check.

    `per_cluster_categories` maps cluster_id -> [category_t1, category_t2, ...].
    Fires if the fraction of clusters whose mode-category share is >=
    `agreement_floor` is itself below `agreement_floor`.
    """
    if not per_cluster_categories:
        return CheckResult("§14.4", False, "no clusters yet — check skipped")
    stable = 0
    for cats in per_cluster_categories.values():
        if not cats:
            continue
        top = Counter(cats).most_common(1)[0][1]
        if top / len(cats) >= agreement_floor:
            stable += 1
    fraction_stable = stable / len(per_cluster_categories)
    if fraction_stable < agreement_floor:
        return CheckResult(
            "§14.4",
            True,
            f"only {fraction_stable:.0%} of clusters had agreement >= {agreement_floor:.0%} across trials",
        )
    return CheckResult("§14.4", False, f"{fraction_stable:.0%} of clusters agree across trials (>= floor)")


def check_substrate_helped(
    s1_confidences: list[float],
    s2_confidences: list[float],
    *,
    margin: float = S2_OVER_S1_CONFIDENCE_FLOOR,
) -> CheckResult:
    """§14.1: did S2's richer cluster signal raise mean confidence over S1?

    Fires if `mean(s2) - mean(s1) < margin`. Skipped when either list is empty.
    """
    if not s1_confidences or not s2_confidences:
        return CheckResult("§14.1", False, "one condition has no data yet — check skipped")
    s1_mean = sum(s1_confidences) / len(s1_confidences)
    s2_mean = sum(s2_confidences) / len(s2_confidences)
    delta = s2_mean - s1_mean
    if delta < margin:
        return CheckResult(
            "§14.1",
            True,
            f"S2-S1 mean confidence delta = {delta:+.3f} (< required margin {margin:+.3f})",
        )
    return CheckResult("§14.1", False, f"S2-S1 mean confidence delta = {delta:+.3f} (>= margin)")


def should_run_midrun_checks(rows_done: int, rows_total: int, fraction: float = 0.25) -> bool:
    """True when the harness has just crossed the `fraction` completion mark.

    Designed to fire exactly once per run: caller checks before incrementing
    rows_done. The condition `rows_done == int(rows_total * fraction)` is the
    on-the-mark fire; using `>=` would re-fire forever once past.
    """
    if rows_total <= 0:
        return False
    target = max(1, int(rows_total * fraction))
    return rows_done == target
