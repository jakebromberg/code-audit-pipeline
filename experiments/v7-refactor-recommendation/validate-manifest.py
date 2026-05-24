#!/usr/bin/env python3
"""Validate plant-manifest.yaml against the wxyc-ios-64 catalog.

Checks performed:
  1. yaml syntactically valid; top-level shape has `plants:` with a list.
  2. §2.2 budget topology: exactly 25 plants total; exactly 5 plants per category; exactly 1 restraint per category.
  3. plant_id values are unique.
  4. category in the V7 MVP enum; synthesis in {none, full, hybrid}; generic_kind in {function, struct} when present.
  5. For each non-planted source_file basename (filename NOT starting with `_Plant_`), assert the path appears in
     either the type-catalog or function-catalog (matched against the catalog's `file` field, which is the relative
     path from the substrate root). This is the path-existence check that would have caught the 4 wrong paths in
     the first draft of the manifest reviewed in PR #21.
  6. For synthesis == hybrid or full, `planted_extras` must equal the count of `_Plant_*` paths under
     source_files. Catches drift between the field and the underlying file list.
  7. Restraint entries (restraint: true) must declare restraint_pair and restraint_signal.
  8. Unknown field warning: per-plant keys outside the documented schema produce warnings (not errors) so typos
     like `restraintpair` surface without blocking schema evolution.
  9. Rubric schema (Phase A.3, per methodology §8 + companion plant-manifest doc):
     a. expected_substrate_signals is a non-empty list of strings.
     b. primary_answer.category ∈ CATEGORIES ∪ {"no-action"}.
     c. primary_answer.category == "no-action" iff restraint: true.
     d. primary_answer.specifics is a non-empty dict.
     e. primary_answer.rationale_must_cite is a non-empty list of strings.
     f. specifics_tolerance is a dict (may be empty if no tolerances apply).
     g. alternative_answers is a list (possibly empty); each entry has category ∈ CATEGORIES,
        weight ∈ [0.0, 1.0], note non-empty string.
     h. wrong_answers is a non-empty list; each entry has category ∈ CATEGORIES ∪ {"no-action"},
        note non-empty string.
     i. wrong_answers convention enforcement: canonical plants must include 'no-action' as a
        wrong-answer (an agent emitting no-action on a canonical is a false negative); restraint
        plants must include the canonical's own category as a wrong-answer (the textbook FP mode).
     j. expected_cluster_symbols is a non-empty list of non-empty strings. Round-2 binding-artifact
        v2 (#86) gates plant ↔ cluster bindings on planted-symbol substring membership in cluster_id;
        an empty list or empty-string entry would defeat the gate (an empty string substring-matches
        every cluster_id), so both are rejected.
 10. Specifics-keys schema (Phase A.4, sub-issue #27 — catches schema drift from agent-prompt.md §2):
     a. primary_answer.specifics keys are a SUPERSET of `rubric.specifics_schemas[category].required`.
     b. primary_answer.specifics has NO unknown keys beyond the schema's required set (catches typos
        like `target_pkg` for `target_package`). If a category legitimately needs optional keys in the
        future, extend the schema with an explicit `optional` list rather than relaxing this check.
     c. For category 'no-action', specifics.reason_class ∈ the documented enum.
 11. Round-2 cross-lens routing (#33) — `cluster_lens` field on plants that share a substrate cluster:
     a. `cluster_lens` value (when present) ∈ CATEGORIES (the MVP refactor-category enum).
     b. Sharing-group presence: two plants share a cluster iff their source_files overlap AND their
        expected_cluster_symbols overlap (the methodology §9 condition, encoded structurally without
        running the substrate). Every plant in a sharing-group of size ≥ 2 MUST declare `cluster_lens`.
     c. Sharing-group uniqueness: all members of a sharing-group must declare DISTINCT `cluster_lens`
        values. The scorer routes recommendations to the plant whose lens matches the rec's category;
        duplicate lenses break the routing.
 12. Round-4 H0b rubric loosening — `primary_answer.specifics_alternatives` and
     `primary_answer.specifics_alternatives_rationale` (per the H0b rubric-loosening plan §3.1):
     a. Both fields are OPTIONAL. Absent fields trigger no validation; only declared fields are checked.
     b. Both, when declared, must be `dict[str, list[str]]` shapes: keys are strings, values are lists
        of strings.
     c. Every key in `specifics_alternatives` must also be a key in `primary_answer.specifics`. An
        alternative for a key the canonical doesn't declare is orphaned — the auto-scorer never reaches
        the loosening path for non-canonical keys.
     d. Each value list is capped at 3 entries per `(plant, key)` (plan §3.2 cap). Lists with > 3
        entries are validator-rejected to keep curation cost bounded.
     e. No duplicates within a single key's alternative list.
     f. No alternative may equal the canonical `primary_answer.specifics[key]` value verbatim. The
        existing primary-match path already scores verbatim matches; duplicating them as alternatives
        inflates the alternative-usage count without changing match outcomes.
     g. `specifics_alternatives_rationale` parallels `specifics_alternatives`: the same key set, each
        value a list of strings of the same length as the corresponding alternatives list. A
        rationale-length mismatch is hard-fail (every alternative must be motivated; an unrationalized
        alternative cannot satisfy the curation rubric's criterion (a)+(b)+(c) checklist).
     h. Each rationale string must be non-empty.

Usage
-----
    python3 validate-manifest.py
    python3 validate-manifest.py --catalog-root /tmp/wxyc-ios-audit-planted
    python3 validate-manifest.py --rubric ./rubric.yaml

Exit code: 0 if all checks pass; 1 otherwise. Errors and warnings printed to stderr; a `OK n=<plant_count>`
summary prints to stdout on success. Warnings do not affect exit code.

Dependencies: PyYAML (stdlib `json` for the catalogs).
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

import yaml

CATEGORIES = {
    "extract-to-common",
    "protocol-inheritance",
    "default-implementation",
    "pat-introduction",
    "generic-parameterization",
}
SYNTHESIS_VALUES = {"none", "full", "hybrid"}
GENERIC_KINDS = {"function", "struct"}
PLANTED_PREFIX = "_Plant_"

# §2.2 budget topology
TOTAL_PLANTS = 25
PLANTS_PER_CATEGORY = 5
RESTRAINTS_PER_CATEGORY = 1

# Documented schema fields. Anything outside this set produces a warning, not an error,
# so the schema can evolve without breaking the validator.
KNOWN_KEYS = {
    "plant_id",
    "category",
    "source_type",
    "source_files",
    "synthesis",
    "planted_extras",
    "generic_kind",
    "cross_layer",
    "restraint",
    "restraint_pair",
    "restraint_signal",
    # Phase A.3 rubric fields
    "expected_substrate_signals",
    "primary_answer",
    "specifics_tolerance",
    "alternative_answers",
    "wrong_answers",
    # Round-2 binding-artifact v2 (#86): per-plant cluster_id symbol gate
    "expected_cluster_symbols",
    # Round-2 cross-lens routing (#33): per-plant lens declaration for shared clusters
    "cluster_lens",
}

# Categories valid as a primary/alternative/wrong-answer recommendation. Mirrors the agent-prompt taxonomy
# in `docs/refactor-recommendation-experiment-agent-prompt.md` §2 restricted to V7 MVP scope. `no-action`
# is a permitted answer category but is NOT in CATEGORIES; it's a separate bucket because (a) it's only
# valid as primary for restraints, and (b) it's the universal wrong-answer for canonical plants. The
# three out-of-MVP-plant categories — Cat. 6 `subclass-lift`, Cat. 7 `macro-synthesis`, and Cat. 8
# `composition` — are not plantable in MVP but remain valid as wrong-answer / alternative
# recommendations the manifest may cite (an agent recommending one of these is in-scope to score).
ANSWER_CATEGORIES = CATEGORIES | {"subclass-lift", "macro-synthesis", "composition"}
NO_ACTION = "no-action"


def is_planted_path(path: str) -> bool:
    """Return True if the path's basename starts with `_Plant_` (V6 plant-file convention)."""
    return Path(path).name.startswith(PLANTED_PREFIX)


def load_catalog_files(catalog_root: Path) -> set[str]:
    """Return the union of `file` values from type-catalog.json and function-catalog.json."""
    files: set[str] = set()
    for name in ("type-catalog.json", "function-catalog.json"):
        path = catalog_root / name
        if not path.exists():
            print(f"warning: catalog file not found: {path}", file=sys.stderr)
            continue
        with path.open() as f:
            for entry in json.load(f):
                if isinstance(entry, dict) and (file_val := entry.get("file")):
                    files.add(file_val)
    return files


def _is_non_empty_string_list(value: object) -> bool:
    return isinstance(value, list) and len(value) > 0 and all(
        isinstance(item, str) and item != "" for item in value
    )


def load_rubric(rubric_path: Path) -> dict:
    """Load the rubric.yaml. Returns the parsed dict.

    Phase A.4 (sub-issue #27): the validator consumes `rubric.specifics_schemas`
    to enforce per-category specifics-keys allowlists. Loading the rubric early
    fails fast if the file is missing or malformed.
    """
    if not rubric_path.exists():
        raise FileNotFoundError(f"rubric file not found: {rubric_path}")
    with rubric_path.open() as f:
        rubric = yaml.safe_load(f)
    if not isinstance(rubric, dict) or "specifics_schemas" not in rubric:
        raise ValueError(f"rubric at {rubric_path} is missing `specifics_schemas`")
    return rubric


def validate_specifics_keys(
    plant: dict, prefix: str, rubric: dict, errors: list[str]
) -> None:
    """Phase A.4 / sub-issue #27: validate primary_answer.specifics keys against rubric schemas.

    Three checks (per the issue's acceptance criteria):
      (a) keys are a superset of `rubric.specifics_schemas[category].required` —
          a missing key is hard-fail because the auto-scorer expects the closed shape.
      (b) keys have no extras beyond `required` — catches typos (e.g., `target_pkg`
          for `target_package`).
      (c) For category 'no-action', `specifics.reason_class` must be in the
          documented enum (`rubric.specifics_schemas['no-action'].reason_class_enum`).
    """
    primary = plant.get("primary_answer")
    if not isinstance(primary, dict):
        return  # earlier rubric check already flagged this
    category = primary.get("category")
    specifics = primary.get("specifics")
    schemas = rubric.get("specifics_schemas", {})
    schema = schemas.get(category)
    if schema is None:
        errors.append(
            f"{prefix}: primary_answer.category={category!r} has no `specifics_schemas` entry "
            f"in rubric.yaml — schema-drift indicator"
        )
        return
    if not isinstance(specifics, dict):
        return  # earlier check flagged this
    required = set(schema.get("required", []))
    actual = set(specifics.keys())
    missing = required - actual
    if missing:
        errors.append(
            f"{prefix}: primary_answer.specifics missing required keys for "
            f"category={category!r}: {sorted(missing)}"
        )
    extra = actual - required
    if extra:
        errors.append(
            f"{prefix}: primary_answer.specifics has unknown keys for "
            f"category={category!r}: {sorted(extra)} (typo? schema drift?)"
        )
    # 10c: no-action reason_class enum check.
    if category == "no-action":
        reason_class = specifics.get("reason_class")
        enum_values = schema.get("reason_class_enum", [])
        if enum_values and reason_class not in enum_values:
            errors.append(
                f"{prefix}: primary_answer.specifics.reason_class={reason_class!r} "
                f"not in documented enum {sorted(enum_values)}"
            )


def validate_rubric(
    plant: dict,
    prefix: str,
    is_restraint: bool,
    plants_by_id: dict[str, dict],
    errors: list[str],
) -> None:
    """Per Phase A.3, validate the rubric-related fields of a plant entry (methodology §8).

    `plants_by_id` is the manifest indexed by plant_id, used by check 9i to look up
    a restraint's canonical and verify the canonical's category appears in this
    plant's wrong_answers (convention enforcement; agents recommending the canonical's
    own action on a restraint is the textbook FP mode).
    """
    # 9a: expected_substrate_signals is a non-empty list of strings.
    signals = plant.get("expected_substrate_signals")
    if not _is_non_empty_string_list(signals):
        errors.append(
            f"{prefix}: expected_substrate_signals must be a non-empty list of strings"
        )

    # 9j: expected_cluster_symbols is a non-empty list of non-empty strings.
    # Per round-2 binding-artifact v2 (#86), this field gates plant ↔ cluster
    # bindings on planted-symbol membership in cluster_id. An empty list or
    # empty-string entry would defeat the gate (an empty string substring-
    # matches every cluster_id), so both are rejected.
    symbols = plant.get("expected_cluster_symbols")
    if not _is_non_empty_string_list(symbols):
        errors.append(
            f"{prefix}: expected_cluster_symbols must be a non-empty list of non-empty strings"
        )

    # 9b–9e: primary_answer shape.
    primary = plant.get("primary_answer")
    if not isinstance(primary, dict):
        errors.append(f"{prefix}: primary_answer must be a dict")
    else:
        pri_cat = primary.get("category")
        valid_primary_cats = ANSWER_CATEGORIES | {NO_ACTION}
        if pri_cat not in valid_primary_cats:
            errors.append(
                f"{prefix}: primary_answer.category {pri_cat!r} not in {sorted(valid_primary_cats)}"
            )
        # 9c: no-action iff restraint
        if is_restraint and pri_cat != NO_ACTION:
            errors.append(
                f"{prefix}: restraint=true but primary_answer.category={pri_cat!r} (must be 'no-action')"
            )
        if (not is_restraint) and pri_cat == NO_ACTION:
            errors.append(
                f"{prefix}: primary_answer.category='no-action' but restraint is not true"
            )
        specifics = primary.get("specifics")
        if not isinstance(specifics, dict) or len(specifics) == 0:
            errors.append(f"{prefix}: primary_answer.specifics must be a non-empty dict")
        cites = primary.get("rationale_must_cite")
        if not _is_non_empty_string_list(cites):
            errors.append(
                f"{prefix}: primary_answer.rationale_must_cite must be a non-empty list of strings"
            )

    # 9f: specifics_tolerance is a dict (may be empty).
    tolerance = plant.get("specifics_tolerance")
    if not isinstance(tolerance, dict):
        errors.append(f"{prefix}: specifics_tolerance must be a dict (possibly empty)")

    # 9g: alternative_answers is a list; each entry has category ∈ ANSWER_CATEGORIES, weight ∈ [0,1],
    # note non-empty string.
    alts = plant.get("alternative_answers")
    if not isinstance(alts, list):
        errors.append(f"{prefix}: alternative_answers must be a list (possibly empty)")
    else:
        for idx, alt in enumerate(alts):
            tag = f"{prefix}: alternative_answers[{idx}]"
            if not isinstance(alt, dict):
                errors.append(f"{tag}: entry must be a dict")
                continue
            cat = alt.get("category")
            if cat not in ANSWER_CATEGORIES:
                errors.append(
                    f"{tag}: category {cat!r} not in {sorted(ANSWER_CATEGORIES)}"
                )
            weight = alt.get("weight")
            if not isinstance(weight, (int, float)) or isinstance(weight, bool):
                errors.append(f"{tag}: weight must be a number in [0.0, 1.0]")
            elif not (0.0 <= float(weight) <= 1.0):
                errors.append(f"{tag}: weight {weight!r} not in [0.0, 1.0]")
            note = alt.get("note")
            if not isinstance(note, str) or note.strip() == "":
                errors.append(f"{tag}: note must be a non-empty string")

    # 9h: wrong_answers is a non-empty list; each entry has category ∈ ANSWER_CATEGORIES ∪ {no-action},
    # note non-empty string.
    wrongs = plant.get("wrong_answers")
    if not isinstance(wrongs, list) or len(wrongs) == 0:
        errors.append(f"{prefix}: wrong_answers must be a non-empty list")
    else:
        valid_wrong_cats = ANSWER_CATEGORIES | {NO_ACTION}
        for idx, wrong in enumerate(wrongs):
            tag = f"{prefix}: wrong_answers[{idx}]"
            if not isinstance(wrong, dict):
                errors.append(f"{tag}: entry must be a dict")
                continue
            cat = wrong.get("category")
            if cat not in valid_wrong_cats:
                errors.append(
                    f"{tag}: category {cat!r} not in {sorted(valid_wrong_cats)}"
                )
            note = wrong.get("note")
            if not isinstance(note, str) or note.strip() == "":
                errors.append(f"{tag}: note must be a non-empty string")

        # 9i: convention enforcement on wrong_answers contents.
        #
        # Canonical plants (restraint=false): no-action MUST appear as a wrong_answer.
        # An agent emitting no-action on a canonical is a false negative, and the
        # methodology §8 routing makes that explicit only if no-action is enumerated;
        # otherwise it falls to wrong_category_not_enumerated and the rubric coverage
        # is implicit. Enforce the convention so the manifest stays the contract.
        #
        # Restraint plants (restraint=true): the canonical's category MUST appear as
        # a wrong_answer. An agent that recommends the canonical's own action on a
        # restraint is the textbook false-positive mode, so the restraint's wrong_answer
        # list documents that explicitly. The canonical's category is looked up via
        # restraint_pair (already validated non-empty by check 7).
        wrong_cats = {w.get("category") for w in wrongs if isinstance(w, dict)}
        if not is_restraint:
            if NO_ACTION not in wrong_cats:
                errors.append(
                    f"{prefix}: canonical plant must include 'no-action' in wrong_answers "
                    "(convention; an agent emitting no-action on a canonical is a false negative)"
                )
        else:
            # For restraints: canonical's category must appear in wrong_answers.
            pair_id = plant.get("restraint_pair")
            canonical = plants_by_id.get(pair_id) if pair_id else None
            if canonical is not None:
                canonical_cat = canonical.get("category")
                if canonical_cat and canonical_cat not in wrong_cats:
                    errors.append(
                        f"{prefix}: restraint must include canonical's category "
                        f"{canonical_cat!r} (from restraint_pair={pair_id!r}) in wrong_answers "
                        "(convention; an agent recommending the canonical's own action is the textbook FP mode)"
                    )


# Cap per (plant, key) from the H0b rubric-loosening plan §3.2. Lists longer than this
# are validator-rejected — curation cost is bounded by this constant, and the
# alternative-usage analysis in the §11 writeup is reported as fixed-width per key.
H0B_ALTERNATIVES_CAP = 3


def _validate_specifics_alternatives(plant: dict, prefix: str, errors: list[str]) -> None:
    """Rule 12 — round-4 H0b: `primary_answer.specifics_alternatives` + rationale schema.

    Both fields are optional. When declared, they must be `dict[str, list[str]]`
    shapes mirroring `primary_answer.specifics`'s keys, with strict cardinality
    (cap 3 per key), no canonical duplicates, no in-list duplicates, and rationale
    list-lengths matching the alternative list-lengths.

    See plan §3.1 / §3.2 and `h0b-curation-rubric.md` for the curation rule these
    schema checks enforce. The auto-scorer (PR 3) reads these fields after the
    exact-value-match path fails; an alternative that passes (a)+(b)+(c) of the
    curation rubric and is verbatim-equal to the agent's emitted value triggers
    the new `primary_match_specifics_blessed_alternative` match label (score 1.0,
    NOT panel-routed).
    """
    primary = plant.get("primary_answer")
    if not isinstance(primary, dict):
        return  # earlier rubric check already flagged this

    alts = primary.get("specifics_alternatives")
    rationale = primary.get("specifics_alternatives_rationale")

    if alts is None and rationale is None:
        return  # H0b is opt-in per plant.

    if alts is None:
        errors.append(
            f"{prefix}: primary_answer.specifics_alternatives_rationale declared without "
            "specifics_alternatives — rationale must accompany alternatives"
        )
        return

    if not isinstance(alts, dict):
        errors.append(
            f"{prefix}: primary_answer.specifics_alternatives must be a dict[str, list[str]]"
        )
        return

    specifics = primary.get("specifics") if isinstance(primary.get("specifics"), dict) else {}
    canonical_keys = set(specifics)

    for key, value in alts.items():
        sub_prefix = f"{prefix}: primary_answer.specifics_alternatives[{key!r}]"
        if not isinstance(key, str):
            errors.append(f"{prefix}: specifics_alternatives has non-string key {key!r}")
            continue
        if key not in canonical_keys:
            errors.append(
                f"{sub_prefix}: key not present in primary_answer.specifics — orphan alternative "
                "(the auto-scorer's loosening path only fires for canonical keys)"
            )
        if not isinstance(value, list):
            errors.append(f"{sub_prefix}: value must be a list of strings")
            continue
        if len(value) > H0B_ALTERNATIVES_CAP:
            errors.append(
                f"{sub_prefix}: {len(value)} alternatives exceeds cap of {H0B_ALTERNATIVES_CAP} "
                "(plan §3.2)"
            )
        # Per-entry type + canonical-duplicate + in-list-duplicate checks.
        seen: set[str] = set()
        canonical_value = specifics.get(key) if key in canonical_keys else None
        for idx, entry in enumerate(value):
            if not isinstance(entry, str):
                errors.append(f"{sub_prefix}[{idx}]: entry must be a string")
                continue
            if entry == canonical_value:
                errors.append(
                    f"{sub_prefix}[{idx}]: alternative {entry!r} duplicates the canonical "
                    f"primary_answer.specifics[{key!r}] value — the primary-match path already "
                    "scores verbatim matches"
                )
            if entry in seen:
                errors.append(
                    f"{sub_prefix}[{idx}]: alternative {entry!r} duplicated within the list"
                )
            seen.add(entry)

    # Rationale shape — only validated if alternatives itself is well-typed.
    if rationale is None:
        # If the curator declared alternatives but no rationale, fail loud. The plan
        # mandates per-alternative rationale grounding.
        if isinstance(alts, dict) and any(alts.values()):
            errors.append(
                f"{prefix}: primary_answer.specifics_alternatives_rationale required when "
                "any specifics_alternatives entry is declared (plan §3.1)"
            )
        return

    if not isinstance(rationale, dict):
        errors.append(
            f"{prefix}: primary_answer.specifics_alternatives_rationale must be a dict[str, list[str]]"
        )
        return

    rationale_keys = set(rationale)
    alt_keys = set(alts)
    extra_rationales = rationale_keys - alt_keys
    if extra_rationales:
        errors.append(
            f"{prefix}: specifics_alternatives_rationale has keys with no matching alternatives: "
            f"{sorted(extra_rationales)}"
        )
    missing_rationales = alt_keys - rationale_keys
    if missing_rationales:
        errors.append(
            f"{prefix}: specifics_alternatives_rationale missing entries for keys "
            f"{sorted(missing_rationales)} — every alternatives key needs a parallel rationale list"
        )

    for key in alt_keys & rationale_keys:
        sub_prefix = f"{prefix}: primary_answer.specifics_alternatives_rationale[{key!r}]"
        alt_list = alts.get(key)
        rat_list = rationale.get(key)
        if not isinstance(rat_list, list):
            errors.append(f"{sub_prefix}: value must be a list of strings")
            continue
        if isinstance(alt_list, list) and len(rat_list) != len(alt_list):
            errors.append(
                f"{sub_prefix}: rationale list has {len(rat_list)} entries but alternatives "
                f"list has {len(alt_list)} — rationale length must equal alternatives length"
            )
        for idx, entry in enumerate(rat_list):
            if not isinstance(entry, str):
                errors.append(f"{sub_prefix}[{idx}]: rationale entry must be a string")
            elif entry.strip() == "":
                errors.append(f"{sub_prefix}[{idx}]: rationale entry must be non-empty")


def _sharing_groups(plants: list[dict]) -> list[set[str]]:
    """Group plants by **cross-lens** cluster-sharing (methodology §9).

    Two plants are in the same group iff ALL THREE conditions hold:
      (1) their source_files lists overlap, AND
      (2) their expected_cluster_symbols lists overlap, AND
      (3) their `category` values differ.

    Conditions (1) + (2) encode the §9 cluster-sharing structural condition
    (PR #89's symbol gate at bind-time ensures that source-file overlap
    alone does NOT imply cluster-id overlap, so both overlaps are needed).
    Condition (3) narrows to the §9 *cross-lens* case specifically: the
    `cluster_lens` routing rule (#33) only disambiguates when plants test
    distinct refactor-category lenses. Same-category cluster-sharing is a
    distinct manifest-design concern (e.g., Plants 2.3/2.4 both test
    protocol-inheritance on overlapping AudioPlayerProtocol clusters) that
    cluster_lens routing cannot resolve — the auto-scorer's existing per-
    plant independent scoring handles it correctly under the canonical
    rubric.

    The relation is transitive over plants of distinct categories: if
    A↔B↔C and the trio spans ≥ 2 categories, all three end up in one
    group. Implemented via union-find; performance is irrelevant at 25
    plants.

    Returns one set of plant_ids per group of size ≥ 2; singletons are
    elided. Empty list if no plant pairs satisfy all three conditions.

    Round-2 (#33) escalation path: conditions (1) + (2) approximate the
    substrate's cluster_id overlap. If post-round-2 trials reveal real
    cluster_ids diverge from the heuristic (false negatives — plants
    share a substrate cluster but the heuristic doesn't flag them;
    false positives — flagged but real cluster_ids disjoint), escalate
    via a separate plan to wire substrate cluster outputs directly into
    the check. Until that lands, the §9 fallback semantics still apply
    so false negatives degrade gracefully to round-1 fan-out behavior.
    """
    parent: dict[str, str] = {}

    def find(x: str) -> str:
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x

    def union(x: str, y: str) -> None:
        rx, ry = find(x), find(y)
        if rx != ry:
            parent[rx] = ry

    for p in plants:
        pid = p.get("plant_id")
        if isinstance(pid, str):
            parent[pid] = pid

    for i, a in enumerate(plants):
        a_id = a.get("plant_id")
        if not isinstance(a_id, str):
            continue
        a_files = set(a.get("source_files") or [])
        a_symbols = set(a.get("expected_cluster_symbols") or [])
        a_cat = a.get("category")
        for b in plants[i + 1:]:
            b_id = b.get("plant_id")
            if not isinstance(b_id, str):
                continue
            b_cat = b.get("category")
            # Condition (3): cross-lens only. Same-category sharing is out of scope.
            if a_cat == b_cat:
                continue
            b_files = set(b.get("source_files") or [])
            b_symbols = set(b.get("expected_cluster_symbols") or [])
            if a_files & b_files and a_symbols & b_symbols:
                union(a_id, b_id)

    groups_by_root: dict[str, set[str]] = {}
    for pid in parent:
        root = find(pid)
        groups_by_root.setdefault(root, set()).add(pid)
    return [g for g in groups_by_root.values() if len(g) >= 2]


def _validate_cluster_lens(plants: list[dict], errors: list[str]) -> None:
    """Round-2 (#33) check 11 — `cluster_lens` schema.

    Three clauses:
      11a. `cluster_lens` value (when declared) ∈ CATEGORIES. Fires on
           any plant that declares the field, including singletons.
      11b. Every plant in a sharing-group must declare `cluster_lens`.
      11c. All members of a sharing-group must declare DISTINCT `cluster_lens`
           values (so the scorer can route by lens unambiguously).
    """
    # 11a: value enum (singletons + sharing-group members alike).
    for plant in plants:
        lens = plant.get("cluster_lens")
        if lens is None:
            continue
        if lens not in CATEGORIES:
            pid = plant.get("plant_id", "<unknown>")
            errors.append(
                f"plant {pid}: cluster_lens {lens!r} not in {sorted(CATEGORIES)}"
            )

    # 11b + 11c: sharing-group presence and uniqueness.
    plants_by_id = {p.get("plant_id"): p for p in plants if isinstance(p.get("plant_id"), str)}
    for group in _sharing_groups(plants):
        sorted_ids = sorted(group)
        missing: list[str] = []
        declared: dict[str, list[str]] = {}  # lens value → plant_ids declaring it
        for pid in sorted_ids:
            plant = plants_by_id.get(pid)
            if plant is None:
                continue
            lens = plant.get("cluster_lens")
            if lens is None:
                missing.append(pid)
            else:
                declared.setdefault(lens, []).append(pid)
        # 11b: each missing member is its own error so the operator sees
        # exactly which plant_ids need migration.
        for pid in missing:
            errors.append(
                f"plant {pid}: cluster_lens required — plant is in sharing-group "
                f"{sorted_ids} (overlapping source_files + expected_cluster_symbols "
                f"with at least one other plant)"
            )
        # 11c: any lens value declared by more than one member breaks routing.
        for lens, claimants in declared.items():
            if len(claimants) > 1:
                errors.append(
                    f"sharing-group {sorted_ids}: cluster_lens values must be distinct "
                    f"but plants {sorted(claimants)} all declare {lens!r}"
                )


def validate(manifest_path: Path, catalog_root: Path, rubric_path: Path) -> int:
    errors: list[str] = []
    warnings: list[str] = []

    try:
        rubric = load_rubric(rubric_path)
    except (FileNotFoundError, ValueError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    with manifest_path.open() as f:
        doc = yaml.safe_load(f)

    plants = doc.get("plants") if isinstance(doc, dict) else None
    if not isinstance(plants, list):
        print("error: manifest must have top-level `plants:` list", file=sys.stderr)
        return 1

    catalog_files = load_catalog_files(catalog_root)
    if not catalog_files:
        print(f"error: no catalog entries loaded from {catalog_root}", file=sys.stderr)
        return 1

    # §2.2 budget topology checks
    if len(plants) != TOTAL_PLANTS:
        errors.append(f"§2.2 budget: expected {TOTAL_PLANTS} plants, got {len(plants)}")
    by_category = Counter(p.get("category") for p in plants)
    restraints_by_category = Counter(
        p.get("category") for p in plants if p.get("restraint")
    )
    for cat in CATEGORIES:
        if by_category[cat] != PLANTS_PER_CATEGORY:
            errors.append(
                f"§2.2 budget: category {cat!r} has {by_category[cat]} plants, expected {PLANTS_PER_CATEGORY}"
            )
        if restraints_by_category[cat] != RESTRAINTS_PER_CATEGORY:
            errors.append(
                f"§2.2 budget: category {cat!r} has {restraints_by_category[cat]} restraints, "
                f"expected {RESTRAINTS_PER_CATEGORY}"
            )

    ids = [p.get("plant_id") for p in plants]
    duplicates = [pid for pid, count in Counter(ids).items() if count > 1]
    if duplicates:
        errors.append(f"duplicate plant_id values: {duplicates}")

    # Index plants by plant_id for cross-plant validations (rule 9i: restraint
    # canonical-category lookup via restraint_pair).
    plants_by_id: dict[str, dict] = {
        p.get("plant_id"): p for p in plants if isinstance(p.get("plant_id"), str)
    }

    for i, plant in enumerate(plants):
        pid = plant.get("plant_id", f"<index {i}>")
        prefix = f"plant {pid}"

        unknown_keys = set(plant.keys()) - KNOWN_KEYS
        if unknown_keys:
            warnings.append(f"{prefix}: unknown field(s) {sorted(unknown_keys)} (typo? schema change?)")

        category = plant.get("category")
        if category not in CATEGORIES:
            errors.append(f"{prefix}: category {category!r} not in {sorted(CATEGORIES)}")

        synthesis = plant.get("synthesis")
        if synthesis not in SYNTHESIS_VALUES:
            errors.append(f"{prefix}: synthesis {synthesis!r} not in {sorted(SYNTHESIS_VALUES)}")

        if (gk := plant.get("generic_kind")) is not None and gk not in GENERIC_KINDS:
            errors.append(f"{prefix}: generic_kind {gk!r} not in {sorted(GENERIC_KINDS)}")

        source_files = plant.get("source_files") or []
        if not isinstance(source_files, list) or not source_files:
            errors.append(f"{prefix}: source_files must be a non-empty list")
            continue

        planted_count = 0
        for sf in source_files:
            if not isinstance(sf, str):
                errors.append(f"{prefix}: source_files entry {sf!r} is not a string")
                continue
            if is_planted_path(sf):
                planted_count += 1
                continue
            if sf not in catalog_files:
                errors.append(f"{prefix}: source_file {sf!r} not found in catalog (path-existence check)")

        declared_extras = plant.get("planted_extras", 0)
        if synthesis in {"full", "hybrid"} and declared_extras != planted_count:
            errors.append(
                f"{prefix}: planted_extras={declared_extras} but found {planted_count} `_Plant_*` paths"
            )
        if synthesis == "none" and planted_count != 0:
            errors.append(
                f"{prefix}: synthesis=none but {planted_count} `_Plant_*` paths present"
            )

        if plant.get("restraint"):
            if not plant.get("restraint_pair"):
                errors.append(f"{prefix}: restraint=true but restraint_pair missing")
            if not plant.get("restraint_signal"):
                errors.append(f"{prefix}: restraint=true but restraint_signal missing")

        # Phase A.3 rubric schema checks
        is_restraint = bool(plant.get("restraint"))
        validate_rubric(plant, prefix, is_restraint, plants_by_id, errors)
        # Phase A.4 specifics-keys allowlist (sub-issue #27)
        validate_specifics_keys(plant, prefix, rubric, errors)
        # Round-4 H0b: specifics_alternatives + rationale schema (rule 12)
        _validate_specifics_alternatives(plant, prefix, errors)

    # Round-2 cross-lens routing (#33): cluster_lens schema check.
    # Runs once over the full plant list (needs cross-plant sharing-group
    # detection); errors are attributed to specific plant_ids inside.
    _validate_cluster_lens(plants, errors)

    if warnings:
        print(f"{len(warnings)} warning(s):", file=sys.stderr)
        for w in warnings:
            print(f"  ! {w}", file=sys.stderr)

    if errors:
        print(f"FAIL: {len(errors)} error(s) in {manifest_path}", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    print(f"OK n={len(plants)} plants validated against catalog at {catalog_root}")
    return 0


def main() -> int:
    here = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--manifest",
        type=Path,
        default=here / "plant-manifest.yaml",
        help="Path to plant-manifest.yaml",
    )
    parser.add_argument(
        "--catalog-root",
        type=Path,
        default=Path("/tmp/wxyc-ios-audit-planted"),
        help="Directory containing type-catalog.json and function-catalog.json",
    )
    parser.add_argument(
        "--rubric",
        type=Path,
        default=here / "rubric.yaml",
        help="Path to rubric.yaml (Phase A.4 specifics-keys allowlist source)",
    )
    args = parser.parse_args()
    return validate(args.manifest, args.catalog_root, args.rubric)


if __name__ == "__main__":
    sys.exit(main())
