# dj-site Divergence Experiment — V4 Results (Comments Scrubbed, No Git Access)

> Re-run of V3 with both contamination vectors from the V3 results doc closed: `// Plant N` comments stripped from every plant file, and the plant-bearing codebase served from a flat non-git directory (`/tmp/dj-site-v4-flat`) so `git status` / `git log` reveal nothing.
>
> Same 20 plants, same manifest. 15 trials (3 conditions × 5 trials), Opus 4.7. Analysis at `pipeline/analysis/v4-analysis.mjs`. Raw outputs at `/tmp/wxyc-audit-v4/`.

## What this run was for

V3 reported C4 substrate-gap recall at 95% and C3 intra-trial Jaccard at 1.00, but both numbers were upper bounds: agents could read `// Plant N: substrate-gap (function-body duplication)…` comments embedded in plant code, and could run `git status` in the worktree to see the full plant inventory. V4 removes both vectors. The point is to ground the V3 recall numbers against an uncontaminated baseline.

## Headline numbers

### Per-category recall

| Category | C2 narrow | C3 widened | C4 cold | Δ vs V3 (C3) | Δ vs V3 (C4) |
|---|---|---|---|---|---|
| exact-duplicates | 25% | 100% | 0% | — | −5pp |
| cross-package-shadows | 0% | **60%** | 100% | **−40pp** | — |
| subset-pairs | 0% | 100% | 20% | — | −30pp |
| near-duplicates | 50% | 100% | 10% | — | **−40pp** |
| substrate-gap | 0% | 0% | **50%** | — | **−45pp** |

### Intra-trial Jaccard

| Condition | Full cluster_id sets | Plant-only sets | V3 baseline (full / plants) |
|---|---|---|---|
| C2 | 1.00 ± 0.00 | 1.00 ± 0.00 | 1.00 / 1.00 |
| C3 | **0.89 ± 0.09** | **0.85 ± 0.12** | 1.00 / 1.00 |
| C4 | 0.43 ± 0.06 | 0.66 ± 0.13 | 0.46 / 0.94 |

## The two big results

### 1. C4 substrate-gap recall: 95% → 50% (the comment-leak bias)

The single largest V3→V4 shift. Per-plant:

| Plant | V3 C4 | V4 C4 | Δ |
|---|---|---|---|
| 17 (function-body dup) | 5/5 (100%) | 2/5 (40%) | −60pp |
| 18 (file-pair dup) | 5/5 (100%) | 4/5 (80%) | −20pp |
| 19 (cross-pkg near-dup) | 5/5 (100%) | **0/5 (0%)** | **−100pp** |
| 20 (intersection subset) | 4/5 (80%) | 4/5 (80%) | — |

Plant 19's collapse from 100% to 0% is the most diagnostic. Without the `// Plant 19: substrate-gap (cross-package near-duplicate)…` comment pointing the agent at the exact pattern, no cold trial thinks to compare `main:ScheduleShiftEntry` against `shared:AddScheduleShiftRequest` by shape across packages. Cold attention finds *named* shadows (plants 5–8 still 100%) but doesn't grep for *shape-equivalent renames*.

Plant 17 drops from 100% to 40% similarly — without the comment, cold agents don't think to diff function bodies; they only md5-diff entire files (plant 18 holds at 80%). Plant 20 holds at 80% because intersection-type resolution is a natural read-the-code task and doesn't require the comment as a cue.

**The cleaned numbers reframe V3's "substrate-gap" finding**: cold agents reliably catch *whole-file duplicates* and *intersection types* without help, but miss *function-body* and *cross-package-shape* gaps without a comment cue. The V3 95% number was almost entirely the comments doing the work for those two categories.

### 2. C3 cross-package-shadows recall: 100% → 60% (the "score every row" batching variance)

Trials 1 and 5 emitted only **3** cross-package-shadows findings each (instead of the 13 in the substrate). They batched all the Flowsheet-family shadows + Album/BinEntry/DiscogsArtistRef/ShowPeek into 3 grouped findings rather than row-per-shadow. Trials 2, 3, 4 emitted 13 — one per row. Per-plant recall on plants 5–8 lands at 3/5 (60%) for each because trials 1 and 5 dropped them.

This isn't a substrate failure — the queries surface all 13 shadows; the catalog records them all. It's an agent prompt-following variance: "Score every shadow in cross-package-shadows.txt" is followed by 3/5 agents but interpreted by 2/5 as "Score every cluster pattern in the file, grouped."

V3 didn't show this batching because the `// Plant 5: cross-package-shadow of @wxyc/shared/Album…` comments were strong individual cues per plant, holding each trial to row-per-plant emission. Once the comments are gone, two trials revert to a more natural "summarize the family" behavior.

This is a real V4 finding worth recording for V5: **prompt-following variance is real and the comment cues were suppressing it.** Either the prompt needs sharper enumeration language ("emit one finding row per line in the .txt file") or the substrate should emit cluster_ids the agent references by ID rather than re-derives.

## Per-plant detail

| # | Category | C2 | C3 | C4 | Notes |
|---|---|---|---|---|---|
| 1 | exact-dup | 5/5 | 5/5 | 0/5 | Cold misses two adjacent JWT-shape duplicates; pipeline catches deterministically |
| 2 | exact-dup (tsx) | 0/5 | 5/5 | 0/5 | `.tsx` blind spot persists |
| 3 | exact-dup 4-way (tsx) | 0/5 | 5/5 | 0/5 | `.tsx` blind spot |
| 4 | exact-dup (tsx) | 0/5 | 5/5 | 0/5 | `.tsx` blind spot |
| 5 | shadow Album | 0/5 | 3/5 | 5/5 | C3 batching variance |
| 6 | shadow BinEntry | 0/5 | 3/5 | 5/5 | C3 batching variance |
| 7 | shadow DiscogsArtistRef | 0/5 | 3/5 | 5/5 | C3 batching variance |
| 8 | shadow ShowPeek | 0/5 | 3/5 | 5/5 | C3 batching variance |
| 9 | subset AuthJwtBasicClaims⊂BetterAuthJwtPayload | 0/5 | 5/5 | 1/5 | Cold sometimes catches via direct read |
| 10 | subset ExperienceConfigPreview⊂ExperienceConfig | 0/5 | 5/5 | 3/5 | Cold catches 60% — easier to spot |
| 11 | subset AlbumCardCompactProps⊂AlbumCardProps (tsx) | 0/5 | 5/5 | 0/5 | `.tsx` blind spot |
| 12 | subset BinColorPreview⊂BinColorSet (tsx) | 0/5 | 5/5 | 0/5 | `.tsx` blind spot |
| 13 | near-dup AuthSessionJwtClaims rename | 5/5 | 5/5 | 2/5 | Cold catches 40% (down from 100% in V3 — comments were the cue) |
| 14 | near-dup PlaylistFilterRow (tsx) | 0/5 | 5/5 | 0/5 | `.tsx` blind spot |
| 15 | near-dup BarAudio (tsx) | 0/5 | 5/5 | 0/5 | `.tsx` blind spot |
| 16 | near-dup SearchCatalogQueryParamsExtended | 5/5 | 5/5 | 0/5 | Cold MISSED 5/5 in V4 (was 5/5 in V3 with comments) |
| 17 | function-body dup | 0/5 | 0/5 | 2/5 | Was 5/5 in V3 — comment dependence |
| 18 | file-pair dup | 0/5 | 0/5 | 4/5 | Robust without comment |
| 19 | cross-pkg near-dup | 0/5 | 0/5 | 0/5 | **Was 5/5 in V3 — total comment dependence** |
| 20 | intersection subset | 0/5 | 0/5 | 4/5 | Robust without comment |

## C3 + C4 combined recall (the V3 "complementary work" claim, retested)

V3 reported 35/36 (97%) plant-detections combined across C3 and C4. V4's numbers are tighter:

- C3 catches 16/20 natural plants at 5/5, 0/4 substrate-gap.
- C4 catches plants 5–8, 10, 13, 17, 18, 20 in at least 2/5 trials. The plants C4 catches that C3 misses (i.e., the substrate-gap set) drop from 4/4 in V3 to 3/4 in V4 (plants 18, 20, partial 17; plant 19 is gone).

Combined C3 ∪ C4 coverage at "any-trial-saw-it" granularity: **17/20 plants** (85%). At "majority-of-trials-saw-it" granularity (≥3/5): **16/20 plants** (80%) — C3 alone matches this.

V3's headline of "97% combined recall" was inflated by the comment leak. V4 says: **C3 alone covers about as much as C3 + C4 once you remove the comment bias.** The marginal value of cold for substrate-gap is plant 18 (file-pair, 80%) and plant 20 (intersection, 80%). Plant 17 (function-body) and plant 19 (cross-pkg) collapse without comments, so they're not reliably covered by cold either.

The case for "combine pipeline + cold rather than treat them as alternatives" is weaker than V3 indicated. The fairer V4 framing: **substrate-widening is the dominant lever; cold-agent inspection provides a small, narrow safety net for whole-file dup and intersection-resolution categories.**

## Why C3 intra-Jaccard dropped from 1.00 → 0.85

V3 had 1.00 intra-trial Jaccard on plants because all 5 trials emitted exactly 54 findings each. V4's C3 has 71/81/87/81/71 findings — trials 1 and 5 batched the cross-package-shadows into fewer rows. The plant-cluster-recall coverage of plants 5–8 is the only place this batching matters; in raw cluster_id terms, trials 1 and 5 have 10 fewer rows than the others.

Interpretation: V3's perfect Jaccard was partially a comment-cue artifact. The plant comments held each trial to the same emission pattern. Without them, 2/5 agents revert to "summarize the family" style. Real intra-trial Jaccard for C3 on a clean codebase is ~0.85, not 1.00.

## Robustness of cold attention biases (V3 → V4)

V3 identified two cold-attention biases: the `.tsx` blind spot and the within-package exact-duplicate miss. Both persist in V4:

- **`.tsx` blind spot**: V3 had 0/35 cells across `.tsx` plants. V4 has 0/35. Identical mechanical pattern.
- **Within-package exact-duplicate miss**: V3 plant 1 caught 1/5; V4 plant 1 caught 0/5. Slightly worse. The two adjacent 8-field JWT interfaces are even less visible to cold without the plant comment to pull attention there.

These aren't agent noise — they're genuinely how cold attention allocates effort. V3's findings on this front are robust; V4 confirms them.

## What V4 newly establishes

1. **Comment cues were doing significant work in V3.** C4 substrate-gap recall halved when comments were scrubbed; plants 17 and 19 collapsed entirely. V4 numbers are closer to the realistic recall for a green-field audit.
2. **Pipeline-aware agents have a "score every row vs summarize the family" prompt-interpretation split**, suppressed by comment cues. Either the substrate emits canonical cluster_ids (the V2 results doc's tier-1 recommendation) or the prompt needs to be sharper about row-per-finding emission.
3. **Cold agents reliably catch byte-identical-file duplicates and intersection-subset relationships** without help. Cold reliably MISSES function-body duplicates and cross-package near-duplicates by shape without help. The substrate-gap categories have different intrinsic difficulty levels.
4. **The "C3 alone ≈ C3+C4 union" finding** suggests V5/V6 substrate work has higher leverage than adding a combined condition. Pipeline-widening to close the file/function/intersection/cross-pkg-shape gaps is the right path.

## What V4 doesn't address

- **C3 batching variance is real but un-mitigated.** V5 should either canonicalize cluster_ids in the substrate or sharpen prompt enumeration language.
- **No false-positive measurement.** Same as V3.
- **One model, one codebase, one SHA.** Same as V3.
- **The `.tsx` blind spot is documented but not closed.** Could be a V5 prompt addition ("explicitly include `.tsx` files in your scan") for C4.

## V5 punch list

1. **Close the 4 substrate-gap categories (carried from V3):**
   - Function-body extractor (plant 17 — V4 cold caught only 40%).
   - File-content hash sub-query (plant 18 — V4 cold caught 80%; pipeline closes the last 20%).
   - Cross-package-shape near-duplicates query (plant 19 — V4 cold caught 0% without comments; substrate is the only path).
   - Intersection-type fields resolution (plant 20 — V4 cold caught 80%; pipeline closes the last 20%).
2. **Substrate-emitted cluster_ids** (V2 tier-1 recommendation). Without this, V4 shows agents interpret "enumerate" inconsistently.
3. **Optional: `.tsx`-explicit cold prompt.** For comparison. Predict: cold recall on `.tsx` plants partially recovers but not to pipeline levels.
4. **Optional: re-run with a non-Claude model on cold-agent role.** Tests whether the `.tsx` blind spot is Claude-specific or general.

## See also

- [`dj-site-divergence-experiment-v3-plant-manifest.md`](./dj-site-divergence-experiment-v3-plant-manifest.md) — plant manifest (same plants, scrubbed comments in V4)
- [`dj-site-divergence-experiment-v3-results.md`](./dj-site-divergence-experiment-v3-results.md) — V3 baseline (comment-contaminated)
- [`dj-site-divergence-experiment-v2-results.md`](./dj-site-divergence-experiment-v2-results.md) — V2 (no plants; the prediction setup)
- V4 raw outputs: `/tmp/wxyc-audit-v4/{C2,C3,C4}/trial-N/output.json`
- V4 analysis summary: `/tmp/wxyc-audit-v4/analysis-summary.{json,md}`
- V4 flat plant-bearing snapshot: `/tmp/dj-site-v4-flat/` (no `.git`)
