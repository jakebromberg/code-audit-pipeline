# V7 plant-mix calibration — wxyc-ios-64 PR history

Phase A.1 of the [V7 implementation plan](../../plans/v7-refactor-recommendation-implementation-plan.md). Mitigates [methodology §13 risk #1](../../docs/refactor-recommendation-experiment-methodology.md#risks) (designer-as-actor bias on category mix) by sampling the wxyc-ios-64 PR history for refactor PRs and classifying them by V7 plant category, then recommending a per-category plant allocation within the 25-plant MVP budget.

## Sampling procedure

Reproducible query (run from any clone with `gh` authenticated to the WXYC org):

```bash
gh pr list --repo WXYC/wxyc-ios-64 --state merged --limit 300 \
  --search 'refactor OR extract OR consolidate OR lift OR generic OR "default impl"' \
  --json number,title,mergedAt,additions,deletions
```

The repo has **132 merged PRs total** as of the sampling date (2026-05-12). The keyword query returned **15 PR-title matches** spanning Nov 2017 to May 2026. A separate broader sweep with terms covering Cat. 2–5 idioms (`unify`, `deduplicate`, `DRY`, `pull up`, `move to`, `shared protocol`, `conformance`, `associated type`, `composition`) returned 3 additional candidates — all on inspection feature-shaped rather than refactor-shaped (auth migration, build-fix, error-reporter integration). The 15-PR set below is the actionable sample.

## Per-PR classification

PRs not mapping cleanly to one of the 5 MVP categories (Cats. 1–5) are marked "out of scope" with a one-line rationale.

| PR | Date | Lines | Title | V7 category |
|---|---|---|---|---|
| #181 | 2026-04-05 | +22 / -3 | Extract detail section header font into shared WXUI constant | **Cat. 1** extract-to-common |
| #185 | 2026-04-05 | +245 / -41 | Extract timedOperation utility for network service layers | **Cat. 1** |
| #187 | 2026-04-05 | +159 / -49 | Extract shared LinkButtonLabel from StreamingButton and ExternalLinkButton | **Cat. 1** |
| #189 | 2026-04-05 | +89 / -16 | Extract HTTP status validation into shared extension | **Cat. 1** (extension-shaped, but the action is extract-to-common — V7's Cat. 1 absorbs the extension-target sub-pattern; Cat. 6 extension-consolidation is dropped in MVP per §8) |
| #191 | 2026-04-05 | +477 / -59 | Extract generic cachedFetch utility | **Cat. 1** + **Cat. 5** (extraction + generic parameterization — primary category is the extract since that's the action verb in the title and the bulk of the diff; the "generic" is a secondary modifier on the extracted symbol) |
| #196 | 2026-04-05 | +385 / -632 | Extract shared test utilities from duplicated mock boilerplate | **Cat. 1** |
| #252 | 2026-05-08 | +13 / -124 | Trim cross-target overlap between CacheCoordinator and ArtworkService cache tests | **Cat. 1** (cross-target deduplication; net negative line delta is the consolidation signature) |
| #7 | 2017-11-14 | +476 / -2145 | Refactor mega view controller | **Out of scope** (large architectural rewrite; no single V7 category captures the change) |
| #35 | 2017-11-28 | +247 / -219 | Default art in lockscreen looks bad | **Out of scope** (UI bug fix; title matched "Default" as a noun, not Cat. 3 default-impl) |
| #56 | 2019-03-13 | +2090 / -574 | Adding playlist support. | **Out of scope** (feature work; title matched "support" through fuzzy search) |
| #153 | 2026-03-10 | +94 / -396 | Fix AnalyticsMacros build failure blocking CI | **Out of scope** (build fix) |
| #198 | 2026-04-09 | +552 / -41 | Adaptive NavigationSplitView layout for iPad and Mac | **Out of scope** (UI feature) |
| #213 | 2026-04-22 | +617 / -29 | Switch anonymous auth from session tokens to JWTs | **Out of scope** (auth migration) |
| #219 | 2026-04-23 | +236 / -12 | Consume server-provided bio tokens instead of client-side parsing | **Out of scope** (feature replacement, not refactor) |
| #256 | 2026-05-09 | +39 / -1 | Record debug state snapshot on PlayWXYCIntent test timeout | **Out of scope** (test diagnostics) |

## Empirical distribution

| Category | Count | % of refactor PRs (n=7) |
|---|---|---|
| Cat. 1 extract-to-common | 7 | 100% |
| Cat. 2 protocol inheritance | 0 | 0% |
| Cat. 3 default implementation | 0 | 0% |
| Cat. 4 PAT introduction | 0 | 0% |
| Cat. 5 generic parameterization | 0 (counting #191 primarily as Cat. 1; would be ≤1 if secondary-category votes counted) | 0–14% |

## Sample-size caveats

The signal is **directionally informative but statistically thin**:

1. **n=7 clean refactor PRs** out of 132 total merged. The bulk of wxyc-ios-64's PR history is feature work, bug fixes, and infrastructure — not refactoring. Reweighting plant allocation against a 7-PR sample over-interprets.
2. **Title-keyword selection is biased toward Cat. 1.** "Extract" is the natural English verb for extract-to-common; the other categories don't have catchy title keywords ("introduce a PAT" or "lift default impl" don't appear in commit-title vernacular). The methodology §13 risk 1 itself flagged that PR-title classification is a coarse signal. A more rigorous calibration would diff-grep for structural patterns (e.g., new `protocol X: Y` declarations replacing prior parallel protocols), but that's V8+ instrumentation, not a Phase A.1 deliverable.
3. **No Cat. 2/3/4/5 PRs landed.** Either wxyc-ios-64's authors don't reach for those refactors often, or they reach for them without title-flagging. Both are plausible: Swift's protocol-with-default-impl idiom is so common that "introduce a default impl" rarely gets called out as the PR's headline action. The natural-findings the V6 substrate surfaced (`PlayerState`/`PlaybackState` parallelism, `DebugMetricsProvider` cross-package duplication, `StreamingService`/`MusicServiceIdentifier` parallel enums — see [V6 results' conclusion](../../docs/wxyc-ios-64-experiment-results.md#conclusion)) all suggest Cat. 2/3 opportunities *exist* in the codebase even if no PR has been merged to address them.

## Recommended plant allocation

**Keep the uniform 5-per-category allocation** for the MVP plant set.

Rationale: a 100%-Cat.1 empirical distribution would suggest reweighting to 25-0-0-0-0, but the sample is too small (n=7) and too biased (Cat. 1 keyword-favored) to support that. Plus the V7 experiment's *purpose* is to test whether the substrate-plus-agent system can surface and recommend across the category taxonomy, not to mirror the historical distribution. A heavily-weighted Cat. 1 plant set would leave Cats. 2–5 effectively unvalidated.

The Cat. 1 dominance in the sample IS worth recording as a finding for the V7 results writeup:

- Real-world Cat. 1 PRs in wxyc-ios-64 (n=7) provide an ecological-validity baseline against the planted Cat. 1 cluster signals. After Phase D runs, compare per-PR-diff substrate signals (would the substrate have surfaced #191's `cachedFetch` extraction as an exact-duplicates or cross-package-shape-near-duplicates cluster *before* it was extracted?) against the planted Cat. 1 cluster signals. If natural and planted Cat. 1 signals are structurally similar, that's positive evidence for substrate generalization.
- Cats. 2/3/4/5 plant recall numbers in Phase E should be reported with the caveat that those categories have no observed wxyc-ios-64 PR-history baseline. Recall percentages on those categories indicate substrate-plus-agent capability for hypothetical refactor opportunities, not historical drift toward them.

## What I would do differently in V8 calibration

The PR-title approach is the cheapest calibration that could possibly work. If V7 results justify a V8 round with better mix-calibration:

- **Diff-grep over each merged PR's changes.** Identify structural signatures (new `protocol B: A` inheritance, new `extension P { func foo() { ... } }` default-impl, new `associatedtype X` PAT introduction) automatically. Cost: one-time substrate-aware diff classifier, ~200 lines.
- **Sample from in-flight refactor planning, not just merged PRs.** Issues and Slack threads tagged "refactor" or "tech debt" might surface Cat. 2/3/4/5 candidates that haven't reached PR yet — those represent the substrate's potential future audience.
- **Cross-codebase calibration.** If V8 ports to a second iOS or Swift codebase, sample its PR history too — the per-category mix is plausibly project-specific (a UI-heavy codebase might over-weight Cat. 1; a typed-collection-heavy library might over-weight Cat. 5).

## See also

- [V7 implementation plan §2.1](../../plans/v7-refactor-recommendation-implementation-plan.md) — task spec
- [V7 methodology §13 risk #1](../../docs/refactor-recommendation-experiment-methodology.md#risks) — the bias this calibration mitigates
- [V7 methodology §5.1–§5.5](../../docs/refactor-recommendation-experiment-methodology.md#plant-design) — the 5 MVP plant categories
- [V6 results conclusion](../../docs/wxyc-ios-64-experiment-results.md#conclusion) — natural-finding examples that suggest Cat. 2/3 opportunities exist beyond the title-keyword sample
- Issue: jakebromberg/code-audit-pipeline#18
- [`experiments/v7-refactor-recommendation/glossary.md`](glossary.md) — shared V7 vocabulary (S1/S2, substrate, plants, metrics, all 13 auto-scorer match labels, binding rules, rounds/phases, code refs, PR/issue index).
