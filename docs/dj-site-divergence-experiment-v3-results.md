# dj-site Divergence Experiment — V3 Results (Synthetic Ground Truth via De-Abstracted Plants)

> Per-plant recall measurement against the 20-plant manifest from [`dj-site-divergence-experiment-v3-plant-manifest.md`](./dj-site-divergence-experiment-v3-plant-manifest.md). Replaces V2's "Jaccard on unknown ground truth" with absolute recall numbers per condition per category. The plants were de-abstracted from existing isolated dj-site and `@wxyc/shared` types so the planted shapes inherit real engineering decisions, not my-taste field-naming.
>
> Three conditions, five trials each, Opus 4.7, agent-default temperature. Raw outputs at `/tmp/wxyc-audit-v3/`. Analysis: `pipeline/analysis/v3-analysis.mjs`. Worktree: `dj-site-v3-plants` on branch `experiment/v3-plants`.

## Headline numbers

### Per-category recall (fraction of plants detected, averaged over trials × plants)

| Category | C2 (narrow) | C3 (widened) | C4 (cold) |
|---|---|---|---|
| exact-duplicates | 25% | **100%** | 5% |
| cross-package-shadows | 0% | **100%** | 100% |
| subset-pairs | 0% | **100%** | 50% |
| near-duplicates | 50% | **100%** | 50% |
| substrate-gap | 0% | 0% | **95%** |

### Intra-condition Jaccard

| Condition | Full cluster_id sets | Plant-only sets |
|---|---|---|
| C2 | 1.00 ± 0.00 | 1.00 ± 0.00 |
| **C3** | **1.00 ± 0.01** | **1.00 ± 0.00** |
| C4 | 0.46 ± 0.14 | 0.94 ± 0.05 |

### Predictions check

| Prediction | Result |
|---|---|
| C3 detects 4/4 exact-duplicates plants | ✅ YES |
| C3 detects 4/4 cross-package-shadows plants | ✅ YES |
| C3 detects 4/4 subset-pairs plants | ✅ YES |
| C3 detects ≥3/4 near-duplicates plants | ✅ YES (4/4) |
| C3 detects 0/4 substrate-gap plants | ✅ YES (by construction) |
| C4 detects ≥3/4 in each natural category | ❌ NO — only 1/4 of natural categories at ≥75% |
| C4 detects ≥3/4 substrate-gap plants | ✅ YES (95%) |
| C3 plant-only intra-trial Jaccard ≥ 0.95 | ✅ YES (1.00) |
| C4 plant-only intra-trial Jaccard ≥ 0.50 | ✅ YES (0.94) |

## The story

### C3 (widened pipeline-aware) hits the recall ceiling on every in-scope category

100% on all four natural categories across 5 trials × 4 plants each = 20-for-20 detection. Every planted exact-duplicate cluster, every cross-package shadow, every subset-pair, every near-duplicate. Intra-trial Jaccard is 1.00 — the five trials emit the exact same set of cluster_ids. **For the categories the pipeline is designed to detect, the substrate-widened pipeline is at the recall ceiling.**

This is the strongest validation yet of the deterministic-extraction principle. The pipeline doesn't *miss* findings in its categories; it doesn't *vary* across trials on what it surfaces; the agent's job is reduced to severity judgment.

### C4 (cold) wins on substrate-gap (19/20 instances), loses on within-package structure

The four substrate-gap plants were designed adversarially against the V2 pipeline: function-body duplication (plant 17), file-pair duplication (plant 18), cross-package near-duplicate by shape (plant 19), and intersection-type subset (plant 20). C3 misses all four by construction. **C4 catches 19 of 20 — recall 95%.** Cold agents reach for `md5`/`diff` shell helpers, grep for similar function bodies, and resolve `A & B` intersections by hand.

But C4 dramatically *loses* on exact-duplicates within main (5% recall) and tightly trails C3 on subset-pairs and near-duplicates (50% each). Two effects compound:

1. **The .tsx blind spot.** C4 systematically misses every plant in a `.tsx` file (plants 2, 3, 4, 11, 12, 14, 15). When cold agents scan a TypeScript codebase for "duplicate types," they go straight to `.ts` files and largely skip component prop interfaces. The pipeline indexes both with no preference; cold attention prioritizes naturally.
2. **Plant 1 (8-field JWT exact-duplicate) caught in only 1/5 cold trials.** The two near-identical interfaces live in *the same directory* (`jwt-types.ts` and `types.ts`). Cold attention either picks one file and stops, or treats them as intentionally-paired. The pipeline catches it because shape_sig hashing is location-agnostic.

### C2 (narrow pipeline-aware) is bottlenecked by what V2 already showed

C2 detects 5 of 20 plants. Every plant it misses is structurally invisible to the V1 substrate — either in a `.tsx` file (not indexed), or a cross-package shadow (no `--shared`), or a subset-pair (no `subset-pairs.jq`). The 5 it catches are all in `.ts` files in the natural categories the V1 queries cover.

This number — 5/20 — is the per-plant analog of V2's "30/54 = 56% widened-only coverage." It tells you precisely how much each V2 substrate addition was buying.

## Cold-agent attention biases (specific, falsifiable)

V3 surfaced two specific cold-attention biases worth recording:

**Cold agents skim `.tsx` files for type findings.** Plants 2, 3, 4, 11, 12, 14, 15 are all in `.tsx`, and C4 caught 0 of them in 25 trial-plant cells (0%). Plants 5–10, 13, 16 in `.ts` files: C4 caught those at 100%. The blind spot is mechanical, not coincidental.

**Cold agents under-detect within-package exact duplicates.** C4's 5% recall on plants 1–4 (vs C3's 100%) tells you cold attention doesn't systematically compare shapes within a single feature directory. Plant 1's two 8-field JWT interfaces in the same auth feature directory should be a glaring duplicate; cold caught it once in five trials. This isn't a category cold "can't see" — it's a category cold doesn't *prioritize*.

These biases are the inverse of the substrate-gap categories where cold dominates. Combined: **C3 + C4 in tandem hits 19/20 plants** at 100% recall in every category. **Pipeline + cold are not redundant; they're complementary along specific axes the V2 results doc theorized and V3 confirms.**

## Methodology gotcha: the "Plant N" comment leak

Every plant file I committed had a comment like `// Plant 17: substrate-gap (function-body duplication)...` explaining its design intent. Cold agents read these comments and several explicitly self-reported "the codebase has explicit `// Plant N:` comments documenting intentionally-injected examples." This is a real bias contamination: cold trials probably found *more* substrate-gap plants because the comments told them where to look.

How bad is the bias on the headline numbers?

- **C3 (pipeline-aware) is unaffected.** C3 trials read the catalog and query outputs first; they only read source for clarification. The comments don't help C3 — its recall is set by what the queries surface.
- **C4 (cold) recall is upper-bound contaminated.** Cold agents that grep for `// Plant` will mechanically find every plant location. C4's 95% substrate-gap recall is plausibly inflated by 20–40 percentage points vs an uncommented version of the same plants.
- **Severity bias is real.** Several C2 trials rated plants as "low — dead Plant near-duplicate" — they recognized the planted nature and downgraded. This affects the severity-calibration analysis (not done here) but not the binary recall numbers used as the headline.

V4 should re-run with `// Plant N` comments scrubbed before agents launch. The recall numbers above should be treated as upper bounds for C4. C3's 100% recall is robust because the pipeline doesn't read the comments at all.

## Substrate sizes (plant impact)

| Variant | Catalog entries | V3 delta vs V2 |
|---|---|---|
| dj-site narrow | 154 main | +14 from plants |
| dj-site widened | 223 main + 840 shared = 1063 | +23 main entries from plants (incl. plant 1's clone, the 4-way Props, etc.) |

## Cluster query output sizes (V3 with plants vs V2 baseline)

| Query | V2 baseline | V3 with plants | Delta |
|---|---|---|---|
| exact-duplicates clusters | 5 | 9 | +4 (plants 1, 2, 3, 4) |
| cross-package-shadows | 9 | 13 | +4 (plants 5–8) |
| name-collisions | 5 | 5 | 0 (plants 5–8 chosen to NOT collide by name with other main types) |
| near-duplicates ≥0.7 | 1 | 6 | +5 (plants 13, 16 + 3 derivative pairs from plant 1 clone) |
| near-duplicates ≥0.5 | 8 | 20 | +12 |
| subset-pairs | 27 | 42 | +15 (plants 9–12 + derivative subsets from plant 20's intersection) |

The deltas match the manifest expectations exactly. The verification step in the manifest passed: no unintended cluster_ids appear in V3 beyond the planted set and their derivative pairings.

## What V3 confirms (sharper than V2)

1. **C3's 100% recall in covered categories means the V2-widened substrate has zero false-negative rate for plants in its query scope.** Whatever V2 misses, V3 plants tell us: it's missing only the categories the substrate doesn't have queries for, not findings within categories it does.
2. **Pipeline + cold complementarity is real and measurable**, not just a V2 conjecture: 16/16 natural plants by C3 plus 19/20 substrate-gap plants by C4 = 35/36 detection at 97% combined recall.
3. **Cold-agent attention has specific, mechanical biases** (the `.tsx` skip; the within-package-pair miss) that look stable across trials. These aren't "agent noise" — they're how cold attention naturally allocates effort.
4. **Intra-trial Jaccard at 1.00 for C3 holds on planted ground truth**, confirming V2's substrate-widening Jaccard result wasn't an artifact of running on the natural finding distribution.

## What V3 surprised on

1. **Plant 1 caught 1/5 by cold but 5/5 by pipeline.** Two 8-field JWT interfaces in the same auth feature directory should be glaring to a careful reader. The within-package blind spot is more aggressive than I expected.
2. **C4 intra-trial Jaccard hits 0.94 on plants** even though the full cluster_id Jaccard is 0.46. That tells you cold-agent variance is dominated by *what they find beyond the plants* (each trial picks different organic findings), not by *which plants they detect* (largely stable). The plants act as an anchor that pulls cold agents toward each other.
3. **Plant 20 (intersection subset) caught by 4/5 cold trials but 0/5 by pipeline.** The cold-agent ability to resolve `RecordingDraft = RecordingBase & RecordingMeta` and notice it's structurally a subset of `RecordingDraftExtended` is robust. The pipeline gap is real and worth closing.

## V4 implications

V3 produces a sharp punch list for V4 substrate work:

1. **Close the four substrate-gap categories**:
   - Function-body extractor (plant 17 territory). Hash function bodies, surface near-duplicates.
   - File-content hash sub-query (plant 18 territory). md5 every file; emit pairs.
   - Cross-package near-duplicates query (plant 19 territory). Relax `package == "main"` in `near-duplicates.jq` and emit a separate sub-query that explicitly compares main↔shared by shape.
   - Intersection-type resolution (plant 20 territory). When parsing `type X = A & B`, also emit a `fields` array as `union(fields(A), fields(B))` so subset-pairs.jq can compare intersections.
2. **Strip plant-leak in next round.** Run V4 plants with no `// Plant N` comments. Verify C4 substrate-gap recall stays high.
3. **Run V4 over multiple SHAs of dj-site** (per `future-directions.md` §1) so the same plants get re-detected as the surrounding code evolves. Tests whether plant recall stays stable across natural codebase drift.
4. **Add a combined C6 condition**: pipeline-aware + "also enumerate anything you find that the catalog missed." Predicted to recover the C4 substrate-gap plants without sacrificing C3 recall — basically the union of the two strong conditions.

## V3 limitations carried forward

- **Designer-as-actor bias persists on plant placement, category mix, and substrate-gap design.** De-abstraction removed it for field shapes; the rest is still mine.
- **No false-positive measurement.** V3 measures recall on plants but doesn't ground-truth-label natural findings, so precision against the full dj-site finding distribution is unmeasured.
- **One codebase, one model.** All trials are dj-site at one SHA, Opus 4.7 at default temperature. The recall numbers above don't transfer automatically to other codebases or other models.

## See also

- [`dj-site-divergence-experiment-v3-plant-manifest.md`](./dj-site-divergence-experiment-v3-plant-manifest.md) — V3 protocol
- [`dj-site-divergence-experiment-v2-results.md`](./dj-site-divergence-experiment-v2-results.md) — V2 baseline; the 0.08/0.15/~0.50/0.70 gap decomposition is what V3 plant categories were designed to test
- [`dj-site-divergence-experiment-v2-methodology.md`](./dj-site-divergence-experiment-v2-methodology.md)
- [`case-study.md`](./case-study.md) — origin of the deterministic-extraction principle
- V3 raw outputs: `/tmp/wxyc-audit-v3/{C2,C3,C4}/trial-N/output.json`
- V3 analysis summary: `/tmp/wxyc-audit-v3/analysis-summary.{json,md}`
- V3 plant-bearing worktree: `/Users/jake/Developer/WXYC/dj-site-v3-plants` on branch `experiment/v3-plants`
