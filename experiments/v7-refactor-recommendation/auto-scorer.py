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

Scope notes:

  • Specifics matching is VALUE-AWARE (round 2, issue #35 / PR closing the
    `primary_match_specifics_*` paths). Case 1 fires when the recommendation's
    `specifics` has all keys required by `rubric.specifics_schemas[category]`
    AND the values structurally equal `plant.primary_answer.specifics` (lists
    as multisets; dicts structurally; scalars by `==`). Missing required keys
    panel-route as `primary_match_specifics_missing_keys`; value mismatches
    panel-route as `primary_match_specifics_outside_tolerance`. The plant's
    `specifics_tolerance` flags are NOT evaluated by the scorer; they are
    surfaced as panel-guidance notes (`tolerance_flag: {key}={value}`) per
    methodology §8 lines 626–631 — out-of-tolerance specifics route to panel
    and the panel applies the flags when rating. See
    `plans/v7-round2-value-aware-specifics-plan.md` and the round-2 entry in
    `rubric-modifications.md` for the design rationale and projection data.
  • Extras-in-specifics are tolerated by the scorer (superset semantics: a
    recommendation may carry extra keys beyond `required` and still match).
    The validator (`validate-manifest.py`) stays closed-set — extras there
    indicate manifest drift.
  • Rationale citation is case-sensitive substring presence. `must_cite`
    strings are symbol names and key phrases that should appear verbatim;
    normalizing case would let "trackcontainer" satisfy "TrackContainer".
  • The breaking-action (-0.5) heuristic reads wrong-answer note prose for
    Swift-error phrasing; a structured `would_break: true` field on
    `wrong_answers` entries would be more robust but is not the MVP shape.
  • The 10–20% grounding-audit sample (per §8) is the human counterweight to
    substring-match gameability — it is not implemented here.

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
    """Superset key check: the recommendation's specifics keys must include
    every key in the schema's `required` set. Extra keys are tolerated —
    an LLM that emits additional metadata (e.g., a nested `notes` field)
    should not lose a Case-1 match. Closed-set drift detection is the
    validator's job, not the scorer's. Returns (ok, problem_descriptions).
    """
    rec_keys = set(rec_specifics.keys()) if isinstance(rec_specifics, dict) else set()
    required = set(schema_required)
    missing = required - rec_keys
    problems = []
    if missing:
        problems.append(f"missing keys: {sorted(missing)}")
    return (not problems, problems)


def _values_structurally_equal(a, b) -> bool:
    """Verbatim structural equality used by `_specifics_values_match`.

    Lists are compared as multisets (order-independent; each element of `a`
    must structurally equal a unique element of `b`). Dicts are compared by
    key-set equality plus recursive value equality. Scalars by `==`. Returns
    True iff `a` and `b` are structurally identical under these rules.

    Note on asymmetry with top-level specifics matching: this comparator
    enforces strict key-set equality on nested dicts (a nested rec dict with
    rec-side extras returns False). The top-level superset-tolerance for
    extras lives in `_specifics_values_match`, which iterates only the
    rubric's `required` keys; this comparator's stricter rule applies to
    *nested* dicts inside specifics values (e.g., `type_params[i]`). Manifest
    authors pin nested shapes precisely, so a rec emitting extra fields
    inside a nested dict is treated as out-of-tolerance and panel-routes.
    """
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            return False
        remaining = list(b)
        for ae in a:
            for i, be in enumerate(remaining):
                if _values_structurally_equal(ae, be):
                    del remaining[i]
                    break
            else:
                return False
        return True
    if isinstance(a, dict) and isinstance(b, dict):
        if a.keys() != b.keys():
            return False
        return all(_values_structurally_equal(a[k], b[k]) for k in a)
    return a == b


def _specifics_values_match(
    rec_specifics: dict,
    primary_specifics: dict,
    required_keys: list[str],
    specifics_alternatives: dict | None = None,
) -> tuple[bool, list[str], bool]:
    """Verbatim value comparison for each required key, with fall-through to
    blessed alternatives per the H0b sub-experiment rubric loosening (plan
    `v7-h0b-rubric-loosening-plan.md` §3.4).

    Scalars: == equality. Lists: multiset equality (order-independent; see
    `_values_structurally_equal`). Dicts: structural equality (recursive).
    Type mismatches (e.g., manifest expects list, rec provides string) are
    mismatches, surfaced through the `!r` repr in the problem string.

    Per-key behavior when the manifest doesn't pre-register a value
    (`primary_specifics` is missing this key OR has it set to None): the
    scorer treats the manifest as not constraining that key's value and
    skips the comparison. Real production manifests pre-register values for
    every required key (validate-manifest.py rule 9.d enforces non-empty
    specifics + rule 10.a enforces key superset); the relaxed precondition
    exists so synthetic test fixtures with minimal plant shapes still
    exercise the keys-only code path.

    H0b fall-through: when the verbatim check fails on key K, the scorer
    re-checks `rec_val` against each entry of
    `specifics_alternatives.get(K, [])` using `_values_structurally_equal`.
    A blessed-alternative match counts as a match for that key and flips
    `any_alternative_used`. Plants without `specifics_alternatives` reduce
    to pre-H0b verbatim-only behavior.

    Returns (ok, problem_descriptions, any_alternative_used). The third
    element is True iff at least one required key was satisfied via a
    blessed alternative rather than verbatim — the caller uses it to choose
    between `primary_match_full` and
    `primary_match_specifics_blessed_alternative` labels.

    Precondition: caller has confirmed every key in `required_keys` is
    present in `rec_specifics` (via `_specifics_keys_match`).
    """
    problems: list[str] = []
    any_alternative_used = False
    alts_by_key = specifics_alternatives or {}
    for key in required_keys:
        if key not in primary_specifics:
            continue  # manifest doesn't constrain this key; vacuously in-tolerance
        manifest_val = primary_specifics[key]
        if manifest_val is None:
            continue  # explicit "no value" sentinel in manifest; same as missing
        rec_val = rec_specifics[key]
        if _values_structurally_equal(manifest_val, rec_val):
            continue  # verbatim hit
        alternatives = alts_by_key.get(key, []) or []
        if any(_values_structurally_equal(alt, rec_val) for alt in alternatives):
            any_alternative_used = True
            continue  # H0b blessed-alternative hit
        suffix = f" (alternatives: {alternatives})" if alternatives else ""
        problems.append(
            f"key={key!r} manifest={manifest_val!r} rec={rec_val!r}{suffix}"
        )
    return (not problems, problems, any_alternative_used)


def _tolerance_flag_notes(plant: dict) -> list[str]:
    """Render `specifics_tolerance` flags as panel-guidance notes.

    Returns a list of `"tolerance_flag: {key}={value}"` strings, one per
    flag, sorted by key for byte-stable output in panel-routing.jsonl. Empty
    list if the plant has no tolerance flags. The auto-scorer does not
    evaluate the flags structurally — per methodology §8, outside-tolerance
    specifics route to panel and the panel applies the flags when rating.
    """
    tol = plant.get("specifics_tolerance") or {}
    return [f"tolerance_flag: {k}={tol[k]}" for k in sorted(tol.keys())]


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
        "wrong language-level construct",  # Cat 5 plants use this phrase for PAT-on-non-protocol etc.
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
    #
    # Methodology §8 lines 626–631: out-of-tolerance specifics route to panel;
    # only specifics within tolerance fire the auto-scored 1.0 / 0.5-weak path.
    # The auto-scorer evaluates tolerance binary (verbatim match vs not); the
    # plant's `specifics_tolerance` flags are panel guidance, not scorer inputs.
    # See `plans/v7-round2-value-aware-specifics-plan.md` for the design
    # discussion and the §3.3 pre-implementation projection.
    if rec_cat == primary_cat:
        primary_specifics = primary.get("specifics") or {}
        specifics_alternatives = primary.get("specifics_alternatives") or {}
        keys_ok, key_problems = _specifics_keys_match(
            rec_specifics, primary_specifics_required
        )
        if not keys_ok:
            return ScoreResult(
                plant_id, PANEL_ROUTE, "primary_match_specifics_missing_keys",
                notes=key_problems + _tolerance_flag_notes(plant),
            )
        values_ok, value_problems, any_alternative_used = _specifics_values_match(
            rec_specifics,
            primary_specifics,
            primary_specifics_required,
            specifics_alternatives,
        )
        if not values_ok:
            return ScoreResult(
                plant_id, PANEL_ROUTE, "primary_match_specifics_outside_tolerance",
                notes=value_problems + _tolerance_flag_notes(plant),
            )
        grounded, missing_citations = _rationale_cites_all(rec_rationale, must_cite)
        if grounded:
            if any_alternative_used:
                # H0b telemetry: this row scored 1.0 only because at least one
                # required key matched a blessed alternative rather than the
                # canonical value. Distinguished label so the v1-clean vs
                # v1-clean-rubric-loose delta can be attributed per-row without
                # re-reading the manifest. See plan §3.4.
                return ScoreResult(
                    plant_id, 1.0, "primary_match_specifics_blessed_alternative",
                    notes=["all conditions met (≥1 key via blessed alternative)"],
                )
            return ScoreResult(
                plant_id, 1.0, "primary_match_full",
                notes=["all conditions met"],
            )
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
    "4.1-s8-example": {
        "plant_id": "4.1-s8-example",
        "category": "pat-introduction",
        "primary_answer": {
            "category": "pat-introduction",
            "specifics": {
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            # H0b blessed alternatives for the dry-run fixture exercising
            # `primary_match_specifics_blessed_alternative`. Real manifest
            # plants get rule-12 validator coverage; INLINE_PLANTS doesn't
            # flow through the validator, but the rationale parity is kept
            # in case future tests parse it.
            "specifics_alternatives": {
                "new_protocol": ["ContainerProtocol"],
            },
            "specifics_alternatives_rationale": {
                "new_protocol": ["The `Protocol` suffix is the conventional Swift naming for protocol declarations."],
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
        "plant_id": "4.1-s8-example",
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
        "plant_id": "4.1-s8-example",
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
        "plant_id": "4.1-s8-example",
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

# ─── Synthetic fixtures: branch-coverage backstop ─────────────────────────
#
# The §20.1–20.5 examples cover five of the auto-scorer's emit values
# (`primary_match_full`, `primary_match_weak_rationale`, `alternative_match`,
# `restraint_false_positive`, `other_routes_to_panel`). The branches below
# (`breaking_action`, `adjacent_wrong_category`, `wrong_category_enumerated`,
# `wrong_category_not_enumerated`, `no_action_grounded`,
# `no_action_ungrounded`, `primary_match_specifics_missing_keys`,
# `primary_match_specifics_outside_tolerance`) are live in
# score_recommendation() but not exercised by §20. The fixtures below close
# that gap with synthetic recommendations bound to real manifest plants —
# they are NOT methodology-asserted scores, but they pin scorer behavior so
# future logic changes can't silently break a branch.
#
# Synthetic fixtures are kept structurally minimal: each one exercises ONE
# branch via the smallest meaningful recommendation shape.

SYNTHETIC_FIXTURES = [
    {
        "label": "[synthetic] primary_match_specifics_missing_keys: Plant 4.1, missing 'replaces' key",
        "plant_id": "4.1-s8-example",
        "recommendation": {
            "category": "pat-introduction",
            "specifics": {
                "new_protocol": "Container",
                "associated_type": "Item",
                "constraints": [],
                # `replaces` deliberately omitted — required by schema
            },
            "rationale": "TrackContainer and ShowContainer can become a PAT. differs at Item.",
        },
        "expected_score": PANEL_ROUTE,
        "expected_match": "primary_match_specifics_missing_keys",
    },
    {
        "label": "[synthetic] primary_match_specifics_outside_tolerance: Plant 4.1, wrong new_protocol value",
        "plant_id": "4.1-s8-example",
        "recommendation": {
            "category": "pat-introduction",
            "specifics": {
                "new_protocol": "WrongProtocolName",  # manifest says "Container"
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            "rationale": "TrackContainer and ShowContainer differ at Item.",
        },
        "expected_score": PANEL_ROUTE,
        "expected_match": "primary_match_specifics_outside_tolerance",
    },
    {
        "label": "[synthetic] adjacent_wrong_category (0.3): Plant 4.1, protocol-inheritance against PAT",
        "plant_id": "4.1-s8-example",
        # Note: protocol-inheritance is adjacent to pat-introduction in
        # rubric.adjacent_categories. extract-to-common would also be adjacent,
        # but 4.1's §8 alternative_answers also lists extract-to-common, so
        # that path hits Case 2 (alternative_match) before adjacency. Choose a
        # category that is adjacent but NOT in alternative_answers.
        "recommendation": {
            "category": "protocol-inheritance",
            "specifics": {
                "parent": "Container",
                "children": ["TrackContainer", "ShowContainer"],
                "moved_members": ["item", "reload"],
                "reuse_existing_swift_protocol": False,
            },
            "rationale": "Both protocols share members; lift them to a parent protocol.",
        },
        "expected_score": 0.3,
        "expected_match": "adjacent_wrong_category",
    },
    {
        "label": "[synthetic] breaking_action (-0.5): Plant 4.1, subclass-lift on protocols",
        "plant_id": "4.1-s8-example",
        "recommendation": {
            "category": "subclass-lift",
            "specifics": {
                "base_class": "ContainerBase",
                "method": "reload",
                "subclasses": ["TrackContainer", "ShowContainer"],
                "target_location": "Shared/Core",
            },
            "rationale": "Lift reload() into a shared base class.",
        },
        "expected_score": -0.5,
        "expected_match": "breaking_action",
    },
    {
        "label": "[synthetic] wrong_category_enumerated (0.0): Plant 4.1, no-action enumerated as wrong",
        "plant_id": "4.1-s8-example",
        "recommendation": {
            "category": "no-action",
            "specifics": {"reason_class": "coincidental"},
            "rationale": "The two protocols look similar by coincidence.",
        },
        "expected_score": 0.0,
        "expected_match": "wrong_category_enumerated",
    },
    {
        "label": "[synthetic] wrong_category_not_enumerated (0.0): Plant 4.1, macro-synthesis fallback",
        "plant_id": "4.1-s8-example",
        "recommendation": {
            "category": "macro-synthesis",
            "specifics": {
                "macro_name": "ContainerMacro",
                "applies_to": ["TrackContainer", "ShowContainer"],
                "synthesizes": ["item", "reload"],
                "population_size_evidence": "2 conformers",
                "use_swift_builtin": False,
            },
            "rationale": "Generate the protocol with a macro.",
        },
        "expected_score": 0.0,
        "expected_match": "wrong_category_not_enumerated",
    },
    {
        "label": "[synthetic] no_action_grounded (1.0): Plant 1R, no-action with cited rationale",
        "plant_id": "1R",
        # Uses the real 1R manifest entry (sample-app-mirror restraint).
        # Rationale must cite all of 1R's rationale_must_cite substrings; if
        # the manifest's must_cite set changes, this fixture FAILS — that is
        # intentional drift detection. Keep the rationale's substring set in
        # sync with the manifest, or rewrite both together.
        "recommendation": {
            "category": "no-action",
            "specifics": {"reason_class": "sample-app-mirror"},
            "rationale": (
                "MetricRow appears in both the main app and in "
                "Examples/WallpaperSampleApp. The sample-app copy is "
                "intentional: it mirrors production but is gated by "
                "is_sample_app — they MUST stay separate so the sample app "
                "can demonstrate the type independently."
            ),
        },
        "expected_score": 1.0,
        "expected_match": "no_action_grounded",
    },
    {
        "label": "[synthetic] no_action_ungrounded (0.5): Plant 1R, no-action without required citation",
        "plant_id": "1R",
        "recommendation": {
            "category": "no-action",
            "specifics": {"reason_class": "sample-app-mirror"},
            "rationale": "These look duplicated but probably shouldn't be merged.",
        },
        "expected_score": 0.5,
        "expected_match": "no_action_ungrounded",
    },
    {
        # Cat 5 plants use "wrong language-level construct" (rather than "Swift-level
        # error" or "don't subclass") for the canonical breaking action — recommending
        # pat-introduction on structs/free functions. The heuristic must catch this
        # phrasing or 4 of the 5 Cat-5 plants score 0.0 instead of -0.5 on the
        # breaking-action case. Plant 5.1 (uiColor/nsColor → platformColor) is the
        # representative case.
        "label": "[synthetic] breaking_action (-0.5): Plant 5.1, pat-introduction on struct methods (Cat-5 phrasing)",
        "plant_id": "5.1",
        "recommendation": {
            "category": "pat-introduction",
            "specifics": {
                "new_protocol": "PlatformColorProvider",
                "associated_type": "Color",
                "constraints": ["PlatformColor"],
                "replaces": ["uiColor", "nsColor"],
            },
            "rationale": "Introduce a PAT to abstract over the platform color type.",
        },
        "expected_score": -0.5,
        "expected_match": "breaking_action",
    },
    {
        # Pins the H0b fall-through to a blessed alternative per plan §3.4. The
        # canonical `new_protocol` is "Container"; the rec emits "ContainerProtocol",
        # which `INLINE_PLANTS["4.1-s8-example"].specifics_alternatives.new_protocol`
        # blesses. All other required keys match verbatim and the rationale cites
        # all `rationale_must_cite` substrings, so the row scores 1.0 with the new
        # label rather than falling out via `primary_match_specifics_outside_tolerance`.
        "label": "[synthetic] primary_match_specifics_blessed_alternative (1.0): Plant 4.1, new_protocol via blessed alt",
        "plant_id": "4.1-s8-example",
        "recommendation": {
            "category": "pat-introduction",
            "specifics": {
                "new_protocol": "ContainerProtocol",  # blessed alternative
                "associated_type": "Item",
                "constraints": [],
                "replaces": ["TrackContainer", "ShowContainer"],
            },
            "rationale": "The cluster differs at Item; TrackContainer and ShowContainer share the rest.",
        },
        "expected_score": 1.0,
        "expected_match": "primary_match_specifics_blessed_alternative",
    },
]


def run_dry_run(rubric: dict, manifest: dict[str, dict]) -> int:
    """Verify worked-example + branch-coverage fixtures reproduce expected scores.

    Methodology §20.1–20.5 is the methodology-asserted spec; the SYNTHETIC_FIXTURES
    pin scorer behavior on branches that §20 doesn't exercise (breaking_action,
    adjacent_wrong_category, etc.). Exits 0 iff every fixture matches.
    """
    fixtures = [("§20", WORKED_EXAMPLES), ("synthetic", SYNTHETIC_FIXTURES)]
    failures = []
    total = 0
    for label, group in fixtures:
        for ex in group:
            total += 1
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
        print(f"\nFAIL: {len(failures)}/{total} fixtures did not reproduce", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1
    print(
        f"\nOK: all {total} fixtures reproduce their asserted scores "
        f"({len(WORKED_EXAMPLES)} §20 worked examples + {len(SYNTHETIC_FIXTURES)} synthetic branch-coverage)"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Auto-score a single refactor recommendation against the V7 plant manifest."
    )
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
