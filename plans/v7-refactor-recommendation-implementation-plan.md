# V7 Refactor-Recommendation Experiment — Implementation Plan

> Operationalizes [`docs/refactor-recommendation-experiment-methodology.md`](../docs/refactor-recommendation-experiment-methodology.md) (§15 roadmap, §16 MVP, §17 decisions outstanding) together with the three companion docs: [plant manifest](../docs/refactor-recommendation-experiment-plant-manifest.md), [agent prompt](../docs/refactor-recommendation-experiment-agent-prompt.md), [macro candidates](../docs/refactor-recommendation-experiment-macro-candidates.md). Each step cites the methodology section it implements.

## TL;DR

Round 1 runs the **MVP shape** per [§16](../docs/refactor-recommendation-experiment-methodology.md#mvp): 25 plants × 5 categories (Cats. 1–5) × 2 conditions (S1 V6-substrate, S2 V7-substrate) × 3 trials × 1 model tier = 150 recommendations × ~$0.06 ≈ $9 trial-execution + $50–110 sub-experiments at Sonnet 4.6 rates (round 1's pinned model per §8 decision #2). **Total budget: $60–120. Wallclock: 4–6 weeks.** Cats. 6 (subclass lift), 7 (macro synthesis), 8 (composition) defer to round 2.

Plan is structured as: (§1) round-zero prerequisites that must close before Phase A starts, (§2–§6) the five-phase execution per [§15 roadmap](../docs/refactor-recommendation-experiment-methodology.md#roadmap) with concrete deliverables and acceptance criteria each, (§7) decisions resolved with doc defaults, (§8) risk-driven exit ramps.

## 1. Round-zero prerequisites (before Phase A starts)

These are non-Phase-A items that unblock Phase A. All three run in parallel — none takes more than half a day. **All three must close before Phase A begins**, and §1.3 (directory shell) must close before any Phase B PR can land, since Phase B's enrichment PRs may need a path to commit artifacts into.

Each item is run in its own git worktree per the [project CLAUDE.md](../CLAUDE.md#git-workflow) convention.

### 1.1 Close [issue #5](https://github.com/jakebromberg/code-audit-pipeline/issues/5)

**Decision (resolving [§17 decision #6](../docs/refactor-recommendation-experiment-methodology.md#decisions-outstanding)):** land issue #5 first. The issue is in the V5 backlog regardless; V7 promotes it from "nice-to-have" to "blocker because the per-cluster rubric scores incoherently without it." The defensive fuzzy-matcher path is an emergency fallback only — listed below under "fallback" — not a parallel option. If §1.1 stalls past two weeks, escalate before falling back.

- **Deliverable:** PR against `pipeline/queries/*.jq` and a new `pipeline/queries/_canonical.jq` that emits a stable, content-addressed `cluster_id` on every cluster row in JSONL. Existing `.txt` outputs preserved as a side-channel for human reading. Schema documented in [`pipeline-contract.md`](../docs/pipeline-contract.md).
- **Acceptance:** running the 8 V6 queries against `wxyc-ios-64` produces JSONL output where every row carries `cluster_id`; the canonical-form rules (sorted names, `+` for n-ary, `__` for directed subset-pairs, repo-relative paths for file-duplicates) live in `_canonical.jq` and are unit-tested.
- **Fallback if scope-blocked:** ~50-line fuzzy ID matcher in the auto-scorer that canonicalizes agent-coined IDs against substrate-coined IDs before lookup. [§13 risk 7](../docs/refactor-recommendation-experiment-methodology.md#risks) frames the failure mode this defends against.

### 1.2 Update the project [`README.md`](../README.md) to match V7 framing

Per [§17 decision #8](../docs/refactor-recommendation-experiment-methodology.md#decisions-outstanding) and [§18 V6 postscript](../docs/refactor-recommendation-experiment-methodology.md#v6-postscript). The README currently describes the substrate as a deduplication / clustering tool; the project's working definition of its deliverable is "actionable refactor recommendations." A stale README is a contamination vector for any S0 cold-agent run that follows it into the codebase.

**MVP scope note on contamination urgency.** Round 1 skips the S0 (cold) condition per [§16](../docs/refactor-recommendation-experiment-methodology.md#mvp), so the README's framing has no direct contamination path into the agent's behavior for round 1. The update is still required before Phase A — the framing has to be settled before pre-registration freezes — but the contamination-vector argument lands more sharply for round 2 (when S0 picks up).

- **Deliverable:** README edit framing the project as "structural cataloging + cluster surfacing → refactor recommendations," with V6 results positioned as the input-layer validation and V7 as the output-layer experiment. V6 results doc gets a postscript per [§18](../docs/refactor-recommendation-experiment-methodology.md#v6-postscript).
- **Acceptance:** README's "what is this" and "what does the deliverable look like" sections match the methodology doc's framing; V6 results doc has a clearly-marked postscript section pointing at V7.

### 1.3 Decide on the experiment workspace layout

The methodology doc references a target path `experiments/v7-refactor-recommendation/` that doesn't exist yet. Create the directory shell so Phase A has somewhere to land artifacts:

```
experiments/v7-refactor-recommendation/
  plant-manifest.yaml         # Phase A primary output (replaces companion .md schema)
  prompt.md                   # Phase A; copies from the companion agent-prompt doc, hash-pinned
  rubric.yaml                 # Phase A; extracted from §8 + per-plant manifest entries
  reproducibility.yaml        # Phase D filled in
  results.md                  # Phase E
  trial-logs/                 # Phase D per-recommendation telemetry sidecar
  rubric-modifications.md     # Phase D/E if post-hoc adjustments occur
```

- **Deliverable:** empty directory shell committed, with a short `README.md` inside pointing at the methodology doc. No content yet.
- **Acceptance:** path exists, `git status` is clean after commit.

## 2. Phase A — Plant manifest + rubric (1–2 weeks)

Per [§15 Phase A](../docs/refactor-recommendation-experiment-methodology.md#roadmap). MVP scope: design 25 plants (5 categories × [4 canonical + 1 restraint] each = 20 canonical + 5 restraints).

### 2.1 Category-mix calibration

Per §8 decision #7 (overriding the methodology §17 default of "accept the bias"). Sample wxyc-ios-64 PR titles matching `refactor|extract|consolidate|lift|generic|default impl` over a meaningful history window. Classify each PR by which of the 5 MVP categories its title implies (Cat. 1 extract-to-common, Cat. 2 protocol inheritance, Cat. 3 default implementation, Cat. 4 PAT introduction, Cat. 5 generic parameterization). Compute the empirical distribution.

- **Output:** `experiments/v7-refactor-recommendation/category-mix-calibration.md` with the PR count per category, the percentages, and a recommended reweighting of plant allocation within the 25-plant MVP budget if the empirical distribution differs from uniform (5-per-category) by more than ~20pp on any axis.
- **Acceptance:** calibration doc committed; subsequent §2.2 source-type sampling uses the per-category plant counts from this calibration (defaulting back to 5-each if the empirical distribution is approximately uniform).
- **Effort:** ~1 day, mostly `gh pr list` plus a small classifier (regex-and-judgment, not LLM-required).
- **Caveat:** PR-title classification has high noise — most refactor PRs don't title themselves consistently. Treat the resulting mix as a coarse signal, not a precision metric. The calibration mitigates the methodology §13 risk-1 bias but doesn't eliminate it.

### 2.2 Source-type sampling

Per the [V6 plant-manifest precedent](../docs/wxyc-ios-64-experiment-plant-manifest.md), each plant derives from a real wxyc-ios-64 declaration. Run a sampling pass to pick source types for each of the 25 plants:

- **Cat. 1 extract-to-common (5 plants):** types that appear in ≥2 packages with shape duplication or near-duplication. Existing V6 plants 1–4 are precedent.
- **Cat. 2 protocol inheritance (5 plants):** parallel protocol pairs with shared member subset. Plant 2.4's "sibling with missing parent" template in the [companion manifest](../docs/refactor-recommendation-experiment-plant-manifest.md) is the canonical shape.
- **Cat. 3 default implementation (5 plants):** protocol + ≥3 conformers with identical method bodies. Plant 3.1 in the companion manifest is the canonical shape.
- **Cat. 4 PAT introduction (5 plants):** protocol pairs differing only by one type slot. Plant 4.1 (`TrackContainer` / `ShowContainer`) is the canonical shape.
- **Cat. 5 generic parameterization (5 plants, split ~3 function + ~2 struct):** function pairs differing only by type identifiers (erased body match) and struct pairs differing only at one type slot. Plant 5.1 is the canonical shape.
- **Restraint twins (1 per category, 5 total):** each twin shares its canonical's shape but has a context flag (test, codegen, sample-app, mock) or boundary signal that marks it as intentional duplication.

**Acceptance:** 25 source types named in `plant-manifest.yaml` with file paths into wxyc-ios-64; cross-checked that no plant accidentally tests two categories at once (per [§10 item 2](../docs/refactor-recommendation-experiment-methodology.md#pre-registration) review criteria).

### 2.3 Per-plant manifest entries

Expand each entry against the YAML schema documented in the [companion plant-manifest doc](../docs/refactor-recommendation-experiment-plant-manifest.md). Fields per entry: `plant_id`, `category`, `source_type`, `plant_locations`, `expected_substrate_signals`, `primary_answer`, `specifics_tolerance`, `alternative_answers`, `wrong_answers`, `restraint` flag.

**Acceptance:** 25 entries committed at `experiments/v7-refactor-recommendation/plant-manifest.yaml`; each entry passes a yaml-schema check; restraint twins explicitly distinguish their context signal from the canonical pair's shape.

### 2.4 Rubric extraction

Per [§8 scoring rubric](../docs/refactor-recommendation-experiment-methodology.md#scoring-rubric). The rubric is mostly in the methodology doc as prose + a scoring table; for execution it needs to land as machine-readable form.

- Extract the scoring table to `experiments/v7-refactor-recommendation/rubric.yaml`.
- Extract the per-plant `rationale_must_cite` substrings into per-plant manifest entries.
- Per [§17 decision #5](../docs/refactor-recommendation-experiment-methodology.md#decisions-outstanding), default the weak-rationale policy to (a): auto-score 0.5 when category and specifics match but a required citation is missing, with the panel-validated grounding-audit sample (10–20% per [§8](../docs/refactor-recommendation-experiment-methodology.md#scoring-rubric)) catching systematic abuse.

**Acceptance:** `rubric.yaml` committed; an auto-scorer dry-run against the worked examples in [§20.1–20.5](../docs/refactor-recommendation-experiment-methodology.md#worked-example) produces the scores those examples assert.

### 2.5 `/review-plan` gate on the manifest

Per [§10 item 2](../docs/refactor-recommendation-experiment-methodology.md#pre-registration). Submit the committed `plant-manifest.yaml` + `rubric.yaml` for review. Reviewer checks:

- Do plant categories actually map to distinct refactors? (Are Plant 4.1 PAT and Plant 5.1 generic-struct distinguishable, or do they collide?)
- Are alternative answers defensible? (Specifically, do Plant N's alternative-weight values track real Swift idiomaticity?)
- Are restraint twins distinguishable from their canonicals *only* via context flags, not via field-level shape?
- Does any plant accidentally test two categories at once?

**Acceptance:** review approval; reviewer notes committed alongside the manifest at `experiments/v7-refactor-recommendation/manifest-review-notes.md`. If review requires manifest revisions, iterate until approval. The [V6 plant manifest](../docs/wxyc-ios-64-experiment-plant-manifest.md) is the closest precedent for plant-level review discipline on a Swift codebase; the [V3 manifest review](../docs/dj-site-divergence-experiment-v3-plant-manifest.md) is the closest precedent for full-experiment plant-design review (V3 included expected-answers alongside plant shapes, which V6 didn't need to).

## 3. Phase B — Substrate V7 enrichments (3–4 weeks, parallelizable with Phase A after week 1)

Per [§15 Phase B](../docs/refactor-recommendation-experiment-methodology.md#roadmap) priority order, scoped to MVP-min (skip class-inheritance edges/resolution and population clustering, since Cats. 6 and 7 are dropped). Each enrichment lands as a separate PR with tests and doc updates.

### 3.1 Name/type split in type-catalog ([§6.1](../docs/refactor-recommendation-experiment-methodology.md#enrichment-name-type-split))

- **What:** `fields` schema gains a parallel `{name, type, isOptional, isStatic}` structured form. Existing flat `field_strings` preserved for V6 query compatibility.
- **Where:** [`extractors/swift/Sources/swift-catalog/TypeCatalogVisitor.swift`](../extractors/swift/Sources/swift-catalog/TypeCatalogVisitor.swift), [`extractors/typescript/type-catalog.mjs`](../extractors/typescript/type-catalog.mjs), [`docs/pipeline-contract.md`](../docs/pipeline-contract.md).
- **Acceptance:** V6 queries against the V7 catalog produce byte-identical output to V6 queries against the V6 catalog; new structured field readable in jq via `.fields_structured[]`.

### 3.2 Protocol-conformance edges ([§6.2](../docs/refactor-recommendation-experiment-methodology.md#enrichment-conformance-edges))

- **What:** for each `struct/class/enum Foo: Bar, Baz`, emit `Foo -conforms-> Bar` edges. Stored on the type record as `conforms_to: [...]`.
- **Where:** SwiftSyntax inheritance-clause walking in `TypeCatalogVisitor.swift`; TypeScript ASTs's `implements` clause; `pipeline-contract.md`.
- **Acceptance:** spot-checked against 10 known wxyc-ios-64 conformances (e.g., `RadioStation: Codable, Hashable`).

### 3.3 Protocol-inheritance edges + resolution ([§6.3](../docs/refactor-recommendation-experiment-methodology.md#enrichment-inheritance-edges))

- **What:** edges (`protocol B: A` emits `B -inherits-> A`) plus a second-pass resolution step that unions parent `fields` into child `fields` (marking `resolved_from: "protocol-inheritance"`, mirroring V5's `resolved_from: "intersection"` convention).
- **Where:** `TypeCatalogVisitor.swift` for edges; a post-processing pass in the extractor pipeline for resolution.
- **Acceptance:** child protocol's `fields` after resolution contains parent's required members; V6's [known follow-up](../docs/wxyc-ios-64-experiment-results.md#what-stays-as-future-work) for protocol-inheritance is closed.
- **Note:** class-inheritance edges + resolution **deferred to round 2** since Cat. 6 is dropped in MVP per [§16](../docs/refactor-recommendation-experiment-methodology.md#mvp).

### 3.4 Function-body type-erased signature ([§6.4](../docs/refactor-recommendation-experiment-methodology.md#enrichment-erased-body-sig))

- **What:** second normalized function body where `IdentifierTypeSyntax` nodes are replaced with `_T1`, `_T2`, … in order of first appearance. New fields: `body_hash_erased`, `body_lines_erased`.
- **Where:** [`FunctionCatalogVisitor.swift`](../extractors/swift/Sources/swift-catalog/FunctionCatalogVisitor.swift), [`function-catalog.mjs`](../extractors/typescript/function-catalog.mjs).
- **Acceptance:** two functions identical except for type identifiers produce identical `body_hash_erased`; their existing non-erased hashes differ.

### 3.5 Package-dependency graph ([§6.5](../docs/refactor-recommendation-experiment-methodology.md#enrichment-package-graph))

- **What:** parse each `Package.swift` for inter-package dependencies. Emit `package-graph.json`. For the 3 app targets without `Package.swift`, extract from `WXYC.xcodeproj/project.pbxproj` using brace-counting text processing (the xcodeproj gem and pbxproj library fail on complex projects, per wxyc-ios-64's own CLAUDE.md).
- **Where:** new file `extractors/swift/Sources/swift-catalog/PackageGraphExtractor.swift`.
- **Acceptance:** the 19 Shared packages + 3 app targets all appear as nodes; spot-check 5 known edges (e.g., `iOS -> Shared/Core`, `Shared/Caching -> Shared/Core`).
- **Submodule note:** `Shared/Wallpaper` is a private git submodule; verify `git submodule update --init --recursive` ran before extraction or Wallpaper-package plants will be unreachable.

### 3.6 Context flags ([§6.6](../docs/refactor-recommendation-experiment-methodology.md#enrichment-context-flags))

- **What:** heuristic flags `is_test`, `is_codegen`, `is_sample_app`, `is_mock` on each type-catalog and function-catalog record.
- **Where:** walker-level detection in the extractor.
- **Acceptance:** spot-checked against ~30 known files of each kind; restraint-twin recognition in §4 relies on these flags.

### 3.7 Seven new queries ([§6.8](../docs/refactor-recommendation-experiment-methodology.md#enrichment-new-queries))

MVP scope: 5 of the 7 (skip `subclass-lift-candidates.jq` and `macro-candidates.jq` since Cats. 6 and 7 are out). Each query lives at `pipeline/queries/<name>.jq`:

- `pat-candidates.jq` (depends on §3.1, used by Cat. 4)
- `default-impl-candidates.jq` (depends on §3.2, used by Cat. 3)
- `protocol-inheritance-candidates.jq` (depends on §3.3, used by Cat. 2)
- `generic-function-candidates.jq` (depends on §3.4, used by Cat. 5)
- `generic-struct-candidates.jq` (depends on §3.1, used by Cat. 5)

**Acceptance per query:** documented invocation in the file header (with `-r`), operates on the canonical catalog schema, produces multi-line raw output, and surfaces ≥1 candidate against the unmodified wxyc-ios-64 catalog as a sanity check.

## 4. Phase C — Plant tree + cluster generation (3–5 days)

Per [§15 Phase C](../docs/refactor-recommendation-experiment-methodology.md#roadmap). Plants get injected into `examples/swift-plants-v7/` (new directory; V6 tree preserved at `examples/swift-plants/`).

### 4.1 Plant-tree creation

Per Phase A's manifest, hand-author 25 plant files mirroring the [V6 plant-tree](../examples/swift-plants/) convention. Naming uses `_Plant_<typeName>.swift` prefix consistently with V6. **No `// Plant` comments** in source — the contamination-vectors mitigation in [§10](../docs/refactor-recommendation-experiment-methodology.md#pre-registration) requires plant-naming leaks be closed at the source level.

**Acceptance:** 25 plant files under `examples/swift-plants-v7/`; `grep -ri "// Plant\|# Plant" examples/swift-plants-v7/` returns nothing.

### 4.2 Plant-tree serving strategy

Per [§17 decision #4](../docs/refactor-recommendation-experiment-methodology.md#decisions-outstanding), default is a flat non-git directory at `/tmp/wxyc-audit/plants-v7/`.

- **Deliverable:** `scripts/serve-plants-v7.sh` — executable bash script that copies wxyc-ios-64's first-party Swift files plus the 25 files from `examples/swift-plants-v7/` into `/tmp/wxyc-audit/plants-v7/`, scrubs `.git/` and any `.gitignore`-style metadata, and chmod-locks the result read-only.
- **Acceptance:** running `scripts/serve-plants-v7.sh` produces `/tmp/wxyc-audit/plants-v7/` with the 25 plant files plus the unmodified wxyc-ios-64 tree merged in; `git status` and `git log` in that directory fail with "not a git repository"; `grep -r "// Plant\|# Plant" /tmp/wxyc-audit/plants-v7/` returns nothing.

### 4.3 Cluster generation per condition

- **S1 inputs:** run V6 substrate (the 8 V6 queries at HEAD) against the planted tree. Capture each query's output as JSONL with `cluster_id` (from §1.1) at `experiments/v7-refactor-recommendation/clusters-s1/`.
- **S2 inputs:** run V7 substrate (V6's 8 + V7's 5 new queries) against the same planted tree. Capture at `experiments/v7-refactor-recommendation/clusters-s2/`.
- **S0 cluster generation N/A** (MVP skips S0 per [§16](../docs/refactor-recommendation-experiment-methodology.md#mvp)).

**Acceptance:** for each S1 query, all expected plants from the manifest's `expected_substrate_signals` field appear; same for S2. Recall is plant-level, not just row-count.

### 4.4 Plant-recall sanity check

Build `examples/swift-plants-v7/analyzer.mjs` by forking [`examples/swift-plants/analyzer.mjs`](../examples/swift-plants) and adapting it to consume the V7 plant-manifest YAML (V6's analyzer reads its manifest inline; V7's manifest is the external YAML from §2.3). The v7 analyzer reads `experiments/v7-refactor-recommendation/plant-manifest.yaml` plus the S1 and S2 cluster JSONL output directories from §4.3 and prints per-plant recall.

Invocation: `node examples/swift-plants-v7/analyzer.mjs --clusters-s1 experiments/v7-refactor-recommendation/clusters-s1/ --clusters-s2 experiments/v7-refactor-recommendation/clusters-s2/`.

Confirm:

- S1 recall ≈ V6 baseline (no regression from V6→V7 substrate changes on V6 queries).
- S2 recall: every plant in the manifest surfaces in at least one of its `expected_substrate_signals`.

**Acceptance:** the analyzer is committed under `examples/swift-plants-v7/`, reads the external YAML manifest, and reports ≥23/25 plants surface in S2; for any plant that doesn't, the manifest gets an explicit `expected_substrate_gap: true` annotation per the V6 precedent for plant 20.

## 5. Pre-flight validation gate (before Phase D, ~2 hours, ~$5)

Per [§15 pre-flight](../docs/refactor-recommendation-experiment-methodology.md#roadmap). All five checks must pass before any trial launches:

1. **Substrate smoke test:** re-run substrate against a 3-plants-per-category slice; confirm `catalog_hashes` and `query_output_hashes` match values captured in `reproducibility.yaml` at pre-registration.
2. **Prompt rendering test:** render the [agent prompt template](../docs/refactor-recommendation-experiment-agent-prompt.md) against one normalized cluster row; confirm context-window fit and no unfilled template variables.
3. **Single-cluster end-to-end dry run:** send one cluster row through the pinned model, score the response, verify JSON-schema match. ~$0.06 at Sonnet rates.
4. **Cost projection:** multiply the MVP recommendation count (150) by the pinned `api_pricing_snapshot` rates; confirm ≤ $120 budget envelope at Sonnet 4.6 rates (the round-1 default per §8 decision #2). If a later round upgrades to Opus, re-check against the $200–300 envelope that implies.
5. **Manifest-rubric review confirmation:** the §2.5 `/review-plan` approval is committed; contamination-vectors check (no `// Plant` comments, no plant-naming commits) passes.

**Gate behavior:** any failure aborts Phase D launch and loops back to the relevant phase. The pre-flight is cheap insurance against the four-figure spend a misconfigured Phase D would otherwise consume.

## 6. Phase D — Trial execution (2–5 days wallclock, ~$9 trial + ~$50–110 sub-experiments)

Per [§15 Phase D](../docs/refactor-recommendation-experiment-methodology.md#roadmap) and [§16 MVP](../docs/refactor-recommendation-experiment-methodology.md#mvp). 25 plants × 2 conditions (S1, S2) × 3 trials × 1 model tier = 150 recommendations.

### 6.1 Model pinning

Per [§8 decision #2](#decisions-resolved-with-doc-defaults), pin to the latest Claude Sonnet 4.6 tier with a date-pinned suffix (e.g., `claude-sonnet-4-6-20260101`). Pinned model identifier and `model_parameters` (temperature 0.0 default) recorded in `reproducibility.yaml`. The Opus tier costs ~5× more per token at the prompt/response sizes V7 uses; Sonnet keeps the MVP budget at $60–120 total, Opus pushes it to ~$200–300.

### 6.2 Trial harness

Build a small harness (~200 lines, language flexible — Python or TypeScript both fine) that:

- Reads `experiments/v7-refactor-recommendation/clusters-s1/` and `clusters-s2/` JSONL outputs.
- For each cluster row, normalizes to the agent-prompt input shape per the [agent-prompt §3](../docs/refactor-recommendation-experiment-agent-prompt.md#3-cluster-row-input-shape-what-the-agent-receives).
- Renders the prompt template per [agent-prompt §1](../docs/refactor-recommendation-experiment-agent-prompt.md#1-full-prompt-text).
- Calls the pinned model API; captures the structured JSON response.
- Writes per-recommendation telemetry to `experiments/v7-refactor-recommendation/trial-logs/<condition>/<trial>/<cluster_id>.json` (cluster_id, condition, trial, input/output tokens, latency, error class, raw response).

### 6.3 Cost-control gates during execution

Per [§15 cost-control gates](../docs/refactor-recommendation-experiment-methodology.md#roadmap):

1. **Per-recommendation token cap:** 50K combined; abort that recommendation if exceeded, log as `trial-overrun`.
2. **Per-condition budget cap:** alert at 80% of condition budget (~$3.50 per condition at Sonnet rates — half of the $9 MVP trial-execution split across S1 and S2 minus a 20% headroom), halt at 100%. The per-condition envelope is small enough that the cap's actionable role is catching surprise pricing changes between pre-registration and execution rather than runaway recommendations.
3. **Mid-run abort on stop-the-line failure modes:** after 25% of trials in a condition, run the [§14.1 substrate-didn't-help](../docs/refactor-recommendation-experiment-methodology.md#pre-mortem) and [§14.4 batching variance](../docs/refactor-recommendation-experiment-methodology.md#pre-mortem) signature checks; pause if either fires.

### 6.4 Sub-experiments (optional within MVP budget)

- **Natural-findings sub-experiment** per [§12](../docs/refactor-recommendation-experiment-methodology.md#cant-measure): run the agent prompt against the [V6 natural findings](../docs/wxyc-ios-64-experiment-results.md#conclusion) (`DebugMetricsProvider`, `PlayerState`/`PlaybackState`, `StreamingService`/`MusicServiceIdentifier`). Panel-graded.
- **Cross-tier comparison** per [§17 decision #2](../docs/refactor-recommendation-experiment-methodology.md#decisions-outstanding): default is **deferred to round 2** to keep MVP scope tight.

**Acceptance:** all 150 recommendations completed without exceeding $120 total spend (at Sonnet rates; $250 if upgraded to Opus); per-recommendation telemetry committed; cost-control gates' behavior recorded in `reproducibility.yaml`.

## 7. Phase E — Scoring + writeup (2–3 weeks)

Per [§15 Phase E](../docs/refactor-recommendation-experiment-methodology.md#roadmap).

### 7.1 Auto-scoring

Build the auto-scorer (~300 lines) per [§8 decision rule](../docs/refactor-recommendation-experiment-methodology.md#scoring-rubric). Inputs: per-recommendation JSON + plant-manifest entries. Outputs: per-plant score, per-category recall, false-positive rate on restraints, grounding rate (citation substring presence), specificity rate.

Auto-scoreable cases (per [§8](../docs/refactor-recommendation-experiment-methodology.md#scoring-rubric)): primary-category match with specifics in tolerance; alternative match; wrong-answer match; restraint correctness. Everything else routes to panel.

### 7.2 Panel review

Per [§17 decision #3](../docs/refactor-recommendation-experiment-methodology.md#decisions-outstanding) default: 3 internal reviewers, blind to condition, ~4 hours each. Panel scores:

- All `category == "other"` recommendations.
- All primary/alternative matches with specifics out of tolerance.
- The 10–20% citation-grounding audit sample per [§8](../docs/refactor-recommendation-experiment-methodology.md#scoring-rubric).
- The natural-findings sub-experiment recommendations from §6.4.

Inter-rater reliability reported as Fleiss κ per [§12](../docs/refactor-recommendation-experiment-methodology.md#cant-measure).

### 7.3 Results writeup

Companion `results.md` at `experiments/v7-refactor-recommendation/results.md`, structured like [V5 results](../docs/dj-site-divergence-experiment-v5-results.md) and [V6 results](../docs/wxyc-ios-64-experiment-results.md). Headline metric: the 2-D point (recall on canonical plants, 1 − FPR on restraint plants) per [§9](../docs/refactor-recommendation-experiment-methodology.md#restraint). Per-category breakdown of S2 − S1 deltas. Identifies which categories benefited from V7 enrichments vs which still need V8+.

`reproducibility.yaml` finalized with execution-time values (`model_versions`, `model_parameters`, `api_pricing_snapshot`, `trial_date_range`, `panel_composition`, `rubric_modifications` pointer).

**Acceptance:** results doc + reproducibility.yaml committed; PR opened against main with `Closes #<phase-A-tracker-issue>` body.

## 8. Decisions resolved with doc defaults

Per [methodology §17 — Decisions outstanding before kickoff](../docs/refactor-recommendation-experiment-methodology.md#decisions-outstanding), the plan adopts the doc's default position on each of the 9 open decisions enumerated there. The numbering below matches §17 1-to-1 so a reviewer can verify the plan against the doc without re-reading. Listed so the reviewer can flag any default to override:

| # | Decision | Resolution |
|---|---|---|
| 1 | Round 1 scope | **MVP** (25 plants, 5 categories, S1+S2, $60–120 at Sonnet rates) |
| 2 | Model versions to pin | **Latest Claude Sonnet 4.6 tier with date-pinned suffix**, single tier for round 1. Overrides the methodology §17 doc default of Opus; the Sonnet pin drops MVP envelope from $100–200 (Opus) to $60–120 (Sonnet) at ~5× cheaper per-token. Decided 2026-05-12. Escalate to Opus in round 2 if S1-vs-S2 deltas are inconclusive and the suspected cause is model capability |
| 3 | Panel size and protocol | **3 internal reviewers**, blind to condition, ~4 hours each |
| 4 | Plant-tree serving | **Flat non-git directory** at `/tmp/wxyc-audit/plants-v7/` |
| 5 | Weak-rationale scoring | **(a) auto-score 0.5**, with 10–20% panel-validated grounding audit |
| 6 | Issue #5 status | **Land first** (in §1.1 of this plan); defensive matcher only as fallback |
| 7 | Category-mix calibration | **Calibrate via wxyc-ios-64 PR-history sampling in §2.1** (overrides methodology §17 default of "accept the bias"). The calibration is ~1 day and the result reweights plant allocation within the 25-plant MVP budget if the empirical distribution is materially non-uniform |
| 8 | README update timing | **Update before Phase A** (§1.2 of this plan) |
| 9 | Population-clustering calibration | **Out of scope for round 1** (Cat. 7 dropped) |

## 9. Risk-driven exit ramps

For each of the top five failure modes in [§14 pre-mortem](../docs/refactor-recommendation-experiment-methodology.md#pre-mortem), the plan's response:

- **§14.1 substrate didn't help (S0 ≈ S2):** MVP skips S0, so this signature manifests as S1 ≈ S2 instead. If S1 ≈ S2 within ±5pp across all categories, report cleanly per §14.1 recovery; identify which categories *did* benefit. Don't claim a substrate win where none exists. Round 2 may pick up S0 to triangulate.
- **§14.2 restraints fail to bite (FPR > 25%):** per-restraint breakdown crossed with context-flag attribution distinguishes context-blind from informed FPR. Context-blind → tighten prompt; informed → report as model-capability finding.
- **§14.3 rubric undercovers (panel >50%):** §6.4 sub-experiments capped at $150 absorb some panel cost; if dominated by `other`, widen taxonomy in round 2; if dominated by specifics-out-of-tolerance, log to `rubric-modifications.md` and re-score.
- **§14.4 batching variance returns:** §1.1 (issue #5) plus the agent prompt's sharp "one recommendation per row" language are the defensive measures. If batching still appears, sharpen prompt and retry affected condition.
- **§14.5 plant artifice doesn't transfer:** §6.4 natural-findings sub-experiment is the explicit measurement. Report the gap as the natural-findings result; plant-derived numbers retain methodology-validation validity.

## 10. Tracking and workflow

**Issue graph.** Single tracker issue: **"V7 refactor-recommendation experiment — MVP round 1"** filed against the project's repo. Sub-issues for each of §1.1, §1.2, §1.3, Phase A milestones, Phase B's 5 enrichment PRs (MVP-scoped), Phase C, Phase D, Phase E. The tracker body lists all children with status; sub-issue and dependency edges wired per the GitHub sub-issues + dependencies API.

Critical dependencies (blocked_by): Phase A blocks Phase C; Phase B blocks Phase C; Phase C blocks the pre-flight gate; pre-flight blocks Phase D; Phase D blocks Phase E. Issue #5 (§1.1) blocks every new query in §3.7.

**Worktree discipline.** Per the [project CLAUDE.md](../CLAUDE.md#git-workflow), every new line of development starts with a worktree created before any code is written. Concretely for this plan:

- §1.1, §1.2, §1.3 each run in their own worktree (3 parallel worktrees).
- Each Phase B enrichment (§3.1–§3.7) runs in its own worktree, since each lands as a separate PR.
- Phase A's manifest design runs in a single worktree; Phase A's rubric extraction in another; Phase A's `/review-plan` iterations happen as commits on the manifest worktree.
- Phase C, Phase D harness, Phase D execution logs, Phase E auto-scorer, Phase E results writeup each run in a dedicated worktree.
- Worktree paths follow the org convention `~/Developer/code-audit-pipeline-swift-substrate-<short-name>` and clean up via `git worktree remove` once the corresponding PR merges.

## See also

- [`docs/refactor-recommendation-experiment-methodology.md`](../docs/refactor-recommendation-experiment-methodology.md) — the methodology spec this plan implements.
- [`docs/refactor-recommendation-experiment-plant-manifest.md`](../docs/refactor-recommendation-experiment-plant-manifest.md) — per-plant YAML schema, expanded in Phase A.
- [`docs/refactor-recommendation-experiment-agent-prompt.md`](../docs/refactor-recommendation-experiment-agent-prompt.md) — full prompt + per-category specifics schemas, used by Phase D.
- [`docs/refactor-recommendation-experiment-macro-candidates.md`](../docs/refactor-recommendation-experiment-macro-candidates.md) — out of round 1 scope; round 2 reference for Cat. 7.
- [Issue #5](https://github.com/jakebromberg/code-audit-pipeline/issues/5) — substrate-emitted `cluster_id`, the V7 prerequisite.
- [`experiments/v7-refactor-recommendation/glossary.md`](../experiments/v7-refactor-recommendation/glossary.md) — shared V7 vocabulary (S1/S2, substrate, plants, metrics, all 13 auto-scorer match labels, binding rules, rounds/phases, code refs, PR/issue index).
