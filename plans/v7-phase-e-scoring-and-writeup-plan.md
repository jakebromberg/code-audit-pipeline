# V7 Refactor-Recommendation Experiment — Phase E plan

> Operationalizes [§7 Phase E](v7-refactor-recommendation-implementation-plan.md#7-phase-e--scoring--writeup-2-3-weeks) of the main implementation plan against the Phase D production trial corpus committed in [PR #72](https://github.com/jakebromberg/code-audit-pipeline/pull/72). Methodology references throughout: [`refactor-recommendation-experiment-methodology.md`](../docs/refactor-recommendation-experiment-methodology.md).

## TL;DR

Phase D shipped 2907 per-rec telemetry files + raw `/v1/messages` bodies under `experiments/v7-refactor-recommendation/trial-logs/`. Phase E turns that corpus into scored results. Splitting the work into **four sequential PRs** keeps each delta reviewable (~300–700 LOC of new code per PR) and lets the auto-scorer cache (PR-E1) unblock the analyses (PR-E2, PR-E3) without re-running the API. Plant 5.3's "declared signals didn't fire" follow-up folds into PR-E2; §6.4 sub-experiments stay deferred and become PR-E4 only if PR-E1–E3 surface a result that wants triangulation.

| PR | Scope | Deps | Approx LOC |
|---|---|---|---|
| **E1** | response-body parser + parsed-fields cache (`trial-logs/parsed/<cond>/trial<n>/<cluster>.json`) | none | ~300 |
| **E2** | §14.1 substrate-helped check + plant-recall confirm against parsed categories | E1 | ~400 |
| **E3** | full auto-scorer run, panel routing list, `results.md`, finalize `reproducibility.yaml` | E1, E2 | ~600 |
| **E4** (optional) | §6.4 sub-experiments (natural-findings, prompt-sensitivity, model-sensitivity) | E3 | TBD |

**Budget: $0 API spend** for E1–E3 (everything walks committed `raw_response_path` bodies). E4 only if greenlit, scoped to the methodology §16 sub-experiment envelope (~$50–110).

**Wallclock: 2–3 weeks** for E1–E3 in series, including the panel sitting (3 reviewers × ~4 hrs each, blind to condition, per the methodology §17 decision #3 default the main plan already adopts).

## What's already in place vs. what this plan adds

Already in the repo (no new infrastructure needed):

- `experiments/v7-refactor-recommendation/auto-scorer.py` — implements the methodology §8 decision rule for a single parsed recommendation. Takes a recommendation dict + plant manifest entry, returns a score in `{-0.5, 0.0, 0.3, 0.5, 0.7, 1.0}` or the `panel_route` sentinel. **Already covers the §20.1–20.5 worked examples per its own dry-run.** What's missing: a bulk runner that walks 2907 recs.
- `experiments/v7-refactor-recommendation/rubric.yaml` + `plant-manifest.yaml` — frozen at pre-registration, hashes pinned in `reproducibility.yaml`. Do not modify in Phase E (per methodology §10 reproducibility, any modification logs to `rubric-modifications.md`).
- `scripts/harness/extract.py` — fence-aware JSON-array extraction from a model response. Used by the harness for `error_class` classification but **not re-used for full parsing**; PR-E1 lifts/extends it.
- 2907 raw response bodies under `trial-logs/raw/{s1,s2}/trial{1,2,3}/*.json` — model's reply verbatim. The auto-scorer's input shape (a single recommendation dict with `category`, `specifics`, `rationale`, `evidence_quote`) maps to `raw_body.content[0].text → fenced JSON array → array[0]`.

What this plan adds:

- A parsed-fields cache so E2/E3 (and any future audit) reads structured rows in one pass instead of re-running fence extraction.
- The §14.1 substrate-helped analysis the §6.2 harness explicitly deferred (the in-harness check self-skipped because per-rec telemetry doesn't carry confidence — Phase E walks the raw bodies for it).
- The plant-recall confirm extension that closes the Plant 5.3 gap (declared signals didn't fire; check whether the parsed categories surface it).
- The bulk auto-scorer driver + panel-routing list + results.md + the final reproducibility.yaml stamps.

## 1. PR-E1 — response-body parser + parsed-fields cache

### 1.1 Deliverable

A small extractor module at `experiments/v7-refactor-recommendation/parse_responses.py` plus a parsed-fields cache committed at `trial-logs/parsed/<cond>/trial<n>/<sanitized-cluster-id>.json`. One parsed file per existing raw file (2905 successes; the 2 `json-parse-error` rows get a stub with `parse_error: true`).

Per-parsed-rec schema:

```json
{
  "cluster_id": "<verbatim from telemetry>",
  "condition": "s1|s2",
  "trial": 1,
  "query": "pat-candidates",
  "row_index": 0,
  "raw_response_path": "raw/s2/trial1/<sanitized>.json",
  "parsed": {
    "category": "pat-introduction",
    "specifics": {"new_protocol": "Container", "associated_type": "Element"},
    "rationale": "<verbatim>",
    "evidence_quote": "<verbatim or null>",
    "confidence": 0.82
  },
  "parse_error": null,
  "extraction_notes": {
    "parser_version": "1.0"
  }
}
```

`confidence` reads from `parsed.confidence` if the model emitted it; otherwise null. Methodology §8 makes confidence optional per-rec — Phase E aggregates only over the non-null subset for §14.1.

### 1.2 Acceptance

- `parse_responses.py` is idempotent: re-running over a populated cache no-ops on already-parsed rows.
- 2905/2907 rows parse to a recommendation dict; the 2 `json-parse-error` rows write a `parse_error: true` stub.
- `cluster_id` round-trips against telemetry: every parsed file's `cluster_id` matches the corresponding telemetry record's `cluster_id` field verbatim, asserted by a unit test. (Issue #5 — substrate-emitted `cluster_id` — is the upstream prerequisite per parent plan §1.1; the defensive fuzzy matcher fallback applies if issue #5 hasn't landed at E1 kickoff.)
- Unit tests at `experiments/v7-refactor-recommendation/test_parse_responses.py`, co-located with the parser (matching the project's `test_validator.py` precedent for experiment-scoped tests; the `pipeline/queries/_tests/` directory is reserved for harness and substrate tests):
  - fence extraction with and without language tag
  - well-formed single-element array → success
  - empty array → `parse_error: "wrong-array-length"`
  - array length ≠ 1 → `parse_error: "wrong-array-length"`
  - non-JSON inside fence → `parse_error: "json-parse-error"`
  - `confidence` field absent → `parsed.confidence: null` (not an error)
  - missing `specifics` map → `parse_error: "missing-required-field"` with field-name list
  - cross-condition smoke: parse 10 real recorded bodies (5 each S1, S2), assert all produce non-null `parsed.category`
- Existing test suites still pass: `python3 experiments/v7-refactor-recommendation/test_validator.py` exits 0; any tests under `scripts/harness/` that exist at E1 kickoff run green. (The exact in-tree test count is whatever the branch shows at E1 kickoff, not a number frozen in this plan.)

**Parse-error namespace alignment.** The `parse_error` discriminator values introduced here — `wrong-array-length`, `json-parse-error`, `missing-required-field` — are a superset that intentionally aligns with `scripts/harness/extract.py`'s existing `ExtractError.error_class` namespace where they overlap. `json-parse-error` is reused verbatim so that telemetry's `error_class` field and the parsed cache's `parse_error` field never disagree on the 2 corpus rows that already failed extraction. The two new values (`wrong-array-length`, `missing-required-field`) are net additions for failure modes the harness extractor doesn't itself surface (it raises `no-array`/`not-a-list` for shape errors and stops before per-field validation). The parser does not invent a parallel namespace.

### 1.3 No analysis logic in PR-E1

This PR commits *only* the extractor + cache + tests. No scoring, no aggregation, no analyzer extension. The split is deliberate: the cache is what the next two PRs both read, and reviewing the parser in isolation lets us trust the cache before piling analyses on it.

### 1.4 Risks

- **Cache invalidation drift.** If the parser changes (bug fix, schema extension), the cache must be regenerated. Mitigation: parser version stamp in each parsed file's `extraction_notes` (`parser_version: "1.0"`), bumped on any non-additive change. Cache regenerator is the same `parse_responses.py --force`. **Invalidation rule:** parser bugs discovered *during* PR-E1 must be fixed before E1 merges (the cache committed in E1 must be self-consistent with the parser that produced it). Parser bugs discovered *after* E1 merges but before E2 starts require a follow-up regeneration PR that bumps `parser_version`, re-runs `parse_responses.py --force`, and re-commits the cache; E2 rebases onto that PR. E2 startup checks every parsed file's `parser_version` matches the currently-checked-in parser; mismatch aborts with an instruction to regenerate.
- **Specifics-schema mismatch.** Some categories require keys the model occasionally omits. The parser does *not* validate against `rubric.specifics_schemas` — that's the auto-scorer's job (PR-E3). PR-E1 records what the model emitted, verbatim.

## 2. PR-E2 — §14.1 substrate-helped check + plant-recall confirm

### 2.1 Deliverable

Two analysis scripts in a new subdirectory `experiments/v7-refactor-recommendation/analyses/` (created by this PR; sits alongside the existing `auto-scorer.py`, `validate-manifest.py`, `preflight/`, etc.):

- `analyses/substrate_helped.py`: reads the parsed cache, computes per-query S2−S1 deltas across the three trials. For each query: mean confidence delta (where confidence present), category-distribution diff (rec proportions per `category`), and the §14.1 pre-registered signature check from the methodology pre-mortem. Output: a single `analyses/substrate-helped.json` plus a console summary table.
- `analyses/plant_recall_extended.py`: extends the existing plant-recall analyzer at [`examples/swift-plants-v7/analyzer.py`](../examples/swift-plants-v7/analyzer.py) (which today checks `expected_substrate_signals` presence) to walk the parsed categories *in addition to* the substrate signal-presence check. For each of the 25 plants: did its parsed-category match the manifest's `primary_answer.category` in any trial under S2? Output: `analyses/plant-recall-extended.json` + a markdown table. Extension strategy: import the existing analyzer's plant-loading + signal-matching helpers as a library; do not duplicate the manifest-walking logic.

### 2.2 Acceptance

- `substrate_helped.py` emits a per-query table with: `query`, `n_s1`, `n_s2`, `mean_confidence_s1`, `mean_confidence_s2`, `delta_confidence`, `delta_significant`, `category_dist_s1`, `category_dist_s2`, `category_dist_distance` (e.g., total variation).
- The §14.1 signature check (per methodology §14.1) produces a single pass/fail per query plus an aggregate. The pre-registered pass criterion is documented inline in the script's header comment, cross-referenced to the methodology section.
- `plant_recall_extended.py` resolves Plant 5.3's "didn't surface in declared signals" follow-up: the parsed-category result either confirms it surfaces in the categorized recs (closing the manifest-tuning gap as a substrate-recall artifact) or confirms it still doesn't (escalates the gap to a substrate-recall finding for round 2). Either outcome is acceptable as long as the analysis runs and the result is documented.
- All output files are deterministic: re-running with the same parsed cache produces byte-identical output JSON (lists sorted, dicts key-sorted).
- Unit tests at `experiments/v7-refactor-recommendation/test_analyses.py` (same co-location convention as `test_parse_responses.py` and the existing `test_validator.py`) cover the two analyses on synthetic 12-rec fixtures (small enough to hand-verify the math).

### 2.3 No writeup yet, no auto-scorer run yet

PR-E2 commits the analyses and their JSON outputs but does **not** populate `results.md`. The writeup lives in PR-E3 where it can quote both the §14.1 result *and* the auto-scorer's category-recall numbers in the same prose.

### 2.4 Risks

- **§14.1 self-skipped in Phase D for a reason.** Per `scripts/harness/README.md` line 136, the in-harness check self-skips because telemetry doesn't carry confidence. PR-E2 walks the raw bodies' `confidence` field, which the model emits in `parsed.confidence` per the agent-prompt §2 specifics schema. If real-world confidence-emission rate is too low (< ~60%), the §14.1 delta becomes noise-dominated. Mitigation: PR-E2's output explicitly reports `n_with_confidence` per query; if < 60%, fall back to the category-distribution distance as the primary signal and downgrade confidence-delta to a secondary number. The decision rule lives in the script header and is auditable.
- **Plant 5.3 escalation could fork the plan.** If the parsed categories also don't surface Plant 5.3, that's a substrate-recall finding requiring an entry in `rubric-modifications.md` and a follow-up issue. PR-E2 raises the issue but does not attempt the fix — keeping E2 scoped to *analysis*, not substrate edits.

## 3. PR-E3 — auto-scorer bulk run + results.md + reproducibility finalize

### 3.1 Deliverable

Three things in one PR:

1. **Bulk runner** at `experiments/v7-refactor-recommendation/score_all.py`: walks the parsed cache, calls `auto-scorer.py`'s `score_recommendation` per parsed rec against its plant manifest entry, writes `analyses/auto-scores.json` (per-rec) + `analyses/score-summary.json` (per-category, per-condition, per-trial aggregates). Routes the un-auto-scoreable recs (Case 6 `panel_route` per methodology §8) to `analyses/panel-routing.jsonl` for the panel sitting.
2. **Panel-routing artifact** + a one-page `analyses/panel-instructions.md` that the 3 internal reviewers (per methodology §17 decision #3) follow. The instructions cover the four panel cases per main plan §7.2: `category == "other"` recs, primary/alternative with specifics out of tolerance, the 10–20% citation-grounding audit sample, and any natural-findings recs (none in MVP — that's §6.4). Panel scores get recorded under `analyses/panel-scores.jsonl` (one row per rec × reviewer); inter-rater κ computed in-script.
3. **`results.md`** at `experiments/v7-refactor-recommendation/results.md`: structured per main plan §7.3 (headline 2-D point: canonical recall × restraint 1-FPR; per-category S2−S1 deltas; substrate-helped signature outcome from PR-E2; Plant 5.3 outcome; auto-scoring rate; panel coverage; Fleiss κ; sensitivity to specifics-tolerance read).
4. **`reproducibility.yaml` finalized** — `panel_composition` populated with the 3 reviewer names + roles, `rubric_modifications` either null or pointing at a committed `rubric-modifications.md`.

### 3.2 Acceptance

- `score_all.py` is idempotent + deterministic (same parsed cache → same `auto-scores.json`).
- Auto-scoring rate is reported in `results.md` per (condition, category) cell. The pre-registered acceptance bar is **panel-route rate ≤ 50%** (equivalently, auto-scored fraction ≥ 50%) per methodology §14.3's "rubric undercovers" signature; a panel-route rate above that threshold is reported as a finding rather than as a procedural failure.
- All 25 plants have a per-plant score recorded in `score-summary.json` for each (condition, trial) cell.
- Fleiss κ computed and recorded in `results.md` per methodology §12.
- `reproducibility.yaml`: `panel_composition` non-TBD; `rubric_modifications` either `null` or path-to-file.
- PR body declares `Closes #<E3-issue-number>` against the E3 issue filed per §5.1 (since the four PRs are tracked as four sibling issues on the "V7 Phase E" GitHub Project, not under a single tracker issue, there is no parent issue to close). Issue #67 is referenced in prose, not as a close-target — PR-E3 does not satisfy #67's scope.

### 3.3 Why the panel goes in E3, not its own PR

The panel sitting is procedural (people doing reviews), not code. Committing the routing artifact + instructions in E3 and waiting for the panel before merging the PR keeps the writeup atomic with its inputs. If the panel takes longer than expected, that's just an extended review on PR-E3 — no separate workflow.

### 3.4 Risks

- **Panel availability.** Three reviewers, 4 hours each, blind-to-condition. The blinding mechanism is: `panel-routing.jsonl` has condition + trial fields stripped, replaced with an opaque `rec_token`. The mapping lives in `analyses/panel-unblind.json` (gitignored until after panel sitting, then committed for reproducibility). Mitigation: if a reviewer drops, score with 2 reviewers and report κ on n=2.
- **Auto-scorer MVP limitations bite.** Per `auto-scorer.py`'s docstring (lines 38–47), specifics matching is **key-only**, not value-aware. If many recs have correct category + correct keys but wrong values, the auto-score over-credits. Mitigation: panel-routing instructions include "value-mismatch spot check" as a fifth case in the 10–20% audit sample; if the panel finds systematic over-credit, log to `rubric-modifications.md` and re-score with a value-aware variant.

## 4. PR-E4 (optional) — §6.4 sub-experiments

Deferred per the original plan §6.4. Worth lifting only if PR-E1–E3 produce one of these signatures:

- S2 ≈ S1 on canonical recall (methodology §14.1 trips): natural-findings sub-experiment becomes the headline measurement instead of the plant-derived numbers.
- Specifics-out-of-tolerance dominates the panel route (>50% of panel routes): prompt-sensitivity sub-experiment (rephrase the §2 specifics schemas) calibrates whether the model can hit tolerance with a sharper schema.
- Confidence-delta + category-distribution distance disagree on substrate-helped (one says yes, one says no): model-sensitivity sub-experiment (rerun a 50-rec subset against a different tier) triangulates capability vs. substrate.

Out of scope to specify in detail here; if the trigger fires, E4 gets its own plan doc and `/review-plan` pass before implementation. Budget envelope inherits from methodology §16 ($50–110 at Sonnet rates).

## 5. Tracking and worktree discipline

### 5.1 Issue graph and project tracking

The four PRs (E1–E4) are tracked as four separate issues on `jakebromberg/code-audit-pipeline`, surfaced via a repo-level **GitHub Project** named "V7 Phase E" rather than a single tracker issue with sub-issue edges. The project provides the rollup view (status board / table with deps); the issues themselves stay self-contained per the `file-ticket` skill's body-content conventions (durable on-issue context, structured Relationships, cross-references in prose) — the skill lives in the user's global `~/.claude/skills/` and is not vendored into this repo.

Issues to file at plan kickoff (each gets added to the "V7 Phase E" project on creation):

- **E1**: response-body parser + parsed-fields cache
- **E2**: §14.1 substrate-helped check + plant-recall confirm (Plant 5.3 fold-in)
- **E3**: auto-scorer bulk run + results.md + reproducibility finalize
- **E4** (open, brief body, no acceptance yet): §6.4 sub-experiments — file at plan kickoff so the project view is complete, leave unassigned until/unless a §6.4 trigger fires in E2 or E3.

Dependencies (blocked-by edges, wired via the GitHub issue-dependencies API per the file-ticket reference doc on `dependencies/blocked_by` — *not* via sub-issue edges, since there's no parent tracker): E2 ← E1, E3 ← E1, E3 ← E2, E4 ← E3.

Project board columns: **Backlog → In progress → In review → Done**. Each issue moves through the columns as its PR opens / merges. Issue #67 (§6.3 production trial execution; satisfied by merged PR #72) is referenced via prose in E1's body but not as a structured dependency — E1 reads the trial-log files PR #72 committed; there's no remaining unblocking work on #67 regardless of whether the tracker issue is still open at E1 kickoff.

### 5.2 Worktree discipline

Per [project CLAUDE.md](../CLAUDE.md), one worktree per PR. Names following the `~/Developer/code-audit-pipeline-swift-substrate-<short-name>/` convention:

- `~/Developer/code-audit-pipeline-swift-substrate-phase-e-parser/` (E1)
- `~/Developer/code-audit-pipeline-swift-substrate-phase-e-analyses/` (E2)
- `~/Developer/code-audit-pipeline-swift-substrate-phase-e-scoring/` (E3)

Each cleans up with `git worktree remove` after its PR merges.

### 5.3 Rebase strategy

Each PR rebases onto the latest `experiment/swift-substrate` before opening (per global CLAUDE.md). E2 rebases onto E3's base only if E1 has merged; otherwise E2's branch tracks E1's branch and the PR re-bases when E1 merges. Same chain for E3 ← E2. Avoid stacked PRs where possible — E1 should merge fast since it's purely an extractor + tests.

## 6. Decisions to flag for `/review-plan`

The plan adopts the main plan §8 defaults wherever possible. Open decisions specific to Phase E that the reviewer should validate:

1. **Cache format & location.** Committing 2905 parsed files under `trial-logs/parsed/` adds ~5–10 MB to the repo, same scale as the raw responses already committed in PR #72. Alternative: a single `parsed.jsonl` file per (condition, trial). The per-file form preserves the resume-friendly listing scheme PR #72 established; the single-file form is fewer git objects. **Recommendation: per-file**, matching the raw-response layout for consistency.
2. **Confidence fallback threshold.** §14.1 falls back from confidence-delta to category-distribution distance when confidence-emission rate is < 60%. The 60% number is a judgment call. **Recommendation: adopt 60% with a console-warning floor at 50%**, refine on first observation.
3. **Panel blinding mechanism.** Strip condition + trial fields and substitute `rec_token`. The unblind map is gitignored until panel sitting completes, then committed. Alternative: keep blinding only for the panel review session, never commit the unblind map. **Recommendation: commit the unblind map after the panel** — methodology §10 reproducibility requires the full mapping for replay.
4. **Plant 5.3 escalation path.** If the parsed categories don't surface Plant 5.3, file a substrate-recall follow-up issue against `jakebromberg/code-audit-pipeline` and document the gap in `results.md` under a "Known limitations" subsection, **without** modifying the manifest in this round. **Recommendation: keep round 1 manifest frozen**; manifest tuning is a round 2 concern.
5. **Auto-scorer value-awareness.** PR-E3's MVP runs the existing key-only scorer. A value-aware variant is ~50 LOC and could land in PR-E3 if the panel's spot check shows systematic over-credit. **Recommendation: ship key-only first**; add value-aware as a follow-up PR only if the panel finds the gap matters.

## See also

- [`v7-refactor-recommendation-implementation-plan.md`](v7-refactor-recommendation-implementation-plan.md) — the parent plan; this doc operationalizes its §7.
- [`../docs/refactor-recommendation-experiment-methodology.md`](../docs/refactor-recommendation-experiment-methodology.md) — §8 scoring rubric (panel-route rule), §10 pre-registration / reproducibility, §12 inter-rater stats (Fleiss κ), §14 failure-mode signatures, §17 decision #3 (panel composition).
- [`../experiments/v7-refactor-recommendation/reproducibility.yaml`](../experiments/v7-refactor-recommendation/reproducibility.yaml) — pre-registration hashes, execution stamps so far.
- [`../scripts/harness/README.md`](../scripts/harness/README.md) — Phase D harness contract; §14.1 self-skip note this plan resolves.
- [PR #72](https://github.com/jakebromberg/code-audit-pipeline/pull/72) — the Phase D trial execution that produced this corpus.
- [`experiments/v7-refactor-recommendation/glossary.md`](../experiments/v7-refactor-recommendation/glossary.md) — shared V7 vocabulary (S1/S2, substrate, plants, metrics, all 13 auto-scorer match labels, binding rules, rounds/phases, code refs, PR/issue index).
