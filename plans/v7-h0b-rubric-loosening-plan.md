# V7 H0b — rubric-loosening sub-experiment (recommended follow-up to round-3's H0a outcome)

> Follow-up sub-experiment recommended by [`results.md §10.7`](../experiments/v7-refactor-recommendation/results.md#107-follow-up-h0b-sub-experiment-recommendation) after round-3's prompt-sensitivity sub-experiment closed with **H0a supported (model capability ceiling)**. Round-3's per-category breakdown — default-implementation [Plant 3.2](../experiments/v7-refactor-recommendation/plant-manifest.yaml) "BlendMode" vs "BlendModeConvertible", [Plant 3.3](../experiments/v7-refactor-recommendation/plant-manifest.yaml) "AudioProcessor" vs "NormalizationModeConfigurable" — surfaces several mismatches that route to panel because the agent's identifier is *structurally equivalent but lexically different* from the manifest's canonical value. This sub-experiment tests whether a loosened auto-scorer rubric (admitting pre-blessed equivalent alternatives) drops the panel-route rate substantially, isolating the rubric-over-strictness contribution per [methodology §10](../docs/refactor-recommendation-experiment-methodology.md#10-pre-registration-discipline). The change is pre-registered via this plan + [`rubric-modifications.md`](../experiments/v7-refactor-recommendation/rubric-modifications.md) round-4 entry per methodology §10.

## 1. Context and motivation

Round-3's prompt-sensitivity sub-experiment (PRs #99–#103, closed 2026-05-20/21) tested whether the round-2 panel-route load (22.80% = 119 of 522 under v1-clean per [`results.md §10.4`](../experiments/v7-refactor-recommendation/results.md#104-headline-panel-route-delta)) was driven by prompt vagueness (H1) or model capability ceiling (H0a). The v2 prompt brought the rate down to 20.69% (108/522) — an overall relative drop of 9.24%, well below the pre-registered 50% threshold for H1. The decision tree resolved to H0a supported.

But the per-category breakdown in [`results.md §10.5`](../experiments/v7-refactor-recommendation/results.md#105-per-category-panel-route-delta) was heterogeneous, not uniform: default-implementation −17.4% rel, protocol-inheritance −19.0%, generic-parameterization −13.0%, extract-to-common 0.0%, pat-introduction +28.6%. Three categories showed partial H1 sensitivity in the 13–19% range; one was flat; one moved *against* H1. This rejected a uniform-H1 reading but is consistent with H1 contributing a small floor under a dominant H0a.

Round-3's writeup §10.7 named a third hypothesis that the plan §1 of the prompt-sensitivity sub-experiment had already pre-registered:

> **H0b — rubric over-strictness**: the auto-scorer's verbatim-match check is too strict; values like `BlendMode` vs `BlendModeConvertible` are structurally equivalent but lexically different. The right fix is rubric loosening, not prompt sharpening.

Inspection of the round-3 `analyses-v1-clean/panel-routing.jsonl` confirms the symptom is real. Plant 3.2's panel-routed rows carry notes like `key='protocol' manifest='BlendMode (new shared protocol over the 16-case union, with displayName + blendMode requirements)' rec='BlendModeConvertible'` — the agent identified the correct refactor (a default-implementation on a shared protocol over the 16 blend-mode cases) but named the protocol `BlendModeConvertible` instead of `BlendMode`. A domain-expert reviewer reading both names would judge them equivalent in this context: both name a shared protocol over the same cluster, with the same field requirements. The auto-scorer's verbatim-match cannot tell the difference and routes to panel.

This sub-experiment tests whether the panel-route load drops substantially under a pre-blessed loosening of the verbatim-match rule. The hypothesis is:

- **H0b — rubric over-strictness**: round-2's panel-route load is dominated by lexically-different-but-structurally-equivalent identifier mismatches. Admitting pre-blessed alternatives in the auto-scorer should drop the panel-route rate by ≥ 50%, without changing the agent's behavior.

Note that this experiment holds the prompt, manifest, model alias, and model parameters **all fixed**. Only the rubric changes. The experimental arm reuses the existing [`trial-logs-v1-clean/`](../experiments/v7-refactor-recommendation/trial-logs-v1-clean) corpus produced by [PR #102](https://github.com/jakebromberg/code-audit-pipeline/pull/102); no new agent calls are made. **Total API spend: $0.**

## 2. Scope

Single sub-experiment: auto-scorer rerun with a pre-registered rubric loosening, applied to the existing v1-clean trial-logs corpus.

**In scope:**

- New per-plant manifest field [`primary_answer.specifics_alternatives`](../experiments/v7-refactor-recommendation/plant-manifest.yaml) at [`experiments/v7-refactor-recommendation/plant-manifest.yaml`](../experiments/v7-refactor-recommendation/plant-manifest.yaml), declaring up to 3 pre-blessed alternative values per required specifics key per plant.
- Curation pass: identify alternatives for the 17 panel-routed plants in the round-2/3 corpus per the curation rule in §3.2.
- Auto-scorer change in [`experiments/v7-refactor-recommendation/auto-scorer.py`](../experiments/v7-refactor-recommendation/auto-scorer.py): after exact-value-match fails, check `value ∈ primary_value ∪ specifics_alternatives[key]`. On match, attach a new match label `primary_match_specifics_blessed_alternative` (scores 1.0, does NOT route to panel).
- Validator update in [`experiments/v7-refactor-recommendation/validate-manifest.py`](../experiments/v7-refactor-recommendation/validate-manifest.py): per-key alternatives must be lists of strings, capped at 3 per (plant, key), no duplicates within a list, no duplication with the canonical value.
- Auto-scorer rerun against the existing [`trial-logs-v1-clean/`](../experiments/v7-refactor-recommendation/trial-logs-v1-clean) parsed cache, producing new [`analyses-v1-clean-rubric-loose/`](../experiments/v7-refactor-recommendation/analyses-v1-clean-rubric-loose) directory.
- Comparison: panel-route rate before-and-after, per condition + per category + per plant + per blessed alternative (how many of the 3-per-key slots were exercised, and which?).
- New [`analyses-v2/h0b-rubric-loosening.json`](../experiments/v7-refactor-recommendation/analyses-v2/h0b-rubric-loosening.json) documents the formal delta matrix and decision-tree outcome.
- New `results.md §11` reports the H0b outcome.
- [`rubric-modifications.md`](../experiments/v7-refactor-recommendation/rubric-modifications.md) round-4 entry per methodology §10.
- [`reproducibility.yaml`](../experiments/v7-refactor-recommendation/reproducibility.yaml) `execution.h0b_sub_experiment` block: pre-registration hashes, rerun timestamp, sub-experiment outcome.

**Out of scope:**

- New agent trials. Held fixed at the v1-clean corpus. Zero API spend.
- Manifest changes beyond the new field. Plants stay fixed.
- Prompt changes. Held fixed at v1.
- Model changes. Held fixed at `claude-sonnet-4-6`.
- Multiple loosening mechanisms. Only pre-blessed alternatives in this sub-experiment. If H0b is null-result and a follow-up wants to test token-edit-distance or semantic-substring matching, that's a separate pre-registration.
- Recruitment / panel work. Independent of [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) / [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94); H0b shifts rows from panel-routed back to auto-scored, which only *reduces* panel work.
- Round-2 (pre-substrate-regeneration) corpus comparison. The matched-substrate v1-clean corpus is the control; round-2's [`analyses/`](../experiments/v7-refactor-recommendation/analyses) artifacts stay as the historical v1-against-original-substrate snapshot.

## 3. Design

### 3.1 Manifest schema extension

Each plant's [`primary_answer`](../experiments/v7-refactor-recommendation/plant-manifest.yaml) block gains an optional `specifics_alternatives` field. Schema:

```yaml
plants:
  - plant_id: "3.2"
    primary_answer:
      category: "default-implementation"
      specifics:
        protocol: "BlendMode (new shared protocol over the 16-case union, with displayName + blendMode requirements)"
        method: "displayName: String { get }"
        target_location: "Shared/Wallpaper/Sources/Wallpaper/Core/BlendMode.swift (extension on BlendMode)"
      specifics_alternatives:
        protocol:
          - "BlendModeConvertible"
        method:
          - "blendMode: BlendMode { get }"
        # target_location: omitted — no blessed alternatives for this key
      specifics_alternatives_rationale:
        protocol:
          - "Same shared protocol over the 16 blend-mode cases with the same displayName + blendMode requirements; -Convertible suffix is a stylistic naming variant."
        method:
          - "Same accessor surface (gettable property returning the case's BlendMode); spelled as the type-erased getter rather than the displayName-as-key form."
        # target_location: omitted (no alternatives for this key)
```

Semantics:
- Each `specifics_alternatives` key is optional; if absent, the auto-scorer falls through to the existing verbatim-match behavior on that key.
- Each key's value is a list of up to 3 strings.
- Strings must NOT duplicate the canonical `primary_answer.specifics[key]` value.
- Strings must NOT duplicate each other within a list.
- `specifics_alternatives_rationale` is a sibling field with the same key set as `specifics_alternatives`. For each key, `len(rationale[key]) == len(alternatives[key])`: one rationale string per alternative, in the same order. The rationale is preserved in the manifest for auditability; it is NOT consumed by the auto-scorer (see §3.2.1).

### 3.2 Curation rule (pre-registered)

Each blessed alternative MUST satisfy three criteria, checked at curation time and validated in PR review:

**(a) Structural equivalence.** The alternative refers to the same refactor at the same scope as the canonical value. For a `protocol` key: both names point at the same proposed shared abstraction, with the same field requirements. For a `target_package` key: both names point at the same package or two packages that are equivalent under SPM-target semantics. For a `target_location` key: both paths point at the same package-relative location (modulo file-name variation).

**(b) Type-shape equivalence.** The alternative matches the schema's expected kind:
- Keys naming a protocol (`protocol`) → alternatives must be type names that *would be* protocols, not classes or structs.
- Keys naming a function (`target_function`, `new_helper_name`) → alternatives must be function names.
- Keys naming a package (`target_package`) → alternatives must be SPM target identifiers.
- Keys naming a path (`target_location`) → alternatives must be paths.
- Keys naming a type (`type_name`) → alternatives must be type names (could be class, struct, enum, or actor; the canonical's kind is preserved).

**(c) Curation-time blindness to agent outputs.** Alternatives are derived from the **plant author's manifest reasoning at manifest-creation time**, NOT from agent outputs in the v1-clean corpus. A blessed alternative is what a domain-expert reviewer would judge equivalent if hand-evaluating each canonical value WITHOUT having seen any specific agent recommendation. The curator's reasoning must be defensible without referencing `trial-logs-v1-clean/`.

In practice, criterion (c) means the curation pass works from `plant-manifest.yaml` + the WXYC source tree + the plant author's notes. The curator may also consult [`results.md §10.7`](../experiments/v7-refactor-recommendation/results.md#107-follow-up-h0b-sub-experiment-recommendation) for the named examples (Plant 3.2, Plant 3.3) since those are already in the public sub-experiment record; but the agent-emitted values across the full corpus stay isolated.

To enforce (c) operationally: PR 2 (curation pass) does NOT read `trial-logs-v1-clean/` files. The PR diff is the manifest-only change; trial logs are not opened.

Cap: ≤ 3 alternatives per (plant, key). Forces curation discipline; reduces the surface area where the curator could over-extend.

### 3.2.1 Curation review rubric

PR 2's reviewer applies the three criteria as a structured checklist, one row per blessed alternative. The rubric lives at [`experiments/v7-refactor-recommendation/h0b-curation-rubric.md`](../experiments/v7-refactor-recommendation/h0b-curation-rubric.md), drafted in PR 1 alongside the schema. Per-alternative checklist:

| Criterion | Question the reviewer answers |
|---|---|
| (a) Structural equivalence | Does the alternative point at the same proposed refactor at the same scope as the canonical? For protocol/type-name keys: do both names refer to the same proposed shared abstraction with the same field requirements / member set? For path/package keys: do both point at the same SPM target or equivalent SPM targets? |
| (b) Type-shape equivalence | Does the alternative match the schema's expected kind per §3.2(b)? (`protocol` → protocol-style type name; `target_function` / `new_helper_name` → function name; `target_package` → SPM target identifier; `target_location` → path string with the right shape; `type_name` → type name preserving the canonical's kind: class/struct/enum/actor.) |
| (c) Curation-time blindness | Is the rationale derived from manifest + source tree, NOT from agent outputs? Could a reader of the rationale tell the difference between "the curator inferred this from manifest reasoning" and "the curator backed into this from looking at agent values"? If the latter, reject. |

Sample rejection templates the reviewer can paste into PR comments:

- **Reject (a)**: "Alternative `<value>` for key `<key>` on Plant `<id>`: not structurally equivalent. <Canonical>'s field requirements are <X>; <alternative>'s would be <Y>. Recommend dropping or replacing."
- **Reject (b)**: "Alternative `<value>` for key `<key>` on Plant `<id>`: type-shape mismatch. Key expects <kind>; alternative is <kind>. Recommend dropping."
- **Reject (c)**: "Alternative `<value>` for key `<key>` on Plant `<id>`: the curation rationale references agent behavior or a specific trial output. Recommend re-deriving the alternative from manifest + source tree only, or dropping if no manifest-grounded justification exists."

Each blessed alternative in the PR 2 manifest diff carries a one-sentence rationale in a sibling field `specifics_alternatives_rationale[key][i]`, explaining the structural-equivalence claim WITHOUT referencing agent values. The rationale field is part of the schema (added in PR 1) so it's machine-checkable: validator enforces `len(rationale[key]) == len(alternatives[key])`. The rationale strings are preserved in the manifest for auditability; they are NOT consumed by the auto-scorer.

### 3.2.2 Operational constraint: 17-plant scope

The curation pass touches exactly the 17 panel-routed plants enumerated in §3.3. PR 2's reviewer runs a pre-flight script that diffs the manifest against the round-3 tip and confirms (a) no plant_id outside the 17 has a `specifics_alternatives` block, (b) no canonical `specifics`/`primary_answer` values were edited, (c) the diff contains only the new field + rationale entries. Pre-flight script lives at [`scripts/check_h0b_curation_scope.py`](../scripts/check_h0b_curation_scope.py), drafted in PR 1.

### 3.3 Curation scope: 17 plants, 40 panel-routed (plant, key) pairs, cap ≤ 3 alternatives = ≤ 120 alternative slots

The 17 plants that surfaced panel-routed rows in the round-2/round-3 corpus are the focus. Per the distinct `plant_id` set in [`analyses-v1-clean/panel-routing.jsonl`](../experiments/v7-refactor-recommendation/analyses-v1-clean/panel-routing.jsonl), these are:

- **default-implementation** (4 plants): Plant 3.1, 3.2, 3.3, 3.4
- **protocol-inheritance** (4): Plant 2.1, 2.2, 2.3, 2.4
- **pat-introduction** (4): Plant 4.1, 4.2, 4.3, 4.4
- **generic-parameterization** (4): Plant 5.1, 5.2, 5.3, 5.4
- **extract-to-common** (1): Plant 1.1

The remaining 3 canonical plants (1.2, 1.3, 1.4) have no panel-routed rows in this corpus and need no curation. The `*R` restraint plants are out of scope by construction (they have no `primary_answer.specifics`).

**`other_routes_to_panel` floor.** Of the 119 panel-routed rows in v1-clean, **7 are `other_routes_to_panel` (all on Plant 5.1's HSBColor cluster — agent declined the taxonomy and proposed a novel action)**. These rows have no `rec_specifics` to match against alternatives, so they CANNOT be moved by H0b's loosening regardless of curation. The remaining **112 rows are `primary_match_specifics_outside_tolerance`** and are H0b's addressable subset. Curation of Plant 5.1 alternatives is therefore methodologically inert (the 7 rows will continue to panel-route post-rerun); Plant 5.1 stays in scope because the curator's blindness to `trial-logs-v1-clean/` per §3.2 criterion (c) means the curator cannot pre-filter on match label, and the rubric-modifications.md round-4 entry should record all 17 plants for symmetry. §3.7 acknowledges the floor when interpreting the threshold bands.

Per-plant work: identify the required specifics keys that ever routed to panel; for each, declare up to 3 alternatives. Estimated curation time: **2–3 hours per curator for the enumeration + writeup**, plus 1–2 hours for the structural-equivalence reasoning per plant. Total budget: 3–6 hours of focused solo judgment work for a single curator; longer if a panel is used. PR 2's description records the actual elapsed time so future sub-experiments can calibrate; if the actual time substantially exceeds 6 hours, that's a signal the cap should be lowered or the curation scope split across multiple sub-experiments.

A pre-curation enumeration helper at [`scripts/h0b_panel_keys_per_plant.py`](../scripts/h0b_panel_keys_per_plant.py) (drafted in PR 1) reads [`analyses-v1-clean/panel-routing.jsonl`](../experiments/v7-refactor-recommendation/analyses-v1-clean/panel-routing.jsonl) and emits, per plant, the set of `specifics` keys that ever fired `primary_match_specifics_outside_tolerance` or `primary_match_specifics_missing_keys`. This frames the curation scope BEFORE the curator opens the manifest. The helper reads only the `match` and `notes` fields of `panel-routing.jsonl` — NOT the `rec_specifics` values — preserving criterion (c) blindness. Per-plant output: `{plant_id, panel_routed_keys: [...]}`. Total runtime: < 1s.

### 3.4 Auto-scorer change

In `auto-scorer.py::score_recommendation`, after the existing `_specifics_values_match` check fails on a given key:

```python
canonical_value = plant['primary_answer']['specifics'][key]
alternatives = (plant['primary_answer']
                     .get('specifics_alternatives', {})
                     .get(key, []))
if _value_match(rec_value, canonical_value) or rec_value in alternatives:
    matched_value = True
else:
    matched_value = False
    notes.append(f"key='{key}' manifest='{canonical_value}' "
                 f"rec='{rec_value}' (alternatives: {alternatives or 'none'})")
```

Match-label assignment: introduce one new match label, `primary_match_specifics_blessed_alternative` (scores 1.0), that fires whenever ALL required keys matched but at least one was matched via a blessed alternative rather than verbatim. Pre-existing `primary_match_full` continues to mean "all required keys matched verbatim." Both labels score 1.0; the label difference is for telemetry, not scoring. This preserves auditability — readers can tell which scored rows benefited from H0b without re-reading the manifest.

**Two-path test coverage requirement.** Regression tests for the auto-scorer change MUST cover both paths explicitly: (1) the existing `primary_match_full` path (all required keys matched verbatim, no alternatives exercised; score=1.0; not panel-routed) and (2) the new `primary_match_specifics_blessed_alternative` path (≥1 required key matched via an alternative; score=1.0; not panel-routed). A regression where one path is silently broken would degrade either H0b's headline (path 2 broken → result understates) or the prior-art canonical case (path 1 broken → result overstates). Both paths must be exercised in the test suite; PR 3's review-loop should flag any test set that covers only one.

### 3.5 Rerun: zero new agent calls

The auto-scorer is deterministic given (parsed cache, manifest, scorer revision). Running it against the existing [`trial-logs-v1-clean/parsed/`](../experiments/v7-refactor-recommendation/trial-logs-v1-clean) cache after the manifest + auto-scorer changes lands produces the new `analyses-v1-clean-rubric-loose/` outputs deterministically.

Output directory: [`experiments/v7-refactor-recommendation/analyses-v1-clean-rubric-loose/`](../experiments/v7-refactor-recommendation/analyses-v1-clean-rubric-loose), sibling to [`analyses-v1-clean/`](../experiments/v7-refactor-recommendation/analyses-v1-clean). Preserves the v1-clean control as-is for byte-comparable reproducibility.

### 3.6 Pre-registered analysis

After the auto-scorer rerun completes:

1. Compute panel-route rate per condition (S1, S2) and overall, under the loosened rubric.
2. Compute the v1-clean → v1-clean-rubric-loose panel-route rate delta per condition and overall.
3. Per-category breakdown of the delta: which categories benefited most from blessed alternatives?
4. Per-plant breakdown of the delta: which plants moved? Which didn't (suggesting their panel-routed rows are structural mismatches, not alternative-blessable)?
5. Per-key alternative usage: how many of the curated alternative slots got exercised by at least one agent rec? If most slots go unused, the curation over-extended; if most are hit, the curation was well-targeted. The output JSON pre-specifies the shape `per_key_alternative_usage: {plant_id: {key: [alt_0_count, alt_1_count, alt_2_count]}}` (zero-padded to the actual list length per key), produced by the auto-scorer rerun. Aggregate counts (`alternatives_offered`, `alternatives_exercised_at_least_once`) appear at the top level for headline reporting.
6. **Acceptance check**: overall panel-route rate drops by ≥ 50% (relative).

### 3.7 Decision tree

| Acceptance | Conclusion |
|---|---|
| Drop ≥ 50% (rel) | **H0b supported**: rubric over-strictness was the dominant cause of round-2's panel-route load. Recommend promoting the `specifics_alternatives` extension to default auto-scorer behavior. The H0a finding from round-3 is *refined*: capability ceiling is real but bounded; the headline panel-route load was overstated by ~50%. |
| 20% ≤ Drop < 50% (rel) | **H0b partial**: rubric over-strictness contributes but isn't dominant. Both H0a (model capability ceiling on remaining 50–80% of panel routes) and H0b (rubric over-strictness on the loosened-blessable 20–50%) are simultaneously true. Auto-scoring has a structural ceiling that more aggressive loosening (a follow-up sub-experiment) might or might not address. |
| Drop < 20% (rel) | **H0b not supported**: panel-route load is not primarily about lexically-different-but-structurally-equivalent identifiers. The round-3 H0a reading stands as the dominant explanation. Rubric loosening has small marginal value. |

The threshold structure mirrors round-3's: 50% headline, decision tree explicit about partial-support and null-result cases.

**Addressable-row floor in threshold interpretation.** The relative-drop denominator is the full v1-clean panel-route rate (119/522 = 22.80%). Per §3.3, 7 of those 119 rows are `other_routes_to_panel` and cannot be moved by `specifics_alternatives` — H0b's mechanism only fires on `primary_match_specifics_outside_tolerance` rows. So the maximum possible relative drop is (119 − 7) / 119 = **94.1%**, not 100%. At the threshold cliff: a 50% drop of *addressable* rows (56 of 112) corresponds to a **47.1% drop of total** (56 of 119), landing 2.9pp below the H0b-supported band. The §11 writeup MUST report (a) the headline relative drop against the full 119 denominator (what the §3.7 bands gate on), AND (b) the addressable relative drop against the 112 denominator (the subset H0b could mechanically move). Both numbers travel together; the headline decision uses (a), and (b) characterizes how close H0b came to its ceiling on the rows it could actually affect.

**Per-category anomaly handling.** If H0b is supported overall (≥ 50% drop in aggregate) but one or more categories show *flat* or *increased* panel-route rate while others drop ≥ 50%, the §11 writeup MUST surface this as a per-category caveat. The leading candidate for such an anomaly is `pat-introduction`, which moved against H1 in round-3 (+28.6% relative under v2 vs v1-clean per [`results.md §10.5`](../experiments/v7-refactor-recommendation/results.md#105-per-category-panel-route-delta)); if it also fails to respond to H0b's loosening, that suggests PAT mismatches are structurally different from the identifier-equivalence pattern (e.g., they're about template applicability or applies-to scope, not naming). The §11 writeup should call out any such anomaly explicitly and recommend a follow-up sub-experiment scoped to the anomalous categories if the structural difference is methodologically important.

### 3.8 Baseline invariance to panel completion

The acceptance metric is panel-route rate, not canonical_recall. As in round-3, panel-route rate is determined by the auto-scorer's match-label classification alone and is invariant under [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) / [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94) panel completion. The H0b decision can proceed in parallel with recruitment and finalization.

The `results.md §11` writeup's canonical-recall delta is a secondary descriptive number that updates once #94 closes; the H0b decision itself does not wait.

## 4. Pre-registration

Frozen before the auto-scorer rerun:

- The `specifics_alternatives` schema extension (§3.1)
- The curation rule with three criteria (§3.2)
- The 3-alternative cap per (plant, key) (§3.2)
- The acceptance threshold (50% / 20% bands) (§3.7)
- The decision tree (§3.7)
- The specific 17-plant curation scope (§3.3)
- PR 2's "diff is manifest-only, no `trial-logs-v1-clean/` reads" constraint (§3.2 criterion c)

Pre-registration document: this plan + [`rubric-modifications.md`](../experiments/v7-refactor-recommendation/rubric-modifications.md) round-4 entry referencing this plan + [`reproducibility.yaml`](../experiments/v7-refactor-recommendation/reproducibility.yaml) round-4 block.

**When the round-4 entries are created**: PR 1 (schema + validator + curation rubric + pre-flight scripts) opens with a commit that adds the `## Round 4 — H0b rubric loosening (2026-05-21)` block to `rubric-modifications.md` AND the `execution.h0b_sub_experiment` block to `reproducibility.yaml`. Both blocks include: a permalink to this plan at its merged SHA, the curation rule, the cap, the acceptance threshold, and the decision tree. The PR 1 commit message MUST include the permalink to this plan at its merged SHA (`plans/v7-h0b-rubric-loosening-plan.md` at the SHA the plan-PR lands at, in the form `https://github.com/jakebromberg/code-audit-pipeline/blob/<sha>/plans/v7-h0b-rubric-loosening-plan.md`) for audit traceability. These blocks freeze the pre-registered parameters before PR 2's curation pass runs.

## 5. Acceptance criteria

- [ ] `specifics_alternatives` and `specifics_alternatives_rationale` schemas added to [`plant-manifest.yaml`](../experiments/v7-refactor-recommendation/plant-manifest.yaml), [`validate-manifest.py`](../experiments/v7-refactor-recommendation/validate-manifest.py), and the manifest's per-plant YAML linter; validator rejects ≥ 4 entries per list, duplicates within a list, duplicates of the canonical value, and any rationale-list length mismatch (`len(rationale[key]) == len(alternatives[key])` enforced per key).
- [ ] [`experiments/v7-refactor-recommendation/h0b-curation-rubric.md`](../experiments/v7-refactor-recommendation/h0b-curation-rubric.md) drafted in PR 1 with the three-criteria checklist + sample rejection templates from §3.2.1; referenced from PR 2's description.
- [ ] Pre-flight scripts drafted in PR 1: [`scripts/h0b_panel_keys_per_plant.py`](../scripts/h0b_panel_keys_per_plant.py) (enumerates which `specifics` keys per plant ever routed to panel; reads only `match`/`notes` fields per §3.3 criterion (c)); [`scripts/check_h0b_curation_scope.py`](../scripts/check_h0b_curation_scope.py) (verifies PR 2's diff touches only the 17 panel-routed plants and adds only `specifics_alternatives` / `specifics_alternatives_rationale` fields, no canonical edits).
- [ ] Curation pass: alternatives declared for the 17 panel-routed plants, ≤ 3 per (plant, key); per-alternative rationale strings (one sentence, manifest-grounded, no agent-output references); diff is manifest-only (no `trial-logs-v1-clean/` reads in PR 2).
- [ ] **Pre-flight gate (PR 2 merge-blocker)**: `python3 scripts/check_h0b_curation_scope.py` exits 0 against PR 2's branch tip; PR 2's description includes the script's stdout (a) confirming the diff touches only the 17 panel-routed plants, (b) confirming no canonical `primary_answer.specifics` values were edited, (c) confirming only `specifics_alternatives` and `specifics_alternatives_rationale` fields were added. A non-zero exit blocks PR 2 merge; the curator iterates until the script passes.
- [ ] Curation review: a designated reviewer (NOT the plant author for PR 2) validates each blessed alternative against the §3.2.1 rubric (three rows of the checklist per alternative); rejection templates used for any failures; no alternative violates structural equivalence, type-shape equivalence, or curation-time blindness; PR 2's description records (a) curator's identity, (b) reviewer's identity, (c) actual elapsed curation time.
- [ ] [`auto-scorer.py`](../experiments/v7-refactor-recommendation/auto-scorer.py) supports the new match path; new match label `primary_match_specifics_blessed_alternative` added (scores 1.0); validator rejects malformed alternatives; validator rejects rationale-length mismatch.
- [ ] **Two-path test coverage (per §3.4)** — regression tests cover both auto-scorer paths under explicitly-named test cases. PR 3's review-loop verifies the following are present and passing:
  - `test_primary_match_full_all_keys_verbatim` — existing path: all required keys matched verbatim, no `specifics_alternatives` consulted; expect score=1.0, match=`primary_match_full`, NOT panel-routed.
  - `test_primary_match_specifics_blessed_alternative_single_key` — new path: one required key matches via a blessed alternative, other keys verbatim; expect score=1.0, match=`primary_match_specifics_blessed_alternative`, NOT panel-routed.
  - `test_primary_match_specifics_blessed_alternative_all_keys_via_alternative` — new path: all required keys match via blessed alternatives; expect score=1.0, match=`primary_match_specifics_blessed_alternative`, NOT panel-routed.
  - `test_primary_match_specifics_outside_tolerance_no_blessed_match` — neither verbatim nor alternative matches; expect score=panel_route, match=`primary_match_specifics_outside_tolerance`, panel-routed.
  - `test_empty_specifics_alternatives_falls_through_verbatim` — plant has no `specifics_alternatives` field; expect verbatim-only behavior preserved (no regression of pre-H0b plants).
  - `test_validator_rejects_oversized_alternative_list` — validator fails when `len(specifics_alternatives[key]) > 3`.
  - `test_validator_rejects_canonical_duplicate_in_alternatives` — validator fails when a blessed alternative duplicates the canonical `primary_answer.specifics[key]` value.
  - `test_validator_rejects_rationale_length_mismatch` — validator fails when `len(specifics_alternatives_rationale[key]) != len(specifics_alternatives[key])`.
- [ ] Auto-scorer rerun against [`trial-logs-v1-clean/parsed/`](../experiments/v7-refactor-recommendation/trial-logs-v1-clean) produces [`analyses-v1-clean-rubric-loose/`](../experiments/v7-refactor-recommendation/analyses-v1-clean-rubric-loose) (4 files: `auto-scores.json`, `score-summary.json`, `panel-routing.jsonl`, `panel-unblind.json`).
- [ ] [`analyses-v2/h0b-rubric-loosening.json`](../experiments/v7-refactor-recommendation/analyses-v2/h0b-rubric-loosening.json) documents v1-clean vs v1-clean-rubric-loose panel-route rates per condition + per category + per plant + per-key alternative usage (per §3.6 step 5 schema: `per_key_alternative_usage: {plant_id: {key: [counts...]}}` plus aggregate `alternatives_offered` / `alternatives_exercised_at_least_once`).
- [ ] `results.md §11` reports H0b outcome; per-category panel-route delta table; per-plant delta table; canonical-recall delta with panel-pending caveat; aggregate alternative-usage summary; **both denominators** per §3.7 — headline relative drop against the full 119 v1-clean panel-route count AND addressable relative drop against the 112 `primary_match_specifics_outside_tolerance` subset.
- [ ] [`rubric-modifications.md`](../experiments/v7-refactor-recommendation/rubric-modifications.md) round-4 entry filed (methodology §10 compliance), with measured outcome appended after PR 4.
- [ ] [`reproducibility.yaml::execution.h0b_sub_experiment.sub_experiment_outcome`](../experiments/v7-refactor-recommendation/reproducibility.yaml) populated: "H0b supported" | "H0b partial" | "H0b not supported".
- [ ] PR 1 commit message includes a permalink to this plan at the merged SHA per §4 traceability requirement.

## 6. Implementation plan

Sequential PRs against `experiment/swift-substrate` (the same long-running feature branch the round-2 and round-3 sub-experiments landed on; consistent with [PR #99](https://github.com/jakebromberg/code-audit-pipeline/pull/99) through [PR #106](https://github.com/jakebromberg/code-audit-pipeline/pull/106)'s convention):

| PR | Scope | Cost | Wallclock |
|---|---|---|---|
| 1 | `specifics_alternatives` + `specifics_alternatives_rationale` schema + validator + pre-registration block in `rubric-modifications.md` round-4 + `reproducibility.yaml` round-4 block + plan-link in commit message + curation rubric doc (§3.2.1) + pre-flight scripts (§3.2.2 / §3.3) | $0 | 1–2 days |
| 2 | Curation pass: alternatives + rationale declared for the 17 panel-routed plants per §3.2 criteria; pre-flight script verifies scope; reviewer validates per §3.2.1 rubric; diff is manifest-only (no `trial-logs-v1-clean/` reads) | $0 | 2–3 days |
| 3 | `auto-scorer.py` change with both-path regression tests per §3.4 + rerun against the v1-clean corpus → `analyses-v1-clean-rubric-loose/` (only if PR 2's curation review passes) | $0 | 1–2 days |
| 4 | `analyses-v2/h0b-rubric-loosening.json` (with §3.6 per-key usage schema) + `results.md §11` + `rubric-modifications.md` round-4 outcome entry + `reproducibility.yaml` `h0b_sub_experiment.sub_experiment_outcome` update | $0 | 2–3 days |

Total: ~1.5 weeks wallclock, **$0 API spend** (no new agent calls). Well under [methodology §16](../docs/refactor-recommendation-experiment-methodology.md#16-minimum-viable-round)'s $50–110 envelope; this sub-experiment is a pure scoring re-run.

**Parallel with**: [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) (recruitment), [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94) (finalization). No human-time dependencies on this sub-experiment; H0b reduces panel-route count and can only help (or not change) the panel queue.

## 7. Risks

1. **Curation bias (cherry-picking).** Risk that the curator blesses alternatives to maximize panel-route drop, including alternatives a domain expert would reject. Mitigation: pre-registered three-criteria rule; PR 2's reviewer validation; cap of 3 alternatives per (plant, key); PR 2's diff-is-manifest-only constraint prevents the curator from reading `trial-logs-v1-clean/` outputs during curation.

2. **Curation-time leak of agent outputs.** Risk that the curator memorized agent outputs from earlier round-3 work and unconsciously declares alternatives matching those outputs. Mitigation: pre-registered curation criterion (c) (curation-time blindness); the curator's notes should reference manifest reasoning + source tree, NOT agent outputs. If the reviewer can identify an alternative that "looks like the agent's output and not like a domain-expert reading," it gets rejected.

3. **Reviewer-and-curator overlap.** If the plant author and the curation reviewer are the same person, criterion (c)'s blindness check is weakened. Mitigation: PR 2 review delegated to a distinct reviewer; PR description names the reviewer; if the project has only one person available, a structured curation log (write down the manifest-grounded reasoning per alternative BEFORE seeing the trial corpus) substitutes for inter-rater blindness.

4. **3-alternative cap too low (or too high).** If 3 is too few, some real structural equivalences go unblessed and the experiment understates rubric over-strictness. If 3 is too high, the curator over-extends and the experiment overstates the result. Mitigation: 3 is a deliberate balance based on the round-3 panel-routing notes; the per-key usage telemetry in §3.6 step 5 will show whether the cap was reached. If most plants use all 3 slots, follow-up sub-experiment can rerun with a higher cap.

5. **Per-plant heterogeneity confounds interpretation.** If H0b drops panel-route on default-implementation by 70% but on extract-to-common by 5%, the headline "H0b supported" hides per-category nuance. Mitigation: per-category and per-plant breakdown is in §3.6 step 3-4; `results.md §11` reports both the headline and the breakdown.

6. **Threshold gaming.** The 50% threshold is the same as round-3's. If the actual delta is 49% or 51%, the headline conclusion flips on a hair. Mitigation: report the actual delta regardless of threshold; characterize partial-support and null-result interpretations explicitly per §3.7's decision tree. Threshold gates the headline interpretation, not the report.

7. **Methodological pollution from round-3 trigger response.** This sub-experiment was *recommended* by round-3's writeup. There's a risk that the framing already presumes H0b is partly true ("the round-3 per-category breakdown suggests several mismatches that route to panel are structurally equivalent but lexically different — exactly the H0b symptom"). Mitigation: criterion (c) curation-time blindness; PR 2's reviewer validation; the pre-registered decision tree (§3.7) admits both H0b-supported and H0b-not-supported outcomes as valid reportable results.

## 8. Open questions

(For `/review-plan` input, before PR 1 opens.)

1. **Curation reviewer selection.** Should curation review use a single reviewer or a panel? Single is faster; panel guards against bias. Default: single reviewer for cost; document the reviewer's identity in PR 2.

2. **Per-key alternative cap.** Is 3 the right number? Lower (1–2) constrains; higher (5–10) admits noise. Default: 3, per §3.2.

3. **Blind vs by-plant curation order.** Should the curator work plant-by-plant (in plant_id order) or in shuffled order to reduce ordering bias? Default: by plant_id for traceability; shuffling adds operational overhead without clear methodological gain at N=17.

4. **Treatment of `pat-introduction` plants.** Round-3's per-category breakdown showed pat-introduction went *up* (+28.6% rel) under v2. Is H0b expected to help here, or are the PAT mismatches structurally different from default-implementation's "BlendModeConvertible"-style ones? Default: include all 4 pat-introduction plants (4.1, 4.2, 4.3, 4.4) in the curation scope (per §3.3); the per-category breakdown in §3.6 step 3 will surface whether H0b moves PAT panel-route or not.

5. **Round-2 corpus comparison.** Should this also score the round-2 original-substrate corpus (in [`analyses/`](../experiments/v7-refactor-recommendation/analyses)) as a parallel control? Default: no — the matched-substrate v1-clean is the established round-3 control; round-2 stays as historical snapshot. If the result is ambiguous, a follow-up could rerun against round-2.

6. **What if curation pass yields fewer than expected alternatives?** If the curator finds only ~30 alternatives total (instead of the ~120 upper bound the 3-cap allows across the 40 panel-routed (plant, key) pairs counted in §3.3), is the cap structurally meaningful or just symbolic? Default: report the actual alternative count in PR 2's review; if substantially below cap, document in §11 writeup as "curation was conservative, not cap-limited."

7. **Promotion path on H0b-supported.** If H0b is supported, does the `specifics_alternatives` extension become default auto-scorer behavior for round 5+, OR does it stay as a scenario-flag? Default: promote to default if H0b ≥ 50% drop; leave as scenario-flag if H0b partial. Recorded as a §11 writeup recommendation, not pre-bound.

## Related

- [`results.md §10`](../experiments/v7-refactor-recommendation/results.md#10-prompt-sensitivity-sub-experiment-round-3--h0a-supported) — round-3 prompt-sensitivity sub-experiment (H0a supported); §10.7 names H0b as the recommended follow-up.
- [`results.md §10.5`](../experiments/v7-refactor-recommendation/results.md#105-per-category-panel-route-delta) — per-category breakdown that surfaces the H0b symptoms (default-implementation Plant 3.2 / 3.3 examples).
- [`plans/v7-round2-prompt-sensitivity-plan.md §1`](v7-round2-prompt-sensitivity-plan.md#1-context-and-motivation) — original three-hypothesis framing where H0b was first pre-registered as out-of-scope-for-round-3.
- [`experiments/v7-refactor-recommendation/rubric-modifications.md`](../experiments/v7-refactor-recommendation/rubric-modifications.md) round-2 value-aware-specifics entry — the change ([PR #90](https://github.com/jakebromberg/code-audit-pipeline/pull/90)) that introduced verbatim-match scoring and produced the panel-route load this sub-experiment investigates.
- [`experiments/v7-refactor-recommendation/glossary.md`](../experiments/v7-refactor-recommendation/glossary.md) — shared V7 vocabulary (the H0b discussion uses `panel-route rate`, `primary_match_specifics_outside_tolerance`, `value-aware specifics matching`, `binding`, etc. all defined there).
- [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) — V7 round-2 recruitment (parallel work, not a blocker).
- [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94) — V7 round-2 finalization (parallel work, not a blocker).
- [#107](https://github.com/jakebromberg/code-audit-pipeline/issues/107) — 2026-05-21 triage tracker; the H0b sub-experiment is recommended there as the natural next experimental move.
