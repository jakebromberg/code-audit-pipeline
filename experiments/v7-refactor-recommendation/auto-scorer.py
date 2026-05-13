#!/usr/bin/env python3
"""Auto-score a single refactor recommendation against the V7 plant manifest.

Implements the methodology §8 scoring rubric in machine-readable form. Reads
`rubric.yaml` + `plant-manifest.yaml` and emits a numeric score in
{-0.5, 0.0, 0.3, 0.5, 0.7, 1.0} for a given recommendation JSON. Recommendations
that do not auto-score (per the §8 decision rule — see below) emit a
`panel_route` sentinel instead of a number.

Decision rule (methodology §8):

  Case 1 — primary match. recommendation.category == primary.category AND
           specifics-tolerance satisfied AND all `rationale_must_cite`
           substrings appear in recommendation.rationale. Score 1.0.
  Case 1' — primary match but missing citation. Same as 1 minus the
            rationale check. Score per `weak_rationale_policy` (default 0.5).
  Case 2 — alternative match. recommendation.category appears in
           `alternative_answers[*].category`. Score = that entry's weight
           (or 0.7 if the rubric's bucket is requested instead). The §8 table
           pins alternative at 0.7; the manifest entry's `weight` can lower
           it (e.g., 0.5 or 0.4 for less-idiomatic alternatives).
  Case 3 — wrong-answer enumeration. recommendation.category appears in
           `wrong_answers[*].category`. Score 0.0 (or -0.5 if the wrong
           answer would break the code — flagged in the manifest via
           wrong-answer note prose; this MVP scorer treats `subclass-lift`
           on a category whose members are structs/enums/protocols as a
           breaking action.).
  Case 4 — restraint plant. Restraint plants score per `restraint_scores`
           in the rubric. Action recommendations score 0.0; `no-action`
           with grounded rationale scores 1.0; ungrounded `no-action`
           scores 0.5.
  Case 5 — adjacent category. recommendation.category is in the
           `adjacent_categories` map relative to primary.category. Score 0.3.
  Case 6 — everything else: `panel_route` (the auto-scorer does not commit
           a number; methodology §8 walks the panel-routed case in §20.5).

`category == "other"` always routes to panel (case 6).

Usage
-----

    # Score a single recommendation:
    python3 auto-scorer.py --recommendation rec.json
    # → emits {"plant_id": "...", "score": 1.0, "match": "primary_match_full", ...}

    # Dry-run against §20.1–20.5 worked examples (regression check):
    python3 auto-scorer.py --dry-run
    # → exits 0 if all 5 worked examples reproduce their asserted scores

The MVP scorer is deliberately minimal: substring presence on rationale text,
key-set superset check on specifics, structural comparison against manifest
fields the manifest declares. The 10–20% grounding-audit sample (per §8) is
the human counterweight to substring-matching's gameability — it is not
implemented here.

Exit code: 0 on success; nonzero on dry-run failure or input error.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
DEFAULT_RUBRIC = HERE / "rubric.yaml"
DEFAULT_MANIFEST = HERE / "plant-manifest.yaml"

PANEL_ROUTE = "panel_route"


@dataclass
class ScoreResult:
    """Auto-scorer output for one recommendation.

    `score` is either a float in {-0.5, 0.0, 0.3, 0.5, 0.7, 1.0, or other
    manifest-supplied alternative weights} or the string `panel_route`. The
    `match` field names which §8 case fired; `notes` is free-form prose for
    diagnostics.
    """

    plant_id: str
    score: float | str
    match: str
    notes: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "plant_id": self.plant_id,
            "score": self.score,
            "match": self.match,
            "notes": self.notes,
        }


def load_rubric(path: Path) -> dict:
    with path.open() as f:
        return yaml.safe_load(f)


def load_manifest(path: Path) -> dict[str, dict]:
    """Index the manifest by plant_id for O(1) lookup."""
    with path.open() as f:
        doc = yaml.safe_load(f)
    return {p["plant_id"]: p for p in doc["plants"]}


def _rationale_cites_all(rationale: str, must_cite: list[str]) -> tuple[bool, list[str]]:
    """Substring-presence check per methodology §8 'Citation-check implementation'.

    Returns (all_present, missing_substrings). Case-sensitive: the manifest's
    `rationale_must_cite` substrings are symbol names and key phrases that
    should appear verbatim in the rationale.
    """
    missing = [s for s in must_cite if s not in rationale]
    return (len(missing) == 0, missing)


def _specifics_keys_match(rec_specifics: dict, schema_required: list[str]) -> tuple[bool, list[str]]:
    """Closed-set key check: the recommendation's specifics keys must equal
    the schema's required set. Returns (ok, problem_descriptions)."""
    rec_keys = set(rec_specifics.keys()) if isinstance(rec_specifics, dict) else set()
    required = set(schema_required)
    missing = required - rec_keys
    extra = rec_keys - required
    problems = []
    if missing:
        problems.append(f"missing keys: {sorted(missing)}")
    if extra:
        problems.append(f"unknown keys: {sorted(extra)}")
    return (not problems, problems)


def _is_adjacent(rubric: dict, primary_cat: str, rec_cat: str) -> bool:
    """Check adjacency via the rubric's `adjacent_categories` undirected pairs."""
    pairs = rubric.get("adjacent_categories", [])
    for pair in pairs:
        if len(pair) == 2 and {pair[0], pair[1]} == {primary_cat, rec_cat}:
            return True
    return False


def _find_alternative(plant: dict, rec_cat: str) -> dict | None:
    """Return the first `alternative_answers` entry whose category matches, else None."""
    for alt in plant.get("alternative_answers", []) or []:
        if alt.get("category") == rec_cat:
            return alt
    return None


def _find_wrong_answer(plant: dict, rec_cat: str) -> dict | None:
    """Return the first `wrong_answers` entry whose category matches, else None."""
    for wrong in plant.get("wrong_answers", []) or []:
        if wrong.get("category") == rec_cat:
            return wrong
    return None


def _is_breaking_action(rec_cat: str, wrong_entry: dict | None) -> bool:
    """Heuristic for §8's -0.5 row: recommended-action would break the code.

    The MVP heuristic: if the wrong-answer entry's note mentions Swift-level
    error phrasing (protocols-don't-subclass, structs-don't-subclass,
    enums-don't-subclass, would-be-a-Swift-level-error, would-be-a-language-level-error),
    treat it as a breaking action. This catches §20-style cases where the
    agent recommends subclass-lift on protocol/struct/enum participants.
    """
    if wrong_entry is None:
        return False
    note = (wrong_entry.get("note") or "").lower()
    breaking_phrases = (
        "swift-level error",
        "language-level error",
        "don't subclass",
        "cannot be subclassed",
        "cannot subclass",
    )
    return any(phrase in note for phrase in breaking_phrases)


def score_recommendation(
    recommendation: dict, plant: dict, rubric: dict
) -> ScoreResult:
    """Score one recommendation against one plant. Implements §8's decision rule.

    `recommendation` is the model's structured output for one cluster row.
    `plant` is the manifest entry whose plant_id matches the recommendation's
    plant_id. `rubric` is the loaded rubric.yaml.
    """
    plant_id = plant.get("plant_id", "<unknown>")
    rec_cat = recommendation.get("category")
    rec_specifics = recommendation.get("specifics") or {}
    rec_rationale = recommendation.get("rationale") or ""

    primary = plant.get("primary_answer") or {}
    primary_cat = primary.get("category")
    primary_specifics_required = (
        rubric.get("specifics_schemas", {}).get(primary_cat, {}).get("required", [])
    )
    must_cite = primary.get("rationale_must_cite") or []

    is_restraint = bool(plant.get("restraint"))

    # ── Case 4: restraint plant (different scoring table) ─────────────────
    if is_restraint:
        if rec_cat == "no-action":
            grounded, missing = _rationale_cites_all(rec_rationale, must_cite)
            if grounded:
                return ScoreResult(
                    plant_id, 1.0, "no_action_grounded",
                    notes=["restraint plant; cited all required signals"],
                )
            return ScoreResult(
                plant_id, 0.5, "no_action_ungrounded",
                notes=[f"restraint plant; missing citations: {missing}"],
            )
        # any action recommendation on a restraint is a false positive
        return ScoreResult(
            plant_id, 0.0, "restraint_false_positive",
            notes=[f"restraint plant; recommended action category={rec_cat!r}"],
        )

    # ── Case "other" always routes to panel ───────────────────────────────
    if rec_cat == "other":
        return ScoreResult(
            plant_id, PANEL_ROUTE, "other_routes_to_panel",
            notes=["category='other' per §8 decision rule"],
        )

    # ── Case 1 / 1': primary match ────────────────────────────────────────
    if rec_cat == primary_cat:
        specifics_ok, specifics_problems = _specifics_keys_match(
            rec_specifics, primary_specifics_required
        )
        grounded, missing_citations = _rationale_cites_all(rec_rationale, must_cite)
        if specifics_ok and grounded:
            return ScoreResult(
                plant_id, 1.0, "primary_match_full",
                notes=["all conditions met"],
            )
        if specifics_ok and not grounded:
            # Case 1': weak rationale. Apply weak_rationale_policy.
            policy = rubric.get("weak_rationale_policy", "auto-score-0.5")
            if policy == "auto-score-0.5":
                return ScoreResult(
                    plant_id, 0.5, "primary_match_weak_rationale",
                    notes=[f"missing required citations: {missing_citations}"],
                )
            return ScoreResult(
                plant_id, PANEL_ROUTE, "primary_match_weak_rationale_panel",
                notes=[
                    f"missing required citations: {missing_citations}",
                    f"weak_rationale_policy={policy}",
                ],
            )
        # Right category, wrong specifics — §8 0.5 bucket.
        return ScoreResult(
            plant_id, 0.5, "primary_category_wrong_specifics",
            notes=specifics_problems,
        )

    # ── Case 2: alternative-answer match ──────────────────────────────────
    alt = _find_alternative(plant, rec_cat)
    if alt is not None:
        # §8 table pins alternative at 0.7; per-manifest weight may lower it.
        weight = alt.get("weight", 0.7)
        return ScoreResult(
            plant_id, float(weight), "alternative_match",
            notes=[f"matched alternative_answers entry weight={weight}"],
        )

    # ── Case 3 / -0.5: wrong-answer enumeration ──────────────────────────
    wrong = _find_wrong_answer(plant, rec_cat)
    if wrong is not None:
        if _is_breaking_action(rec_cat, wrong):
            return ScoreResult(
                plant_id, -0.5, "breaking_action",
                notes=[f"wrong_answers entry flagged as Swift-level error: {wrong.get('note')!r}"],
            )
        return ScoreResult(
            plant_id, 0.0, "wrong_category_enumerated",
            notes=[f"matched wrong_answers entry: {wrong.get('note')!r}"],
        )

    # ── Case 5: adjacent category (§8 0.3 bucket) ─────────────────────────
    if _is_adjacent(rubric, primary_cat, rec_cat):
        return ScoreResult(
            plant_id, 0.3, "adjacent_wrong_category",
            notes=[f"category {rec_cat!r} is adjacent to primary {primary_cat!r}"],
        )

    # ── Fallback: wrong category, not enumerated, not adjacent ────────────
    # §8: "Wrong category; hallucinated rationale; no engagement with cluster
    # evidence" → 0.0. Without panel review we can't distinguish "wrong but
    # honestly grounded" from "hallucinated", so we conservatively score 0.0.
    return ScoreResult(
        plant_id, 0.0, "wrong_category_not_enumerated",
        notes=[f"category {rec_cat!r} not in primary, alternatives, wrong-answers, or adjacency map"],
    )


# ─── Dry-run fixtures: methodology §20.1–20.5 worked examples ─────────────
#
# Each fixture pairs a recommendation JSON (verbatim from §20) with the
# expected score the methodology asserts. The dry-run subcommand runs the
# auto-scorer and exits 0 iff every fixture matches its asserted score.
#
# Note on plant-id binding: §20 says "Plant 4.1's manifest entry is in §8."
# That refers to the §8 hypothetical example block (the TrackContainer /
# ShowContainer pair), NOT the real `plant-manifest.yaml`'s 4.1 entry,
# which was filled in later with a different real-substrate pair. The
# dry-run therefore constructs the §8 abstract plant entries inline as
# `INLINE_PLANTS` and uses them for the §20.1–20.3 worked examples; §20.4
# and §20.5 use real manifest entries (1R and 3.1 respectively) because
# those examples are bound to manifest plants directly.
#
# §20.5 ("panel-routed novel answer") is asserted to route to panel
# (`category == 'other'`); the auto-scorer emits the `panel_route` sentinel.
# The methodology then describes a panel returning 0.7, but that is human
# work and not asserted as an auto-scorer responsibility — we only assert
# the routing decision here.

# The §8 example block, reified as a plant entry for §20.1–20.3 to score
# against. Matches the YAML in methodology §8 verbatim (modulo the YAML→dict
# conversion).
INLINE_PLANTS = {
    "4.1-§8-example": {
        "plant_id": "4.1-§8-example",
        "category": "pat-introduction",
        "primary_answer": {
            "category": "pat-introduction",
            "specifics": {
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            "rationale_must_cite": ["TrackContainer", "ShowContainer", "differs at Item"],
        },
        "alternative_answers": [
            {
                "category": "generic-parameterization",
                "weight": 0.7,
                "note": "Two protocols become one generic struct — defensible but less idiomatic for the protocol-shaped case.",
            },
            {
                "category": "extract-to-common",
                "weight": 0.4,
                "note": "Extracting both without PAT misses the abstraction but isn't actively wrong.",
            },
        ],
        "wrong_answers": [
            {
                "category": "no-action",
                "note": "Two protocols differing only by type slot are PAT-shaped; recommending no-action is a false negative.",
            },
            {
                "category": "subclass-lift",
                "note": "Protocols don't subclass; this would be a Swift-level error.",
            },
        ],
        "restraint": False,
    },
}


WORKED_EXAMPLES = [
    {
        "label": "§20.1 canonical-strong: Plant 4.1 (§8 example) exemplary",
        "plant_id": "4.1-§8-example",
        "recommendation": {
            "cluster_id": "pat-candidates:TrackContainer+ShowContainer",
            "category": "pat-introduction",
            "specifics": {
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            "rationale": (
                "TrackContainer and ShowContainer have identical method shapes "
                "(var item, func reload() async) and differ only at the type of "
                "`item`. This is the textbook PAT signature: a protocol with one "
                "slot that varies per conformer. Introducing `protocol Container "
                "{ associatedtype Item; var item: Item { get }; func reload() async }` "
                "lets both protocols collapse to one, with conformers binding Item "
                "to Track or Show. The cluster row shows the pair differs at Item."
            ),
            "evidence_quote": (
                "TrackContainer { var item: Track; func reload() async } | "
                "ShowContainer { var item: Show; func reload() async } | differs at Item"
            ),
            "alternative": None,
            "confidence": 0.9,
        },
        "expected_score": 1.0,
        "expected_match": "primary_match_full",
    },
    {
        "label": "§20.2 canonical-weak-rationale: Plant 4.1 (§8 example), missing 'differs at Item' citation",
        "plant_id": "4.1-§8-example",
        "recommendation": {
            "cluster_id": "pat-candidates:TrackContainer+ShowContainer",
            "category": "pat-introduction",
            "specifics": {
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            "rationale": "These two protocols can be combined with a PAT.",
            "evidence_quote": "TrackContainer | ShowContainer",
            "alternative": None,
            "confidence": 0.8,
        },
        "expected_score": 0.5,
        "expected_match": "primary_match_weak_rationale",
    },
    {
        "label": "§20.3 alternative-answer match: Plant 4.1 (§8 example), generic-parameterization",
        "plant_id": "4.1-§8-example",
        "recommendation": {
            "cluster_id": "pat-candidates:TrackContainer+ShowContainer",
            "category": "generic-parameterization",
            "specifics": {
                "generic_kind": "struct",
                "type_params": [{"name": "Item", "constraint": None}],
                "new_name": "Container",
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            "rationale": (
                "TrackContainer and ShowContainer have parallel structure differing "
                "at Item. Replacing both with `struct Container<Item> { let item: "
                "Item; func reload() async { ... } }` collapses them to one generic "
                "value type."
            ),
            "evidence_quote": (
                "TrackContainer { var item: Track } | ShowContainer { var item: Show }"
            ),
            "alternative": None,
            "confidence": 0.7,
        },
        "expected_score": 0.7,
        "expected_match": "alternative_match",
    },
    {
        "label": "§20.4 restraint false positive: Plant 1R, recommended action",
        "plant_id": "1R",
        "recommendation": {
            "cluster_id": "exact-duplicates:CacheClientConfig+CacheClientConfigMock",
            "category": "extract-to-common",
            "specifics": {
                "target_package": "Shared/Core",
                "type_name": "ClientConfig",
                "remove_from": [
                    "Shared/Caching/Sources/Caching/_Plant_CacheClientConfig.swift",
                    "Shared/Caching/Tests/CachingTests/_Plant_CacheClientConfigMock.swift",
                ],
            },
            "rationale": (
                "Both files declare an identical ClientConfig shape. Extracting "
                "to Shared/Core and importing from both eliminates the duplication."
            ),
            "evidence_quote": (
                "CacheClientConfig { url, timeout, retries, headers } | "
                "CacheClientConfigMock { url, timeout, retries, headers }"
            ),
            "alternative": None,
            "confidence": 0.85,
        },
        "expected_score": 0.0,
        "expected_match": "restraint_false_positive",
    },
    {
        "label": "§20.5 panel-routed: Plant 3.1, 'other' category",
        "plant_id": "3.1",
        "recommendation": {
            "cluster_id": "default-impl-candidates:Loggable",
            "category": "other",
            "specifics": {
                "proposed_action": (
                    "Wrap logDebugInfo() in a free function `logDebugInfo(_ obj: "
                    "Loggable)` in the Logger package; deprecate the protocol "
                    "method, route through the free function."
                ),
                "why_no_category_fits": (
                    "The three conformers don't share enough state to justify a "
                    "default impl on the protocol — the bodies are identical because "
                    "the work is type-erased. A free function over the protocol's "
                    "surface is more honest about the lack of polymorphism."
                ),
            },
            "rationale": (
                "logDebugInfo()'s body in all three conformers calls only "
                "protocol-surface methods. A default impl works mechanically "
                "but encodes a polymorphism that isn't there."
            ),
            "evidence_quote": (
                "All three logDebugInfo() bodies: { self.log(.debug, info: self.diagnosticInfo) }"
            ),
            "alternative": {
                "category": "default-implementation",
                "specifics": {"protocol": "Loggable", "method": "logDebugInfo()"},
                "rationale": "Standard Swift idiom; less expressive about the type-erasure but lower-friction.",
            },
            "confidence": 0.6,
        },
        "expected_score": PANEL_ROUTE,
        "expected_match": "other_routes_to_panel",
    },
]


def run_dry_run(rubric: dict, manifest: dict[str, dict]) -> int:
    """Verify §20.1–20.5 worked examples reproduce their asserted scores.

    Methodology §20 is the spec; this is the regression test. Exits 0 if all
    five examples match; nonzero (and prints diffs) otherwise. The dry-run is
    the auto-scorer's TDD harness — changes to the matching logic that break
    any §20 example are caught here.
    """
    failures = []
    for ex in WORKED_EXAMPLES:
        plant = INLINE_PLANTS.get(ex["plant_id"]) or manifest.get(ex["plant_id"])
        if plant is None:
            failures.append(f"{ex['label']}: plant_id {ex['plant_id']!r} not in manifest")
            continue
        result = score_recommendation(ex["recommendation"], plant, rubric)
        ok = (result.score == ex["expected_score"]) and (
            result.match == ex["expected_match"]
        )
        status = "PASS" if ok else "FAIL"
        print(
            f"[{status}] {ex['label']}: "
            f"score={result.score!r} (expected {ex['expected_score']!r}); "
            f"match={result.match!r} (expected {ex['expected_match']!r})"
        )
        if not ok:
            for note in result.notes:
                print(f"    note: {note}")
            failures.append(ex["label"])
    if failures:
        print(f"\nFAIL: {len(failures)}/{len(WORKED_EXAMPLES)} worked examples did not reproduce", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print(f"\nOK: all {len(WORKED_EXAMPLES)} §20 worked examples reproduce their asserted scores")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--rubric", type=Path, default=DEFAULT_RUBRIC, help="Path to rubric.yaml"
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_MANIFEST,
        help="Path to plant-manifest.yaml",
    )
    parser.add_argument(
        "--recommendation",
        type=Path,
        help="Path to a single recommendation JSON file to score (requires --plant-id)",
    )
    parser.add_argument(
        "--plant-id",
        help="Plant ID to score the recommendation against (when --recommendation is set)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Run methodology §20.1–20.5 worked-example regression check",
    )
    args = parser.parse_args()

    rubric = load_rubric(args.rubric)
    manifest = load_manifest(args.manifest)

    if args.dry_run:
        return run_dry_run(rubric, manifest)

    if args.recommendation is None or args.plant_id is None:
        parser.error("either --dry-run or (--recommendation AND --plant-id) is required")

    with args.recommendation.open() as f:
        rec = json.load(f)
    plant = manifest.get(args.plant_id)
    if plant is None:
        print(f"error: plant_id {args.plant_id!r} not in manifest", file=sys.stderr)
        return 1
    result = score_recommendation(rec, plant, rubric)
    print(json.dumps(result.to_dict(), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
