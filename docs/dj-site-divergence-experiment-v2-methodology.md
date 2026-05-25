# dj-site Divergence Experiment — V2 Methodology

> Protocol for the second run of the dj-site pipeline-vs-cold divergence experiment, designed to address the confounds and underpowered comparisons surfaced in [V1](./dj-site-divergence-experiment.md). This is a *methodology* doc — it specifies what to run, not what was found. Results will be captured in a sibling `dj-site-divergence-experiment-v2-results.md` after V2 executes.

## What V1 showed and what V2 needs to show

V1 ran two pipeline-aware agents and two cold agents against dj-site and compared their findings docs. Headline: within-group Jaccard was ~0.40 in both pairs, cold agents found ~1.5–2× more legitimate issues, and the principle's reproducibility claim turned out to be about the substrate, not about findings downstream of it. The analysis attributed the divergence to three layered causes — bandwidth-limited sampling, greedy attention with different starting hooks, and free-form synthesis where the prompt invited creative writing rather than judgment over enumerated rows.

V1's design conflated several of these causes. The prompt asked for a free-form Markdown doc with "quality over quantity" — which forced sampling, invited prose synthesis, and made severity calibration drift across runs. The substrate was incomplete in load-bearing ways (no `--shared`, no `.tsx`, no reference counts) without the experiment treating substrate-completeness as a controllable variable. The codebase was a frontend, where the extractor's coverage is known to be weak, with no backend control to isolate that effect. And n=2 per condition is too small to distinguish "true 0.40 Jaccard" from "true 0.25 we got lucky" — a single noisy datapoint per cell.

V2 is designed to isolate these factors. The headline questions to answer:

1. Does output format (free-form prose vs structured row-per-finding) drive divergence?
2. Does prompt regime (sample-with-cap vs enumerate-without-cap) drive divergence?
3. Does substrate widening close the recall gap between pipeline-aware and cold agents?
4. Does the frontend-vs-backend distinction persist when the other variables are controlled?
5. With the prompt and output controls in place, what is the actual within-group Jaccard?

## What V2 deliberately does *not* address

**Human-curated ground truth is deferred.** Building a fixed denominator for recall (one engineer's exhaustive audit, listed before any agents run) would be the most rigorous single change. V1 used post-hoc union-of-agent-outputs as the denominator, which is circular: each agent's "recall" was measured against a set that included its own findings. V2 has the same limitation, and the headline recall numbers will still be relative, not absolute. The deferral is a practical one — engineer time is the scarce resource — but it should be reattempted whenever a senior engineer has 60–90 minutes free. Until then, V2's recall numbers should be read as "recall against the union of all V2 outputs," not "recall against ground truth."

A consequence: when V2's pipeline-aware recall jumps under the widened-substrate condition (as predicted), part of that jump may be the substrate finding genuinely new issues, and part may be the union denominator growing because *those* new findings are now in it. The relative comparison between conditions is still meaningful; the absolute "we cover 80% of real issues" claim is not available without ground truth.

## Conditions matrix

V2 runs five conditions. Each condition runs 5 trials (10 if budget allows; tighter intervals are worth the extra cost). All trials launch sequentially with 30-second staggers, pinned to the same model and temperature, against the same git SHA of dj-site (and Backend-Service for C5).

| ID | Substrate | Output format | Prompt regime | Codebase |
|---|---|---|---|---|
| **C1** | V1 narrow (no `--shared`, no `.tsx`, no reference counts) | Free-form Markdown | Sample with "quality over quantity" cap | dj-site |
| **C2** | V1 narrow | Structured row-per-finding (CSV-shaped) | Enumerate every cluster, no skipping | dj-site |
| **C3** | V2 widened (the 5 contract additions) | Structured row-per-finding | Enumerate every cluster | dj-site |
| **C4** | None (cold agent — same as V1 Exp 2) | Structured row-per-finding | Enumerate every issue found | dj-site |
| **C5** | V2 widened | Structured row-per-finding | Enumerate every cluster | Backend-Service |

Comparisons each cell unlocks:

- **C1 vs C2** — Output format + prompt regime, holding substrate constant. If C2's intra-pair Jaccard is much higher than C1's, prompt-and-format does most of the divergence work. If both are similar, prompt-and-format isn't the cause.
- **C2 vs C3** — Substrate widening, holding output format and prompt constant. If C3 surfaces more findings than C2 (and the new ones overlap the cold-agent-only findings from V1), substrate widening is the route to closing the recall gap.
- **C3 vs C4** — Pipeline-aware (widened) vs cold, both under the structured/enumerate regime. The cleanest fair-fight comparison. If they converge to similar findings sets, the pipeline is doing useful work; if cold still wins on recall, the substrate needs more widening.
- **C3 vs C5** — Same conditions on a different codebase. Tests whether the dj-site/Backend-Service distinction is structural (extractor coverage gap on frontend) or artifactual (something specific about dj-site).
- **C1 (V2) vs V1 Exp 1A+1B** — Sanity check that V2's C1 reproduces V1's pipeline-aware behavior. If the Jaccards differ materially, something else changed.

## Setup details

### Substrate variants

**Narrow substrate (C1, C2)** — Exact V1 setup. Run from current `main` of code-audit-pipeline:

```bash
mkdir -p /tmp/wxyc-audit-v2/dj-site-narrow
cd /Users/jake/Developer/code-audit-pipeline/extractors/typescript
node type-catalog.mjs \
  --root /Users/jake/Developer/WXYC/dj-site \
  --output /tmp/wxyc-audit-v2/dj-site-narrow/catalog.json
# Then run all 4 jq queries as in V1.
```

**Widened substrate (C3, C5)** — Requires the 5 contract additions to land in the extractor first:

1. `.tsx` indexing (one-line regex change in `walkDir`)
2. Default-on `--shared` warning when a sibling `@wxyc/shared` is detected on disk and `--shared` is not passed
3. Per-type `reference_count` (second pass: grep-approximation is fine for a first cut)
4. Subset-pairs query (`pipeline/queries/subset-pairs.jq`) and a corresponding `is_strict_subset_of: [other_name]` field if it ends up living on the catalog
5. Inline-literal expansion: when a property's type is a `TypeLiteralNode`, emit a synthetic catalog entry with `name = outer_name + "." + field_name` and the inner members as `fields`

Then:

```bash
mkdir -p /tmp/wxyc-audit-v2/dj-site-widened
cd /Users/jake/Developer/code-audit-pipeline/extractors/typescript
node type-catalog.mjs \
  --root /Users/jake/Developer/WXYC/dj-site \
  --shared /Users/jake/Developer/WXYC/wxyc-shared/src \
  --output /tmp/wxyc-audit-v2/dj-site-widened/catalog.json
# Run the existing 4 queries + the new subset-pairs query.
```

C5 is the same as C3 but with `--root /Users/jake/Developer/WXYC/Backend-Service` and `--shared /Users/jake/Developer/WXYC/wxyc-shared/src`.

### Output format

C2–C5 agents emit a JSON file with one object per finding. Schema:

```json
{
  "finding_id": "C3-run3-001",
  "cluster_id": "exact-duplicates:DJRequestParams+DJBinQuery",
  "severity": "low",
  "blast_radius": { "files": 2, "lines": 6 },
  "issue": "Both declare { dj_id: string } with identical comments; bin imports nothing from authentication.",
  "recommendation": "Promote DJIdParam = { dj_id: string } to a shared location; import from bin.",
  "files": [
    { "path": "lib/features/authentication/types.ts", "line": 142 },
    { "path": "lib/features/bin/types.ts", "line": 9 }
  ],
  "source_cluster": "exact-duplicates.txt"
}
```

`cluster_id` references either a cluster from a pipeline query (e.g., `exact-duplicates:DJRequestParams+DJBinQuery`) or a cold-agent-discovered cluster (e.g., `cold:flowsheet-entry-shadow`). It is the join key for cross-run comparison — two findings with the same `cluster_id` are "the same finding" for Jaccard purposes, regardless of prose differences in `issue` / `recommendation`.

C1 keeps V1's free-form Markdown output unchanged so the direct V1↔V2 comparison is valid.

### Severity rubric (explicit, used in C2–C5)

| Severity | Definition | Example |
|---|---|---|
| **HIGH** | Active drift between a local type and an external contract; or runtime breakage potential (type asserts a shape that doesn't match wire); or shadowed name from `@wxyc/shared` with a parity test pinning equivalence. | `WXYCRole` reimplemented locally; `total_pages` vs `totalPages` wire bug |
| **MEDIUM** | Within-package duplication with multiple live call sites; or dead-code cluster with documented historical motivation; or function-body duplication ≥20 lines. | DJ-registry wire DTOs duplicating skeleton; `betterAuthSessionToAuthenticationData` sync/async pair |
| **LOW** | Stylistic; subset-of-existing-type relations; trivial duplication with one or two call sites; convention observations. | `TrackDetailsResult ⊂ SuggestTrackResult`; `interface` vs `type` style split |

Agents may not coin new severity levels. If a finding doesn't fit one of the three, drop it.

Better still (optional refinement): drop severity from the agent's job entirely and have a separate scoring pass — a sixth condition or a post-hoc analysis — apply this rubric uniformly across all runs. Keeps the agent in the "describe the row" lane and out of the "judge the whole picture" lane. V2 includes severity in the agent's output because the rubric above is explicit enough to discipline it; if severity calibration still drifts more than 1 grade across runs of the same condition, V3 should move severity to a separate pass.

### Prompt regime — "enumerate every cluster, no skipping"

C2–C5 prompts replace V1's "quality over quantity" with:

> Score *every* cluster in `exact-duplicates.txt`, *every* pair in `near-duplicates.txt` (at 0.5 and 0.7 thresholds), *every* shadow in `cross-package-shadows.txt`, and *every* subset pair in `subset-pairs.txt`. Emit one finding row per cluster. Do not skip rows. If a cluster is genuinely uninteresting (e.g., two identical 1-field types with no real overlap), still emit a row with severity=low and a one-line recommendation ("leave as-is"). The output is meant to be filterable — let the reader skip the low-severity rows themselves.

For C4 (cold), the parallel instruction:

> Enumerate every duplicate or near-duplicate type cluster you find. Emit one row per cluster. Apply the same severity rubric. Do not select what to write up; record everything you're confident about.

The shift from "select 5–10 things to write about" to "score every enumerated row" is the central prompt change. It tests whether divergence in V1 was a sampling artifact (predict: yes, dominant) or a substantive disagreement about the issues (predict: minor).

### Trials, staggering, and pinning

5 trials per condition (10 if budget allows). All trials in a condition use:

- Same model + temperature (Opus 4.7 at default for the agent tool, pinned by spec in the prompt)
- Same git SHA of dj-site / Backend-Service (record in the per-trial metadata)
- 30-second stagger between launches to avoid latency-correlated stochastic correlation
- Same scratch-directory layout: `/tmp/wxyc-audit-v2/<condition>/<trial>/output.json`

### Logging

Each trial records a `trace.json` alongside its output:

```json
{
  "trial_id": "C3-run3",
  "started_at": "2026-05-11T15:42:01Z",
  "ended_at":   "2026-05-11T15:48:34Z",
  "tool_calls": 87,
  "tokens": 145000,
  "files_read": [
    { "path": "/tmp/wxyc-audit-v2/dj-site-widened/catalog.json", "order": 1 },
    { "path": "/tmp/wxyc-audit-v2/dj-site-widened/cross-package-shadows.txt", "order": 2 },
    { "path": "lib/features/flowsheet/types.ts", "order": 3 },
    ...
  ],
  "phases": {
    "inventory":   "00:00:00–00:01:12",
    "drill_in":    "00:01:12–00:05:30",
    "synthesis":   "00:05:30–00:06:33"
  }
}
```

`files_read` is the order in which the agent issued Read calls; `phases` is a coarse breakdown the agent self-reports at the end (inventory = scanning catalog/queries, drill-in = source reads, synthesis = writing the output). Together these let us test whether divergence is dominated by *initial-hook choice* (different files read first → different drill paths) or by *reading-order downstream* (same starting hook, different walks afterward) or by *synthesis-step variation* (same observations, different write-ups).

The agent should not be told that this trace is being recorded for analysis — that may bias its behavior. The trace should be assembled from the runtime's existing tool-call log, not from a self-reported summary baked into the prompt.

### Human-with-pipeline baseline (best-effort)

If a senior engineer has 15–30 minutes free, they run *one* trial under condition C3 (pipeline-aware, widened, structured rubric, enumerate). Their output goes into the analysis as a single reference point — not a recall denominator, but a calibration anchor. Questions it answers: are agents in C3 reaching the human's recall, or short of it? Are the agent's severity ratings calibrated similarly to the human's? Are there clusters the human flags that no agent surfaced?

If no engineer time is available, V2 still runs and analyzes without this baseline. The baseline is a "nice to have," not a blocker.

## Measurement protocol

After all trials complete:

1. **Build the union finding set per condition.** For each condition, take the union of all `cluster_id`s emitted across its trials. This is the condition's "covered surface."
2. **Compute pairwise Jaccard within each condition.** For each pair of trials in the same condition, count `|trials A ∩ B| / |A ∪ B|` on `cluster_id`. Report mean, median, min, max, and standard deviation across all C(5, 2) = 10 pairs.
3. **Compute cross-condition recall.** For each finding `cluster_id` in the union of *all* trials across all conditions, record which conditions cover it (in at least 1 trial). This identifies the "what only cold found" and "what only widened pipeline-aware found" sets.
4. **Severity-calibration analysis.** For each `cluster_id` covered by ≥2 conditions, record the modal severity per condition. If C3 and C4 both flag `WXYCRole` but one rates it HIGH and the other MEDIUM, that's calibration drift. Quantify by counting `cluster_id`s with severity disagreement across conditions.
5. **Read-order divergence analysis.** From the `trace.json`s in each condition, compute Jaccard on the first-N files-read (N=5) between trial pairs. If first-N file Jaccard is much higher than findings Jaccard, agents start in the same place and diverge later (reading-order story). If first-N file Jaccard is similar to findings Jaccard, agents diverge from the start (initial-hook story).
6. **Phase-cost analysis.** From the `phases` in `trace.json`, compute mean time spent in inventory / drill-in / synthesis per condition. Tests the hypothesis that cold agents spend disproportionately more time in inventory (which the pipeline pre-computes).

## Predictions to falsify

V1's analysis made several specific claims. V2 should produce numbers that either support or refute each:

| Claim from V1 | V2 prediction (specific number) |
|---|---|
| Output format + prompt regime drive most of V1's divergence. | C2 intra-pair Jaccard ≥ 0.75; C1 reproduces ~0.40. |
| Substrate widening is the route to top-K convergence. | C3 surfaces ≥80% of cold-agent-only findings from V1; C3 intra-pair Jaccard ≥ 0.85. |
| Pipeline-aware (widened) and cold agents converge under controlled prompts. | C3 ∪ C4 covered surface has overlap ≥ 0.70 Jaccard. |
| Frontend vs backend gap is structural. | C5 (Backend-Service) intra-pair Jaccard ≥ C3 (dj-site), and C5 widened-vs-cold gap is smaller than C3's. |
| Pigeonhole-sampling math explained ~40% Jaccard in V1. | C2's enumerate-without-cap regime should collapse this; if it doesn't, the sampling story was wrong and the divergence is deeper than bandwidth. |

If C2 doesn't show ≥0.75 Jaccard, the "free-form prompt invites synthesis where there's nothing to synthesize" claim from V1 was wrong, and the divergence is rooted somewhere else (judgment-level disagreement, model nondeterminism, etc.). If C3 doesn't show ≥0.85, substrate widening is necessary but insufficient and we need a different intervention. Either result is informative.

## What V2 will and will not claim

**V2 can claim:** intra-condition Jaccard distributions with real confidence intervals; relative recall across conditions; whether substrate widening drives convergence on top-K findings; whether output-format and prompt-regime explain V1's divergence; whether the frontend-vs-backend gap survives variable control; calibration drift across conditions.

**V2 cannot claim:** absolute recall (without ground truth); whether the agents are missing important issues that no agent in the V2 cohort happened to surface; whether C3 reaches the human-attainable ceiling (without a human baseline; the optional best-effort baseline gives one reference point but not a population).

## What V3 should reach for if V2's results hold

If V2's predictions land roughly as stated, V3's marginal value comes from:

1. **Ground-truth recall denominator.** The deferred change #1. After V2 has narrowed which conditions to bet on, paying the engineer-time cost for one careful audit unlocks absolute recall numbers.
2. **Audit-as-changelog.** Per [`future-directions.md` §1](./future-directions.md#1-time-as-a-first-class-dimension). Re-run C3 against dj-site quarterly; surface what changed in the structural surface across runs. The pipeline's biggest selling point is across-audit, not within-audit, and V2 still doesn't test it.
3. **Wider language coverage.** If V2 confirms the substrate-coverage hypothesis on TypeScript, the contract additions transfer to Python and other extractors. The dj-site-vs-Backend-Service test (C3 vs C5) is a within-language analogue of what a future polyglot test would do.

If V2's predictions *don't* land, V3 needs to reconsider whether the principle's reproducibility claim holds at all, or whether agent stochasticity sets a floor on findings divergence that no substrate or prompt design can push below.

## See also

- [`dj-site-divergence-experiment.md`](./dj-site-divergence-experiment.md) — V1 results doc; the experiment this protocol is the successor to.
- [`pipeline-contract.md`](./pipeline-contract.md) — JSON contract being extended by V2's substrate-widening additions.
- [`case-study.md`](./case-study.md) — origin of the deterministic-extraction principle that V2 stress-tests.
- [`future-directions.md`](./future-directions.md) — §1 (time as first-class) and §2 (broader extractor kinds) are the natural successors if V2's results support the substrate-widening hypothesis.
- Raw V1 outputs (for V2's C1 sanity-check baseline): `/tmp/wxyc-audit/dj-site/results/{exp1a,exp1b,exp2a,exp2b}.md`. V2 outputs will land at `/tmp/wxyc-audit-v2/<condition>/<trial>/output.json`.
