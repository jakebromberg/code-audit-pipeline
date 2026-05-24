# H0b curation rubric — blessing `specifics_alternatives`

Companion to [`plans/v7-h0b-rubric-loosening-plan.md`](../../plans/v7-h0b-rubric-loosening-plan.md) §3.2 / §3.2.1. The curator (PR 2 author) and the curation reviewer (a designated reader who is NOT the plant author) apply this rubric to every proposed alternative before merging PR 2.

The rubric exists because [H0b's experimental validity](../../plans/v7-h0b-rubric-loosening-plan.md#1-context-and-motivation) depends on `specifics_alternatives` being pre-blessed under a published rule, not curated to match observed agent outputs. The three criteria below are pre-registered in the [round-4 entry of `rubric-modifications.md`](rubric-modifications.md) and frozen by PR 1 merge. PR 2's diff is constrained to the manifest; auto-scorer changes belong to PR 3.

## How to use this rubric

1. Run [`scripts/h0b_panel_keys_per_plant.py`](../../scripts/h0b_panel_keys_per_plant.py) to enumerate `(plant_id, key)` combinations in scope. The script reads only `match_reason` and `notes[key='<name>']` substrings — it elides every agent-emitted value, preserving criterion (c) blindness.
2. For each `(plant_id, key)` the script lists, the curator reads the manifest's canonical `primary_answer.specifics[key]` and proposes up to **3** alternative values for that key. Empty lists are also valid — declaring no alternatives for a key means H0b's loosening rule will not kick in for that key, and the existing verbatim-match path stands. A list of zero alternatives is preferable to a list of weak alternatives.
3. For each proposed alternative, the curator writes a single-sentence `specifics_alternatives_rationale` entry (one per alternative, same-index list) grounded ONLY in the manifest and the source repository — no references to trial-logs or agent outputs.
4. The curator runs [`scripts/check_h0b_curation_scope.py`](../../scripts/check_h0b_curation_scope.py) before opening PR 2. The script must exit 0; its stdout pasted into the PR 2 description satisfies the plan §5 acceptance checklist.
5. The reviewer (NOT the plant author for the affected plant) applies this rubric to each proposed alternative independently, ticking each of the three checkbox rows in §1 below. Any row that fails for any alternative blocks the PR; the curator removes or revises the offending entry and the reviewer re-applies.

## 1. Three-criteria checklist (per proposed alternative)

For every `(plant_id, key, alternative_value)` triple in the diff, the reviewer answers all three of the following as **Pass** or **Fail**:

### Criterion (a) — structural equivalence

Does the alternative value refer to the **same structural refactor** as the canonical `primary_answer.specifics[key]` value?

- Same number of conformers (for `protocol-inheritance` / `default-implementation` plants), same set of replaced symbols (for `generic-parameterization`), same target package (for `extract-to-common`), or same template surface (for `pat-introduction`).
- The alternative may differ in *naming* (canonical: `BlendMode`; alternative: `BlendModeConvertible`), in *member ordering* (canonical: `[fetchInt, fetchString]`; alternative: `[fetchString, fetchInt]`), or in *commentary parentheses* (canonical: `BlendMode (new shared protocol over the 16-case union)`; alternative: `BlendMode`).
- The alternative may NOT introduce or remove a conformer, replace a different target type, or scope to a different package than the canonical answer's intent.

The reviewer reads ONLY the manifest (`primary_answer.specifics[key]` and `rationale_must_cite`, plus the plant's `source_files`) to judge structural equivalence. No reference to `trial-logs-v1-clean/` cache, `panel-routing.jsonl`, or any other artifact that contains agent outputs.

### Criterion (b) — type-shape equivalence

Does the alternative match the **type shape** the rubric's `specifics_schemas[category]` requires for this key, at BOTH the YAML level and the semantic level?

**YAML-level shape** (the auto-scorer's `_values_structurally_equal` enforces this):

- If the canonical value for `key` is a **string**, the alternative is also a string.
- If the canonical value is a **list of strings**, the alternative is also a list of strings of the same length (member ordering may differ; the helper compares lists as multisets).
- If the canonical value is a **list of dicts** (e.g., `type_params: [{name, constraint}]`), the alternative is a list of dicts with the same keys, with allowed value variation within keys per criterion (a).
- YAML-level mismatches (canonical: string; alternative: list) are immediate Fail — the auto-scorer's helper does not coerce types, and a type-mismatched alternative would never trigger.

**Semantic-level shape** (per plan §3.2.1 table):

| Key family | Expected shape |
|---|---|
| `protocol` | protocol-style type name (UpperCamelCase, "able"/"ing"/-suffix-Convertible variants OK) |
| `target_function`, `new_helper_name`, `new_name` | function name (lowerCamelCase preferred; SPM target prefix may be added/removed) |
| `target_package` | SPM target identifier (`Shared/Wallpaper`, `Shared/Core`, etc.) |
| `target_location` | filesystem path with the right extension and the right SPM-target prefix |
| `type_name` | type name preserving the canonical's kind (class/struct/enum/actor — don't substitute kinds) |
| `replaces`, `moved_members`, `conformers_simplified` | list of symbol names; member ordering may differ but the set's cardinality must match the canonical |
| `new_protocol`, `parent`, `children` | protocol-style or type-style names depending on the category's schema |
| `method` | method/property accessor name with the canonical's getter/setter shape preserved |

### Criterion (c) — curation-time blindness

Did the curator avoid reading agent outputs while selecting this alternative?

- No reference to `trial-logs-v1-clean/raw/*.jsonl`, `trial-logs-v1-clean/parsed/`, `analyses-v1-clean/auto-scores.json`, `analyses-v1-clean/panel-routing.jsonl`, `analyses-v1-clean/panel-unblind.json`, or any per-rec content from those files in:
  - PR 2's commit messages,
  - PR 2's branch history (`git log --all` from the curator's branch tip),
  - The `specifics_alternatives_rationale` strings,
  - Any code comment in the diff.
- [`scripts/h0b_panel_keys_per_plant.py`](../../scripts/h0b_panel_keys_per_plant.py)'s text/JSON output is admissible because by construction it elides agent values (see plan §3.3 + script docstring). Running it does not violate (c).
- The reviewer spot-checks the curator's branch history with `git log <curator-branch> --all --oneline` looking for any commit touching a non-manifest path; if found, the diff fails (a) (and is then blocked by [`scripts/check_h0b_curation_scope.py`](../../scripts/check_h0b_curation_scope.py)) AND surfaces a (c) concern about what informed the curation choices.

A Pass on (c) is necessarily probabilistic — the rubric cannot prove the curator didn't read trial-logs in another tab. The mitigation is documenting the curator's process in the PR 2 description (which files they read, in what order) so the reviewer can sanity-check.

## 2. Rejection templates

Use these templates when rejecting an alternative. Each template names the violated criterion + a concrete artifact in the diff.

### Template R-a (criterion (a) — structural divergence)

> Rejecting `plant {plant_id}.{key}.specifics_alternatives[{index}] = {value!r}`. Criterion (a) fails: the alternative refers to {brief structural difference, e.g., "a different target package than the canonical Shared/UI"}. The canonical `primary_answer.specifics[{key}] = {canonical!r}` names {what the canonical points to}. Per the rubric, alternatives may differ in naming or ordering but not in the structural refactor being recommended.

### Template R-b (criterion (b) — type-shape mismatch)

> Rejecting `plant {plant_id}.{key}.specifics_alternatives[{index}] = {value!r}`. Criterion (b) fails: the alternative is a {observed type} but the canonical `primary_answer.specifics[{key}]` is a {expected type}. The auto-scorer's `_specifics_values_match` helper compares types strictly; a type-mismatched alternative would never trigger.

### Template R-c (criterion (c) — curation-time blindness compromised)

> Rejecting `plant {plant_id}.{key}.specifics_alternatives[{index}] = {value!r}`. Criterion (c) is in doubt: the alternative reads as a paraphrase of an agent emission rather than a manifest-grounded blessing. Reasoning: {observed evidence, e.g., "the rationale string quotes a phrase that appears in `panel-routing.jsonl::rec_rationale`", or "the curator's branch history shows a commit reading `trial-logs-v1-clean/`"}. Curator: please remove this alternative and rewrite based on the canonical specifics + manifest rationale only.

### Template R-cap (cardinality cap exceeded)

> Rejecting `plant {plant_id}.{key}.specifics_alternatives` (length {n}). The 3-alternative cap is pre-registered in plan §3.1 and §3.2; lists with more than 3 entries are validator-rejected (rule 12). Trim to the 3 strongest alternatives.

### Template R-dup-canonical (canonical value duplicated in alternatives)

> Rejecting `plant {plant_id}.{key}.specifics_alternatives[{index}] = {value!r}`. The entry exactly matches the canonical `primary_answer.specifics[{key}]`. Verbatim matches against the canonical are scored by the existing primary-match path; duplicating them as a blessed alternative inflates the apparent alternative-usage count without changing scoring. Validator rule 12 rejects this case.

### Template R-rationale-length (rationale list length mismatch)

> Rejecting `plant {plant_id}.{key}` — `specifics_alternatives` has {m} entries but `specifics_alternatives_rationale` has {n}. Per plan §3.1 and validator rule 12, every alternative must carry exactly one rationale string at the same index. Either add the missing rationale(s) or drop the unrationalized alternative(s).

## 3. Worked example

The plan's motivating example is Plant 3.2's `protocol` key.

- Plant 3.2's canonical `primary_answer.specifics.protocol = "BlendMode (new shared protocol over the 16-case union, with displayName + blendMode requirements)"`.
- Round-2/3's panel routings under match label `primary_match_specifics_outside_tolerance` consistently surface mismatches where the agent named the protocol differently (an example documented in [`results.md §10.5`](results.md#105-per-category-panel-route-delta) without quoting agent text in this rubric to preserve (c)).
- A blessable alternative might read: `"BlendModeProtocol (new shared protocol over the 16-case union, with displayName + blendMode requirements; preserving the existing BlendMode enum type as the protocol's canonical concrete type)"`. Criterion (a): same refactor (extract a shared protocol over the 16-case union), differs in the protocol name only. Criterion (b): same type (string). Criterion (c): the rationale derives entirely from the manifest's existing canonical value plus the plant's source pair — no reference to anything in `trial-logs-v1-clean/`.

The rationale that ships alongside this alternative might read: `"Adds the conventional 'Protocol' suffix while keeping the underlying enum type preserved as the canonical concrete type; equivalent under criterion (a) because the refactor (shared protocol over the 16-case union with the same two requirements) is identical."` — a single sentence, manifest-grounded, no agent-output references.

The curator and reviewer would together decide whether to include this alternative; the rubric is a floor, not a ceiling.

## 4. Where this rubric lives in the validity argument

PR 2's curation pass is the only step in the H0b chain where human judgment enters. If the rubric is loose (admits naming variants that aren't structurally equivalent), the measured drop overstates H0b's effect. If the rubric is too tight (rejects defensible variants), the measured drop understates H0b and converges to round-3's H0a outcome.

The three-criteria checklist is the bias-against-overstating mechanism: it requires (a) structural identity (not just naming overlap), (b) type-shape identity (no coercion games), and (c) curation-time blindness (no fitting to observed agent emissions). PR 2's reviewer is the bias-against-understating mechanism: distinct from the plant author, applying the checklist independently. The combination — pre-registered rubric + two-party review + scope script — operationalizes the [methodology §10 pre-registration discipline](../../docs/refactor-recommendation-experiment-methodology.md#10-pre-registration-discipline) for this sub-experiment.

**Floor acknowledgment.** Of the 119 v1-clean panel-routed rows, 7 are `other_routes_to_panel` (all on Plant 5.1's HSBColor cluster — the agent declined the taxonomy and proposed a novel action). These rows have no `rec_specifics` to match against blessed alternatives, so they CANNOT move under H0b regardless of how careful the curation is. The addressable subset is 112 `primary_match_specifics_outside_tolerance` rows; the maximum possible relative drop against the full 119 denominator is 94.1%. Per the plan's §4 pre-registration, [`results.md §11`](results.md) will report drops against BOTH denominators (the headline 119 and the addressable 112), so the threshold decision uses the full denominator while readers can also see how close H0b came to its ceiling on the rows it could actually affect. The curator's job is unchanged by this floor — criterion (c) blindness precludes pre-filtering on match label anyway.

## See also

- [`plans/v7-h0b-rubric-loosening-plan.md`](../../plans/v7-h0b-rubric-loosening-plan.md) — the full plan; §3.2 / §3.2.1 are the canonical statements of these criteria.
- [`rubric-modifications.md`](rubric-modifications.md) — round-4 entry holds the frozen pre-registration parameters.
- [`scripts/h0b_panel_keys_per_plant.py`](../../scripts/h0b_panel_keys_per_plant.py) — pre-curation enumeration (preserves (c)).
- [`scripts/check_h0b_curation_scope.py`](../../scripts/check_h0b_curation_scope.py) — PR 2 merge-blocker.
- [`glossary.md`](glossary.md) — terminology reference.
