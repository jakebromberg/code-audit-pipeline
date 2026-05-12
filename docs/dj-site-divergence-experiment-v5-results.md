# V5 Plant-Recall Experiment — Results

## Question

After landing the four V5 substrate-gap closures (function-body extraction, file-content hashing, cross-package shape near-duplicates, intersection-type field resolution), does the pipeline now recall the V4 substrate-gap plants (17–20) that V4-C3 missed half the time?

## Setup

Same dj-site plant tree as V4 (`/tmp/dj-site-v4-flat` — flat non-git copy with `// Plant N: …` comments stripped). Same 20 plants. Single condition (`C3-v5`), 3 trials. Pipeline-aware widened agent prompt, expanded to enumerate clusters from 9 query outputs:

| Query | Lines | New in V5? |
|---|---|---|
| `exact-duplicates.txt` | 31 | no |
| `name-collisions.txt` | 17 | no |
| `cross-package-shadows.txt` | 13 | no |
| `near-duplicates.txt` (Jaccard ≥ 0.7) | 24 | no |
| `near-duplicates-0.5.txt` | 78 | no |
| `subset-pairs.txt` | 324 | (intersection-resolved entries are new) |
| `function-duplicates.txt` | 225 | **yes** |
| `file-duplicates.txt` | 24 | **yes** |
| `cross-package-shape-near-duplicates.txt` | 48 | **yes** |

Each trial scored every cluster row, emitting a `{cluster_id, severity, rationale}` finding. Prompt: [`/tmp/wxyc-audit-v5/prompt_C3_v5.md`](../../../../tmp/wxyc-audit-v5/prompt_C3_v5.md). Analyzer: [`/tmp/wxyc-audit-v5/v5-analysis.mjs`](../../../../tmp/wxyc-audit-v5/v5-analysis.mjs).

## Per-plant recall

All four V4-substrate-gap plants now caught by every trial.

| # | Category | V4 C3 (5 trials) | **V5 C3 (3 trials)** |
|---|---|---|---|
| 1–4 | exact-duplicates | 4/4 plants @ 100% | 4/4 plants @ 100% |
| 5–8 | cross-package-shadows | 4/4 plants @ 100% | 4/4 plants @ 100% |
| 9–12 | subset-pairs | 4/4 plants @ 100% | 4/4 plants @ 100% |
| 13–16 | near-duplicates | 4/4 plants @ 100% | 4/4 plants @ 100% |
| 17 | substrate-gap (function-body) | 1/5 trials @ 20% | **3/3 trials @ 100%** |
| 18 | substrate-gap (file-content) | 5/5 trials @ 100% (lucky direct read) | 3/3 trials @ 100% |
| 19 | substrate-gap (cross-package near-dup) | 4/5 trials @ 80% | 3/3 trials @ 100% |
| 20 | substrate-gap (intersection-subset) | 0/5 trials @ 0% | **3/3 trials @ 100%** |
| | **substrate-gap category recall** | **50%** | **100%** |

V4's most extreme misses — plant 17 (function-body Jaccard) and plant 20 (intersection-subset) — both close cleanly because the V5 substrate now emits them as ordinary rows in its query outputs.

## Intra-trial agreement

Striking convergence on the extraction layer; judgment variance preserved on the synthesis layer.

| Metric | V4 C3 (5 trials) | **V5 C3 (3 trials)** |
|---|---|---|
| Findings per trial | 35–69 | 171, 171, 171 |
| Intra-trial Jaccard, full cluster_id sets | 0.85 | **1.00** |
| Intra-trial Jaccard, plant-only sets | 1.00 (5 trials all agreed once you constrain to plants) | **1.00** |
| Identical cluster_id sets across trials? | no (batching variance — e.g., trials 1 and 5 grouped 13 cross-package-shadow rows into 3 batched findings) | **yes** (all three trials emit identical 171-element cluster_id set, MD5-equal) |
| Identical severity assignments across trials? | n/a | **no** (3 distinct severity MD5s; ~6 high/medium/low boundary calls differ per trial-pair) |

The byte-identical cluster_id outputs are not contamination — trials wrote to separate `/tmp/wxyc-audit-v5/C3-v5/trial-N/` directories with full temporal overlap (~300s each, no chance to read each other's outputs). It is substrate completeness: the prompt's "score every row" instruction plus the new substrate's structural emission of plants 17–20 leaves no judgment for the agent on *what to score*. Severity divergence stays in the layer where judgment legitimately lives.

## Comparison with V4 substrate-gap behaviour

V4 had measured the substrate-gap plants as an axis where the cold (C4) agent had access to the source tree and could grep for byte-level duplicates and shape-near-duplicates that the V2 substrate did not surface. After scrubbing `// Plant N: …` comments in V4, C4 substrate-gap recall fell to 50% (cold agents weren't grepping carefully enough). Pipeline-aware C3 stayed near 0% because the substrate had no surfaces for those plants. The V5 gap-closures move both ends — the pipeline-aware agent now reads structural findings for these plants from the query outputs, no source-reading required.

## What stays as future work

- Function-near-duplicate cluster_id collapse: the sorted-pair format `function-near-duplicates:<a>+<b>` collapses three RTK-Query `onQueryStarted+onQueryStarted` rows (same-name pairs across 3 pairwise comparisons) into a single cluster_id. Trial 2 flagged this explicitly. Substrate-emitted cluster_ids (V5 substrate issue #5) would solve this by giving each row its own deterministic ID.
- Severity convergence sits in the agent-judgment layer where some variance is appropriate, but the 6-ish boundary disagreements per trial pair suggest a tighter severity rubric might be worth iterating on. Out of scope for V5.
- 3-trial sample is small. The cluster_id convergence is striking enough (MD5-equal across three independent runs) that a larger run is more confirmation than discovery, but a 5–10 trial follow-up would tighten the band on the substrate-gap-recall delta.

## Conclusion

V5 substrate-gap closures land their measurable goal. Substrate-gap recall: V4-C3 50% → V5-C3 100%. Pipeline-aware intra-trial Jaccard: V4-C3 0.85 → V5-C3 1.00. The new substrate elements (function-catalog, file-hashes, cross-package shape near-duplicates, intersection-type field resolution) collapsed the four V4-untouchable plants into ordinary query rows, and the prompt-following layer's "score every row" instruction does the rest. The only remaining variance lives in agent severity judgments — the layer where variance belongs.
