# V7 Round 2 — prompt-sensitivity sub-experiment (resolves [#77](https://github.com/jakebromberg/code-audit-pipeline/issues/77) trigger #2)

> Round-2 sub-experiment fired by [#77](https://github.com/jakebromberg/code-audit-pipeline/issues/77) trigger #2 ("specifics-out-of-tolerance dominates the panel route — > 50%"). Round-2's [`panel-routing.jsonl`](../experiments/v7-refactor-recommendation/analyses/panel-routing.jsonl) shows 102 of 108 routed rows (94.4%) are `primary_match_specifics_outside_tolerance` — the auto-scorer is offloading nearly all judgment to humans because the agent's specifics values disagree verbatim with the manifest's `primary_answer.specifics`. Per [Phase E plan §6.4](v7-phase-e-scoring-and-writeup-plan.md), the prompt-sensitivity sub-experiment diagnoses whether the high panel-route rate is *prompt vagueness* (sharpen the §2 specifics schemas → agent hits tolerance → panel-route rate drops) or *model capability ceiling* (sharpen → no change). The change is pre-registered via this plan + [`rubric-modifications.md`](../experiments/v7-refactor-recommendation/rubric-modifications.md) round-3 entry per [methodology §10](../docs/refactor-recommendation-experiment-methodology.md).

## 1. Context and motivation

The headline V7 round-2 finding ([`results.md`](../experiments/v7-refactor-recommendation/results.md) §7) is that 100% of the 102 rows that fired `primary_match_full` or `primary_match_weak_rationale` under round-1's key-only scoring *flipped* under round-2's value-aware comparison ([PR #90](https://github.com/jakebromberg/code-audit-pipeline/pull/90)) — every row had at least one mismatched required value. Of those 102 mismatches, 95.1% were classified substantive (different identifier, different target package) and 4.9% trivial (manifest-side parenthetical commentary the agent didn't reproduce).

The interpretive ambiguity in [`results.md`](../experiments/v7-refactor-recommendation/results.md) §7 reads:

> Where round-1 said "key-only over-credit is bounded for the planted clusters in this corpus" — that read does not hold under value-aware scoring. The over-credit was substantial: the headline `canonical_recall` shifts from S1=0.270 / S2=0.615 (key-only) to S1=0.070 / S2=0.110 (value-aware), with 108 rows routed to panel awaiting [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) reviewer recruitment.

The corrected canonical-recall numbers (S1=0.070, S2=0.110) are reportable, but the *cause* of the 94% panel-route rate isn't. Three hypotheses are observationally equivalent:

- **H1 (prompt vagueness)**: the [§2 specifics schemas](../docs/refactor-recommendation-experiment-agent-prompt.md) are general enough that the agent emits reasonable-but-different values. Sharpening (more structural constraints + per-category worked examples) should let the agent hit tolerance directly, dropping the panel-route rate.
- **H0a (model capability ceiling)**: the agent can't reason about these tolerances regardless of prompt sharpness. Sharpening produces no change.
- **H0b (rubric over-strictness)**: the auto-scorer's verbatim-match check is too strict; values like `BlendMode` vs `BlendModeConvertible` are structurally equivalent but lexically different. The right fix is rubric loosening, not prompt sharpening — but that's a separate sub-experiment.

This plan tests H1 vs H0a by holding the rubric fixed and varying the prompt. H0b stays out of scope; a separate sub-experiment can test it if H1 fails and the headline finding still needs interpretation.

## 2. Scope

Single sub-experiment: prompt v2 rerun against the round-2 trial corpus, control = round-2 existing data + drift-check sample.

**In scope:**

- New prompt v2 at [`docs/refactor-recommendation-experiment-agent-prompt-v2.md`](../docs/refactor-recommendation-experiment-agent-prompt-v2.md) (sibling to the [v1 file](../docs/refactor-recommendation-experiment-agent-prompt.md); both stay in the repo for reproducibility). The v2 file lives at the same directory level as v1 — repo path `docs/refactor-recommendation-experiment-agent-prompt-v2.md`, alongside `docs/refactor-recommendation-experiment-agent-prompt.md`. Committing both side-by-side preserves the v1 baseline as the round-2 control and lets the methodology §10 hash pinning cover both prompt versions.
- Harness flag: [`scripts/harness/prompt.py`](../scripts/harness/prompt.py) gains a `--prompt-version {v1,v2}` argument that maps to `docs/refactor-recommendation-experiment-agent-prompt.md` and `docs/refactor-recommendation-experiment-agent-prompt-v2.md` respectively. Default stays `v1` so existing call sites remain byte-identical. The current `extract_prompt_body(doc_text)` signature stays unchanged; the flag is consumed at the caller (harness CLI) which selects which file to read before calling `extract_prompt_body`.
- Drift-check protocol: pre-registered 30-rec sample, run before sharpened rerun, with explicit halt-on-fail thresholds.
- Full Phase D rerun with v2 prompt (~2907 recs at Sonnet 4.6, ~$39).
- Auto-scorer regenerated; new [`analyses-v2/prompt-sensitivity.json`](../experiments/v7-refactor-recommendation/analyses-v2/prompt-sensitivity.json) documents v1 vs v2 panel-route rates per condition and per category.
- New [`results.md`](../experiments/v7-refactor-recommendation/results.md) §10 (or similar) reports H1/H0a outcome.
- [`rubric-modifications.md`](../experiments/v7-refactor-recommendation/rubric-modifications.md) round-3 entry per [methodology §10](../docs/refactor-recommendation-experiment-methodology.md).
- [`reproducibility.yaml`](../experiments/v7-refactor-recommendation/reproducibility.yaml): prompt v2 hash, drift-check methodology, rerun trial dates, alias→snapshot capture.

**Out of scope:**

- H0b (rubric over-strictness) — separate sub-experiment if H1 fails and the finding still needs interpretation.
- Auto-scorer logic changes — the rubric stays fixed.
- Manifest changes — the 25-plant manifest stays fixed.
- Recommendation-text normalization — strict verbatim comparison continues.
- Recruitment / panel work — independent of [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) / [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94).

## 3. Design

### 3.1 Prompt v2 — sharpening changes

Two changes from v1, both pre-registered per user decision 2026-05-20:

**(a) Structural constraints (per-category).** Add explicit boundary language to each category's §2 specifics schema in [`docs/refactor-recommendation-experiment-agent-prompt.md`](../docs/refactor-recommendation-experiment-agent-prompt.md):

- **default-implementation**: "The `protocol` field must name a type that already exists in the cluster's source files. Do NOT propose new protocol names. The `default_impl_location` field must be inside the same SPM package as `protocol`."
- **generic-parameterization**: "The `target_function` field must name a function that exists in the cluster's source files. Do NOT propose new function names."
- **extract-to-common**: "The `target_package` MUST name a package that exists in the source tree and is upstream of all consumer packages. The `new_helper_name` may be a new name."
- **protocol-inheritance**: "The `parent_protocol` must name a type that exists in the cluster's source files. Do NOT propose new parent protocols."
- **pat-introduction**: "The `pat_name` may be a new name. The `applies_to` fields must name existing types in the cluster."

These constraints encode *structural* expectations from the [manifest's tolerance schema](../experiments/v7-refactor-recommendation/plant-manifest.yaml) without exposing the manifest values themselves. Methodologically clean: the agent learns "stay grounded in the cluster's source files" without learning what the answer key looks like.

**(b) Non-corpus worked examples (one per category).** Add one walked-through example per category at the end of §2, drawn from a synthetic toy refactor that has zero overlap with the 25-plant V7 corpus. Concrete proposal:

- **default-implementation**: a hypothetical `Logger` protocol with `ConsoleLogger`, `FileLogger`, `NetworkLogger` conformers all redeclaring `log(message:)` — lift to a default impl on `Logger`. None of these names appear in the V7 corpus.
- **generic-parameterization**: a hypothetical `Cache<K, V>` parameterized over key/value types. None of these names appear in the V7 corpus.
- **extract-to-common**: a hypothetical `JSON.encode` / `JSON.decode` helper extracted from per-domain encoders into a shared `JSONUtils` module.
- **protocol-inheritance**: a hypothetical `ReadableStream` and `WritableStream` lifted to a shared `Stream` parent.
- **pat-introduction**: a hypothetical `RetryPolicy` template applied across `NetworkClient`, `DiskCache`, `MessageQueue`.

Pre-registration constraint: the examples will be reviewed against the [V7 manifest](../experiments/v7-refactor-recommendation/plant-manifest.yaml) before implementation to confirm zero name overlap. The overlap check is mechanical, not judgmental: PR 1 ships a small script at `scripts/check_example_overlap.py` that loads the v2 prompt and the manifest, then exits non-zero on any substring match between (i) every identifier extracted from the v2 worked-examples block and (ii) any string value found in the manifest under `source_type`, `source_files`, `expected_cluster_symbols`, `primary_answer.specifics.*`, or `alternative_answers[*].specifics.*`. Reviewer signoff in PR #1 consists of pasting the script's clean-exit output into the PR review comment; substring-match failures must be resolved before PR 1 merges.

Worked-example presentation format: each example is rendered in the v2 prompt as a single prose paragraph following the existing v1 style — e.g., "A hypothetical `Logger` protocol with three conformers (`ConsoleLogger`, `FileLogger`, `NetworkLogger`) all redeclaring `log(message:)` — lift to a default impl on `Logger`." Same narrative register as v1's existing schema descriptions; no schema diagram or table format. This keeps the prompt structure consistent and avoids accidentally signalling that examples are answer-key shaped.

**What we do NOT add (per user decision 1c excluded):**

- No tolerance-flag language. The manifest's `default_impl_must_be_in_protocols_own_package` and similar flags stay invisible to the agent. Including them would leak the manifest's tolerance schema into the prompt — methodologically polluting the experiment.
- No corpus-specific examples. Drawing examples from the 25-plant manifest would tell the agent what answer-key shape to emit. Polluting.

### 3.2 Drift-check protocol

Pre-registered before any rerun begins. Run on the same calendar day as the v2 rerun.

**Sample**: 30 recs from the round-2 corpus, stratified to cover all 5 plant categories × balanced S1/S2 conditions. Pre-registered sampling seed for reproducibility: `seed=20260520`.

**Procedure**:

1. Render v1 prompt (unchanged) against the same cluster inputs the round-2 corpus saw.
2. Call Sonnet 4.6 alias once per rec. Capture the response.
3. Compare against the stored round-2 response for that rec (from [`trial-logs/parsed/`](../experiments/v7-refactor-recommendation/trial-logs/parsed/)).

**Metrics + tolerances**:

- **Structural — category disagreement**: of the 30 reruns, how many emit a different `category` than the round-2 response? Tolerance: ≤ 6 of 30 (20%).
- **Structural — specifics-key drift**: per rec, what fraction of required specifics keys appear/disappear vs round-2? Tolerance: ≤ 30% average drift across the 30 recs.
- **Behavioral — panel-route rate**: rescore the 30 v1-rerun responses with the [auto-scorer](../experiments/v7-refactor-recommendation/auto-scorer.py). Compare panel-route rate to the round-2 panel-route rate on those exact 30 recs. Tolerance: within ± 10 percentage points.

**Threshold derivation**: round-2 didn't run repeat-the-same-rec sampling at the v1 prompt, so no empirical intra-trial variance baseline exists for these metrics. The 20% / 30% / ±10pp thresholds are conservative estimates intended to leave headroom for benign alias-snapshot drift while still flagging drift large enough to invalidate the round-2 control. The 20% category-disagreement threshold is roughly 2.5× the expected baseline variance for repeated calls at temperature 0 on a structured-output task; the 30% specifics-key threshold and ±10pp panel-route threshold follow the same conservatism multiplier. If round-3 (or any future trial) collects intra-trial variance data with the same alias-pinned model, these thresholds should be tightened. The actual measured values for all three metrics are captured in [`analyses-v2/drift-check.json`](../experiments/v7-refactor-recommendation/analyses-v2/drift-check.json) at rerun time alongside the threshold values, so a future agent can audit whether the conservatism was warranted in retrospect.

**Drift-check failure semantics**: the protocol assumes the Sonnet 4.6 alias is stable across the round-2 → v2-rerun calendar window. Per [#66](https://github.com/jakebromberg/code-audit-pipeline/issues/66), the alias is not date-pinned, so the check cannot distinguish three failure modes: (i) the alias snapshot rotated mid-window, (ii) sampling variance for repeat structured-output calls is genuinely higher than the 2.5× conservatism allows, (iii) the round-2 corpus has properties (e.g., long inputs, schema corners) that produce more inherent variance than the threshold assumes. The drift-check is binary on the threshold; it does not diagnose the cause. Recovery does not pre-commit between modes — see "Halt-recovery protocol" below.

**Decision rule**:

- All three pass → proceed with v2 rerun. Round-2 corpus is the valid control.
- Any tolerance fails → **halt immediately**. Do not proceed to the full rerun on the same calendar window. Do not pre-commit to a recovery option in this plan; see Halt-recovery protocol below.

**Halt-recovery protocol**: on any drift-check failure, file a follow-up issue titled "V7 drift-check failure: recovery options for prompt-sensitivity sub-experiment" containing the measured drift metrics, the failure-mode hypothesis, and proposed recovery cost. The follow-up issue decides among (a) full re-control rerun (~$78, still within the [methodology §6.3](../docs/refactor-recommendation-experiment-methodology.md) main-trial headroom and §16 envelope), (b) abort the sub-experiment and post-mortem the drift, or (c) await alias re-pinning (per [#66](https://github.com/jakebromberg/code-audit-pipeline/issues/66)) and retry from drift-check. Recovery proceeds only after the follow-up issue is filed and a decision is recorded; this plan does not authorize re-control compute spend in advance.

**Cost**: 30 recs at Phase D rates ≈ $0.40.

### 3.3 v2 rerun

After drift-check passes:

- Full Phase D rerun with v2 prompt: 25 plants × 2 conditions (S1, S2) × ~3 trials × clusters per plant = ~2907 recs (mirrors the round-2 trial size).
- Parsed cache regeneration at [`experiments/v7-refactor-recommendation/trial-logs/parsed-v2/`](../experiments/v7-refactor-recommendation/trial-logs/parsed-v2/).
- Auto-scorer rerun produces [`analyses-v2/auto-scores.json`](../experiments/v7-refactor-recommendation/analyses-v2/auto-scores.json) (sibling to round-2's [`analyses/`](../experiments/v7-refactor-recommendation/analyses/)).
- The round-2 [`analyses/`](../experiments/v7-refactor-recommendation/analyses/) stays untouched as the v1 control.

**Cost**: ~$39 (mirrors the round-2 Phase D production trial spend of $39.46 per [`reproducibility.yaml`](../experiments/v7-refactor-recommendation/reproducibility.yaml)).

**Budget check**: total sub-experiment cost ≈ $39 main rerun + $0.40 drift check + ($0.40 retry budget) ≈ $40. [Methodology §16](../docs/refactor-recommendation-experiment-methodology.md) envelope is $50–110; main-trial [§6.3](../docs/refactor-recommendation-experiment-methodology.md) cap is $120 with $80 headroom from round-2's $39.46 spend. Comfortable.

### 3.4 Pre-registered analysis

After v2 rerun completes:

1. Compute v2 panel-route rate per condition (S1, S2) and overall.
2. Compute v2 − v1 panel-route rate delta per condition and overall.
3. Per-category breakdown of the delta: which categories show the largest drop?
4. **Acceptance check**: overall panel-route rate drops by ≥ 50% (e.g., from 94% to ≤ 47%).

**Why 50%?** Half the panel-route rate signals that prompt vagueness was the *primary* cause per the structural-constraint hypothesis: if sharpening the §2 schemas wipes out the majority of tolerance-flag judgments, the agent was reaching for plausible-but-misaligned values because the prompt didn't bound them. A smaller drop (e.g., 20–30%) would indicate prompt contribution exists but isn't dominant — that's a co-causality result (H1 partial + H0a or H0b also active), which rejects H1-as-primary-cause and warrants a follow-up rubric-loosening experiment (the H0b path). A negligible drop (< 10%) would support H0a (model capability ceiling) cleanly. The 50% threshold is domain-specific to the diagnostic question of "is prompt vagueness the dominant driver?", not arbitrary; the *actual delta* is reported in [`results.md`](../experiments/v7-refactor-recommendation/results.md) §10 regardless of which side of the threshold it falls on, with per-category breakdown so readers can distinguish "all categories sharpened equally" from "only some categories benefited from sharpening."

**Baseline invariance to round-2 panel completion**: the acceptance metric is *panel-route rate* (the fraction of recs the auto-scorer routes to panel), not *canonical recall* (which depends on panel scores being promoted into the headline). Panel-route rate is determined purely by the auto-scorer's match-label classification of each rec and is invariant under panel-scoring completion ([#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85), [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94)). The v2 rerun can therefore proceed in parallel with recruitment and finalization without circularity in the acceptance decision. The §10 writeup's *canonical-recall* delta — a secondary, descriptive number — does depend on panel scores; if panel work is still pending when v2 results land, that section reports the auto-scored-only canonical-recall delta and is amended once #94 closes. The H1/H0a decision itself does not wait on panels.

Decision tree:

| Drift-check | Acceptance | Conclusion |
|---|---|---|
| Pass | Pass (≥ 50% drop) | **H1 supported**: prompt vagueness was the dominant cause of the 94% panel-route rate. Report panel-route-rate drop, per-category breakdown, and revised canonical-recall numbers in [`results.md`](../experiments/v7-refactor-recommendation/results.md) §10. |
| Pass | Fail (< 50% drop) | **H0a supported**: model capability ceiling. Report no-effect finding; flag H0b (rubric over-strictness) as the next sub-experiment to test if the headline finding still needs interpretation. |
| Fail | (not evaluated) | **Halt**. Halt-recovery path per §3.2. |

## 4. Pre-registration

Pre-registered before any rerun begins:

- Drift-check tolerances (20% category disagreement, 30% specifics-key drift, ±10pp panel-route rate).
- Acceptance threshold (50% panel-route rate drop).
- Decision tree (above).
- Sampling seed (`seed=20260520`).
- Prompt v2 file hashed and committed before the rerun starts.

Pre-registration document: this plan + [`rubric-modifications.md`](../experiments/v7-refactor-recommendation/rubric-modifications.md) round-3 entry referencing this plan + [`reproducibility.yaml`](../experiments/v7-refactor-recommendation/reproducibility.yaml) round-3 block.

**When the round-3 entries are created**: PR 1 (prompt v2 + harness flag) opens with a commit that adds the `## Round 3 — prompt-sensitivity sub-experiment (2026-05-20)` block to [`rubric-modifications.md`](../experiments/v7-refactor-recommendation/rubric-modifications.md) AND the round-3 `execution.prompt_sensitivity_sub_experiment` block to [`reproducibility.yaml`](../experiments/v7-refactor-recommendation/reproducibility.yaml). Both blocks include: a permalink to this plan at its merged SHA, the v2 prompt file hash (computed at commit time), the pre-registered drift-check tolerances (20% / 30% / ±10pp), the acceptance threshold (50%), and the sampling seed (`seed=20260520`). These blocks freeze the pre-registered parameters before PR 2's drift-check runs, so the thresholds cannot be edited after observing the rerun outcome. PR 1 merge gates PR 2.

## 5. Acceptance criteria

- [ ] Prompt v2 drafted at [`docs/refactor-recommendation-experiment-agent-prompt-v2.md`](../docs/refactor-recommendation-experiment-agent-prompt-v2.md), reviewed against the [V7 manifest](../experiments/v7-refactor-recommendation/plant-manifest.yaml) for zero example-overlap. Overlap review verifies, in PR review comments: (1) no v2-example identifier (type, function, package, or symbol name) appears as a key or value in [`plant-manifest.yaml`](../experiments/v7-refactor-recommendation/plant-manifest.yaml); (2) no v2-example identifier is a substring of any plant's `expected_cluster_symbols` list entry; (3) reviewer approval comment explicitly attached before merge.
- [ ] Harness supports `--prompt-version v2` flag; existing v1 path unchanged in [`scripts/harness/prompt.py`](../scripts/harness/prompt.py).
- [ ] Drift-check 30-rec sample run; three metrics computed; pass/fail recorded in [`analyses-v2/drift-check.json`](../experiments/v7-refactor-recommendation/analyses-v2/drift-check.json).
- [ ] If drift-check passes: full v2 rerun (~2907 recs); auto-scorer regenerated at [`analyses-v2/`](../experiments/v7-refactor-recommendation/analyses-v2/).
- [ ] [`analyses-v2/prompt-sensitivity.json`](../experiments/v7-refactor-recommendation/analyses-v2/prompt-sensitivity.json) documents v1 vs v2 panel-route rates per condition + per category.
- [ ] [`results.md`](../experiments/v7-refactor-recommendation/results.md) §10 reports H1/H0a outcome; per-category panel-route delta table; updated headline canonical-recall if H1 supported.
- [ ] [`rubric-modifications.md`](../experiments/v7-refactor-recommendation/rubric-modifications.md) round-3 entry filed ([methodology §10](../docs/refactor-recommendation-experiment-methodology.md) compliance).
- [ ] [`reproducibility.yaml`](../experiments/v7-refactor-recommendation/reproducibility.yaml) updated: prompt v2 hash, drift-check methodology, rerun trial date, captured alias→snapshot from API response headers if available.

## 6. Implementation plan

Sequential PRs against `experiment/swift-substrate`:

| PR | Scope | Cost | Wallclock |
|---|---|---|---|
| 1 | Prompt v2 + harness `--prompt-version` flag + non-corpus-example overlap review | $0 | 3–4 days |
| 2 | Drift-check 30-rec sample + [`analyses-v2/drift-check.json`](../experiments/v7-refactor-recommendation/analyses-v2/drift-check.json) | ~$0.40 | 1 day |
| 3 | v2 full rerun + [`analyses-v2/`](../experiments/v7-refactor-recommendation/analyses-v2/) regeneration (only if PR 2's check passes) | ~$39 | 2–3 days |
| 4 | [`analyses-v2/prompt-sensitivity.json`](../experiments/v7-refactor-recommendation/analyses-v2/prompt-sensitivity.json) + [`results.md`](../experiments/v7-refactor-recommendation/results.md) §10 + [`rubric-modifications.md`](../experiments/v7-refactor-recommendation/rubric-modifications.md) round-3 entry + [`reproducibility.yaml`](../experiments/v7-refactor-recommendation/reproducibility.yaml) update | $0 | 3–5 days |

Total: ~1.5 weeks wallclock, $39.40 API spend, well under [methodology §16](../docs/refactor-recommendation-experiment-methodology.md)'s $50–110 envelope.

**Parallel with**: [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) (recruitment), [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94) (finalization). No human-time dependencies on this sub-experiment; it runs alongside the panel work.

## 7. Risks

1. **Model drift larger than tolerances**: halt rule fires; sub-experiment can't proceed without re-control. Mitigation: drift-check is cheap; budget allows the re-control at $78 if needed (still within $50-110 envelope's upper bound with main-trial headroom). [Issue #66](https://github.com/jakebromberg/code-audit-pipeline/issues/66) documents the Sonnet 4.6 alias-not-date-pinned constraint that necessitates the drift check.
2. **Sharpening accidentally leaks corpus knowledge**: if non-corpus examples accidentally rhyme with corpus plants, methodological pollution. Mitigation: PR 1 includes explicit overlap review against the [25-plant manifest](../experiments/v7-refactor-recommendation/plant-manifest.yaml); reviewer signoff before commit.
3. **Acceptance threshold too strict**: 50% drop might miss meaningful-but-smaller signals (e.g., 30% drop). Mitigation: report the actual delta regardless of threshold; characterize "partial sensitivity" in the writeup. Threshold gates interpretation, not reporting.
4. **Round-2 panel reliability still pending**: if [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94) closes with κ < 0.4, the round-2 results aren't reliably auditable. The prompt-sensitivity sub-experiment compares panel-route *rates*, not panel scores, so this isn't a hard blocker. But the §10 writeup should note the dependency and reproducibility implications.
5. **v1 prompt corpus contamination**: the round-2 v1 prompt may itself have unintended structural language that nudges the agent. Mitigation: diff v1 against the original [methodology §2](../docs/refactor-recommendation-experiment-methodology.md) schemas to confirm only the documented changes.

## 8. Open questions

(None as of plan-draft time. All five methodology questions resolved with the user 2026-05-20.)

## Related

- [#77](https://github.com/jakebromberg/code-audit-pipeline/issues/77) — E4 sub-experiments tracker (trigger #2 fired)
- [#85](https://github.com/jakebromberg/code-audit-pipeline/issues/85) — V7 round 2 recruitment (parallel work, not a blocker)
- [#94](https://github.com/jakebromberg/code-audit-pipeline/issues/94) — V7 round 2 finalization (parallel work, not a blocker)
- [#66](https://github.com/jakebromberg/code-audit-pipeline/issues/66) — Sonnet 4.6 alias-not-date-pinned (drift-check motivation)
- [PR #89](https://github.com/jakebromberg/code-audit-pipeline/pull/89) — `expected_cluster_symbols` symbol-binding gate (round-2 corpus regenesis 12 → 6 rows)
- [PR #90](https://github.com/jakebromberg/code-audit-pipeline/pull/90) — value-aware specifics matching (round-2 corpus 6 → 108 rows; triggered this sub-experiment)
- [`plans/v7-phase-e-scoring-and-writeup-plan.md`](v7-phase-e-scoring-and-writeup-plan.md) §6.4 — original sub-experiment specification
- [`docs/refactor-recommendation-experiment-methodology.md`](../docs/refactor-recommendation-experiment-methodology.md) §6.4 (Plant 6.4), §10 (rubric-modifications protocol), §16 (sub-experiment budget envelope)
- [`docs/refactor-recommendation-experiment-agent-prompt.md`](../docs/refactor-recommendation-experiment-agent-prompt.md) — v1 prompt; v2 lives at sibling path
