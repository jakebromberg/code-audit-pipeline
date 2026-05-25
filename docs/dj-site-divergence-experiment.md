# dj-site Experiment: Pipeline-Aware vs Cold-Agent Divergence

> A second TypeScript data point. Four agent runs, two with the pipeline as substrate and two without, on the WXYC dj-site frontend. The interesting finding is not "the pipeline is faster" — that was already known. The interesting finding is *how* the two groups disagree, and what that says about where the deterministic-extraction line should sit.
>
> **Successor:** [`dj-site-divergence-experiment-v2-methodology.md`](./dj-site-divergence-experiment-v2-methodology.md) is the V2 protocol that addresses the confounds and underpowered comparisons identified in this run.

## Why this experiment

The [case study](./case-study.md) established the principle: deterministic tools enumerate, agents judge. The Swift and Python feasibility studies extended the principle to other languages and converged on a "Path 2: parse + recognize contracts" middle ground. Before adding a second-language extractor, we wanted a second TypeScript data point: does the principle hold on a *frontend* codebase that the reference extractor was not designed against?

The case study's audit subject was a TypeScript Express monorepo — backend code, heavy on Drizzle tables, Zod schemas, and Express handlers. dj-site is something else: a Next.js 16 React frontend with feature-organized type modules, RTK Query, no Drizzle, no Zod, and ~95% `.tsx` files that the current extractor doesn't index. It's a stress test of how well the pipeline generalizes when its catalog is narrower than the codebase.

The experiment also gave us a way to ask the harder question: **when both an agent with the pipeline output and an agent without it analyze the same codebase, how much do their findings actually overlap?** The case study argued that the pipeline lets agents work small, focused judgment over reproducible structured rows. If that's right, pipeline-aware agents should produce findings that are (a) more reproducible run-to-run and (b) at least as good as cold-agent findings, at a lower cost. The dj-site experiment was designed to test that claim directly.

## Setup

Four general-purpose agents launched in parallel against the same codebase (`/Users/jake/Developer/WXYC/dj-site`), with identical output skeletons and anti-padding instructions. The only difference between pairs:

- **Experiment 1 (pipeline-aware), runs A and B.** Given pre-computed pipeline outputs at `/tmp/wxyc-audit/dj-site/`: `catalog.json` (140 entries), `exact-duplicates.txt` (2 clusters, 4 declarations), `near-duplicates-0.5.txt` (2 pairs), and three empty query files (`name-collisions.txt`, `near-duplicates.txt` at 0.7 Jaccard, `cross-package-shadows.txt` — because no `--shared` was passed). Method instruction: "Treat the pipeline as your enumeration substrate — do not re-walk the file tree or re-catalog by hand."
- **Experiment 2 (cold), runs A and B.** No pre-extracted catalog. Same task, same output template. "Catalog the types yourself."

Both groups had access to the full dj-site repo and were free to read any source file. Both were given the same dotdir/dist skip-list so scan effort wasn't the comparison variable. Identical output skeleton: `# title / ## Summary / ## Finding N` with severity/files/issue/recommendation, ending in a `## Methodology Note`.

Raw outputs are at `/tmp/wxyc-audit/dj-site/results/{exp1a,exp1b,exp2a,exp2b}.md`.

## Cost & shape, raw

| | Exp 1A | Exp 1B | Exp 2A | Exp 2B |
|---|---|---|---|---|
| Tool uses | 86 | 58 | 153 | 113 |
| Tokens | 122,993 | 101,631 | 200,541 | 202,734 |
| Wall-clock | 7m 06s | 4m 41s | 15m 04s | 12m 53s |
| Findings emitted | 8 | 6 | 11 | 14 |
| HIGH-severity findings | 1 | 0 (highest = medium) | 2 | 4 |

Cold agents cost roughly **2× the tokens, 2–3× the wall-clock, 2× the tool calls** of pipeline-aware agents, and emitted **50–130% more findings**. The pipeline-aware agents' HIGH-severity bar was also calibrated lower (1B's top severity was "medium"), which is itself worth noting — see "Calibration drift" below.

## Findings overlap, qualitatively

Across all four runs, ~20+ distinct issues were surfaced. Categorizing them by who saw what:

### All four agreed (3 findings)

| Issue | Severity |
|---|---|
| `Account.userName` vs `username` everywhere else — same string, different casing, already silently being compared in `RosterTable.tsx:228` (`dj.userName === user.username`) | medium |
| `WXYCRole` and role-mapping helpers locally re-declare exports from `@wxyc/shared/auth-client/auth` (parity test pins them) | high (1A, 2B) / implicit (1B, 2A) |
| Three legacy `DJ*` request/response types in `authentication/types.ts` form an exact + near-duplicate cluster | medium / low / dead-code (depending on run) |

### Both cold agents agreed, neither pipeline-aware did (5 findings)

| Issue | Severity |
|---|---|
| Local `FlowsheetEntry` union + 5 type guards duplicate `@wxyc/shared/dtos` exports verbatim; `FlowsheetSongEntry` has drifted on `rotation` vs `rotation_bin` | high |
| `JSONDates<T>` and `AlbumSearchResultJSON` are **no-op adapters**: the shared package already declares the underlying date fields as `string`, not `Date` | high (2A) / low (2B) |
| Four `as Record<string, unknown>` casts in `convertToAlbumEntry` are vestigial defenses; the fields are actually typed on the shared `AlbumSearchResult` now | low |
| `betterAuthSessionToAuthenticationData` and its async sibling are ~40-line byte-near-identical blocks | medium |
| Orphan `types.test.ts` at project root imports `./types` (doesn't exist); vitest picks it up and fails | medium |

### Both pipeline-aware agents agreed, neither cold did (1 finding)

| Issue | Severity |
|---|---|
| `TrackDetailsResult` is literally `Omit<SuggestTrackResult, "track_title">` — declared as two independent objects | low |

### Unique findings (one agent only, all legitimate)

- **1A:** `SearchQuery` in `filterBySearchTerms.ts` is an undeclared subset of `FlowsheetQuery`; wire-format/frontend-format casing split is consistent and intentional (info).
- **1B:** Explicitly identifies four of the duplicate DJ-types as **dead code** — never imported anywhere; zombie types from before the better-auth migration. Made the dup finding much more actionable.
- **2A:** `binSlice` is defined and tested but **never registered** in `combineSlices`; tracklist shape declared in three places; two `requireAuth` functions with different signatures and failure modes (envelope vs redirect).
- **2B:** `FlowsheetV2PaginatedResponseJSON.total_pages` is snake_case but the shared schema uses `totalPages` (one consumer is wrong about the wire); `OnAirDJ.id: string` (dj-site) vs `number` (shared) contract bug worth filing against shared; `FlowsheetSubmissionParams`/`UpdateRequestBody` drifted from shared; `Genre`/`Format` unions re-declared instead of imported; `getUserRoleInOrganization` server/client duplicate; `convertV2Entry` has four near-identical case branches; byte-identical orphan `app/StoreProvider.tsx`.

None of the unique findings look like false positives on inspection.

## Divergence within each group

The user's question was specifically about within-group divergence (1A vs 1B, 2A vs 2B). Computing rough Jaccard similarity on de-duplicated findings:

| Group | Run A | Run B | Overlap | Jaccard |
|---|---|---|---|---|
| Pipeline-aware (1A, 1B) | 8 | 6 | 4 | 0.40 |
| Cold (2A, 2B) | 11 | 14 | 7 | 0.39 |

**The within-group divergence rate is roughly identical (~40% Jaccard) across both experiments.** This was unexpected. The case study's hypothesis was that pipeline-aware agents would be *more* reproducible run-to-run because they're operating on a deterministic substrate. Instead what we see is that they diverge on roughly the same proportion of findings — the divergence just happens at a different scale.

The *qualitative* divergence is, however, materially different:

- **1A vs 1B disagreement is about emphasis.** Both find the same authentication-file cluster; 1A separates `WXYCRole` reimplementation into its own HIGH finding, while 1B folds it into the broader "dead duplicate DJ types" finding and highlights that four of them are unreferenced zombies. 1A is more taxonomic ("here are the kinds of duplication"), 1B is more pragmatic ("here's what you can delete tomorrow"). Both are correct readings of the same evidence.
- **2A vs 2B disagreement is about *which* shared-package shadows to surface.** Both go deep into `node_modules/@wxyc/shared/dist/*.d.ts` and find that dj-site reimplements significant parts of the shared package. But 2A surfaces the FlowsheetEntry guards, JSONDates, and AlbumSearchResult-casts cluster, and finds dj-site-side dead code (binSlice, requireAuth); 2B surfaces the same FlowsheetEntry shadow plus four more specific shadows (PaginatedResponse, OnAirDJ, FlowsheetSubmissionParams, Genre/Format) and a server/client function-pair duplication. They agree on the *pattern* (dj-site treats `@wxyc/shared` as optional reference, not as the contract) but disagree on which instances to enumerate. Recall is the variable.

## Where the pipeline-aware agents *stayed inside the line* — and what they missed

Both pipeline-aware agents did the disciplined thing: they read the catalog and queries, picked specific candidates to investigate, confirmed via source reads, and called out the gaps in the pipeline output explicitly. Both flagged the same four gaps:

1. **No `.tsx` files indexed.** dj-site has ~2478 TS/TSX files; the extractor indexed 123 `.ts` files. Component prop types, inline `useState<T>` types, and standalone widget-prop exports are invisible. (Caught by 1A's grep of `NowPlayingWidgetProps`.)
2. **No `--shared` was passed.** This is the single most consequential omission. The cross-package-shadows query was empty, but the cold agents proved that dj-site's most important structural problems are exactly cross-package shadows.
3. **Inline object literals collapse to one field.** `BetterAuthSession.user` is a 25-field inline literal that the extractor captures as a single field whose `type_text` is the stringified literal. Catalog can't Jaccard it against `User`, which is the actual duplication.
4. **No "strict subset" detector.** Jaccard treats `A ⊂ B` as low similarity if A is much smaller than B. `SearchQuery ⊂ FlowsheetQuery` and `TrackDetailsResult ⊂ SuggestTrackResult` get missed.

The discipline that the pipeline-aware agents showed — staying inside the line and treating gaps as gaps rather than reaching for the source code — is exactly what the principle asks of them. But that discipline has a cost: **the pipeline-aware agents recovered roughly half the findings the cold agents found**, and the missing half includes most of the HIGH-severity items.

This is the central tension this experiment surfaces. The principle works when the deterministic substrate is *complete*. When it's incomplete in load-bearing ways (no `--shared`, no `.tsx`, no inline-literal expansion), the disciplined agent inherits the substrate's blind spots.

## Where the cold agents *crossed the line*

Several cold-agent findings are not type-catalog issues at all:

- `binSlice` defined and tested but not registered in `combineSlices` → Redux store wiring.
- Two `requireAuth` functions with different signatures → API design / footgun.
- Role-extraction cascade copy-pasted across four sites → logic duplication, not type duplication.
- `betterAuthSessionToAuthenticationData` sync/async byte-near-identical 80-line bodies → function-body duplication.
- Four near-identical case branches in `convertV2Entry` → control-flow duplication.
- Orphan/broken `types.test.ts` → test-discovery / dead file.
- Byte-identical duplicate `StoreProvider.tsx` → orphan file.
- "No Zod / runtime validation anywhere" → convention observation.

These are all legitimate engineering findings, and they're all out of scope for the current pipeline. The cold agents are doing more than the pipeline was designed to enable, not less.

This is informative for the project's identity. The current pipeline answers "where are the duplicate type declarations?" Cold agents naturally widen the question to "where is the structural duplication, of any kind, that an engineering reader would flag in a code review?" That's a strictly bigger question. If we want pipeline-aware agents to compete on recall, we either:

1. **Narrow the question back** (frame the pipeline as "type-duplication-only audit," explicitly out-of-scope for logic dupes, dead code, etc.), or
2. **Grow the pipeline to encompass more** (add function-signature clustering, dead-code detection via reference counts, etc.), per [future-directions.md §2](./future-directions.md#2-beyond-types-the-catalog-as-a-universal-structural-index).

The first is honest about the lane. The second is the case study's roadmap. The dj-site experiment makes the cost-of-staying-narrow visible in a way the original audit did not, because dj-site happens to have most of its real structural problems *outside* the original lane.

## Calibration drift across runs

A subtler observation: severity ratings drifted between runs.

| Issue | 1A | 1B | 2A | 2B |
|---|---|---|---|---|
| WXYCRole reimplemented from shared | high | — (folded) | — (folded) | high |
| FlowsheetEntry duplicates shared dtos | — | — | high | high |
| JSONDates is a no-op | — | low | high | low |
| `binSlice` not registered | — | — | medium | — |
| `total_pages` vs `totalPages` wire bug | — | — | — | high |

1B's highest severity was "medium." 2B's pipeline-aware sibling (1B) found four findings as low/medium that 2B independently rated high. This is a function of the prompt structure ("don't pad with trivial findings") interacting with the substrate: when an agent's substrate is thin, it under-rates ("nothing here looks that bad"); when its substrate is rich, it over-rates ("there's a lot here, surely some of it is critical"). Severity is not stable across these agents.

For comparison purposes, the *count* of high-severity findings is therefore not very meaningful. The count of findings that survive a human review pass would be.

## What this says about the principle

Restating the principle: **deterministic extraction, agentic synthesis**. The lit test from the case study: *can the question be answered by clustering structured rows? If yes, write the extractor. If no, use agents.*

The dj-site experiment confirms the lit test directly. The findings that pipeline-aware agents *did* catch are exactly the ones the catalog rows answered (exact duplicates, subset relations, name overlaps in the indexed scope). The findings they missed are the ones whose answers required *new* catalog dimensions that don't exist yet:

- A `package="shared"` column populated from `@wxyc/shared/dtos` would have turned the cold agents' best findings into a one-line jq cluster.
- An `is_referenced: boolean` or `reference_count: int` column would have turned 1B's manual grep work into a query.
- A `field_names_normalized: [string]` column (casing-stripped) would have surfaced the `userName`/`username` drift mechanically.

The principle isn't wrong. It's that **the principle's payoff is proportional to the catalog's coverage of the question**. When coverage is thin, you fall back to agents doing enumeration work — which is exactly the trap the case study warned against. The disciplined pipeline-aware agents in 1A and 1B avoided that trap by *flagging the gaps* instead of compensating for them. That's the right move under the principle, but it means the run produces a strictly smaller findings list than a cold run.

## Implications for the pipeline contract

This experiment surfaces five concrete additions to [`pipeline-contract.md`](./pipeline-contract.md), all of which would have closed specific gaps observed:

1. **Indexing `.tsx`.** One-line fix to the TypeScript extractor's filename regex; supports the obvious follow-on (`react-component-props` as a new `kind`). Without this, frontend codebases get the pipeline's worst showing.
2. **`--shared` should not be optional in practice.** The orchestrator (whenever there is one) should warn loudly when a `package.json` in `--root` lists `@<scope>/shared` (or similar) and `--shared` is not passed. Today the pipeline silently emits an empty `cross-package-shadows.txt`, which both pipeline-aware agents correctly identified as misleading.
3. **Reference counts per declared type.** A second pass over the catalog (using `tsc`'s checker, or a grep-based approximation) populates `reference_count`. Solves the live-vs-dead distinction that 1B did by hand. The case study's "missed import" finding family also gets cheaper.
4. **Subset / superset clustering.** A new `subset-pairs.jq` that returns ordered pairs `(A, B)` where A's field set is a strict subset of B's. Cheap to compute, catches `Omit<Foo, …>` candidates that Jaccard alone can't see.
5. **Inline-literal expansion.** When the extractor sees a property whose `type` is itself a `TypeLiteralNode`, emit a synthetic catalog entry with the outer type's name + `.<field>` as the synthetic name, the inner members as `fields`. Then `BetterAuthSession.user` becomes a clusterable shape against `User`.

Item 1 is mechanical. Items 2 and 4 are short jq queries. Item 5 is a one-evening change to the extractor. Item 3 is the heaviest because it requires either a type-checker pass or a grep approximation; the grep approximation (`grep -rE "\\b<name>\\b"` minus the declaration site) is probably fine for a first cut.

A subtler implication: the pipeline contract should grow a notion of **negative space**. "We indexed 33 of 2478 TS/TSX files" is information the consumer needs to interpret the catalog's emptiness. A single line in `extractor.log` already states this; the catalog itself doesn't. Consider emitting a top-level `{ scope: { files_indexed, files_total, file_kinds_indexed } }` block alongside the entries array, so downstream queries can detect "the catalog is incomplete relative to the codebase" without re-walking the file tree.

## Comparison to the case study

The case study found 10 exact-dupe clusters + 15 near-dupe pairs in a 595-type Express backend. The dj-site run found 2 exact-dupe clusters + 2 near-dupe pairs (at 0.5 Jaccard) in a 140-type Next.js frontend.

**Per-type duplication density is ~6× lower on dj-site.** This is partly real (dj-site has been more disciplined about consolidating types) and partly an artifact (the extractor's scope misses where the real duplication lives — both inside `.tsx` files and across the `@wxyc/shared` boundary). The case-study repo was *all backend*, where Drizzle tables and Zod schemas are concentrated in `shared/database/` and `shared/validation/` — i.e., exactly the scope the extractor covers fully. dj-site's equivalent contracts live in `@wxyc/shared`, which the current run did not pass to `--shared`.

This is the second-language-of-TypeScript finding: **the same extractor produces qualitatively different value on different *kinds* of TypeScript codebases.** Backend monoliths with concentrated DTO modules get the original case-study experience: the pipeline does almost all the work, agents do small judgment passes. Frontend codebases with their contracts living in a separate npm package and most type declarations inside `.tsx` files get something much weaker out of the same pipeline.

The portability claim in the case study generalization section ("the architecture is portable across languages, audit goals, and repos because it factors cleanly") survives, but with a sharpening: portability requires **per-codebase-kind extractor configuration**, not just per-language. Adding `.tsx` support, default-on `--shared` warnings, and `--include-component-props` flags are the kinds of knobs a frontend audit needs that a backend audit doesn't.

## One prediction

If we re-ran this experiment after addressing the five contract additions above (`.tsx` indexing, `--shared`-warning, reference counts, subset detector, inline-literal expansion), the pipeline-aware agents would converge on ~80% of the cold-agent findings, and within-group Jaccard would rise from 0.4 to ~0.6+. The remaining 20% (logic dupes, dead Redux state, broken test files) is genuinely out of the type-catalog lane and should stay there, unless the pipeline grows new extractor `kind`s for those concerns (per [future-directions.md §2](./future-directions.md)).

If that prediction holds on a future run, the principle is validated empirically: deterministic extraction at the right level of coverage *does* keep agents disciplined to small judgment passes without sacrificing recall. If it fails — if cold agents still find many things pipeline-aware agents miss — then the pipeline's lane needs further narrowing or further widening, but not the half-measure of "type catalog only, but pretend it's a full audit."

## Implications for the next-language decision

The original motivation for this experiment was to gather a second TypeScript data point before committing to a second-language extractor. The data point is in, and it argues against rushing into a second language. The single highest-leverage piece of work right now is not a Python or Rust extractor — it is **closing the five gaps surfaced in this experiment on the TypeScript extractor**:

1. `.tsx` indexing
2. default-on `--shared` warning
3. reference counts
4. subset detector
5. inline-literal expansion

Each is small (hours to a day of work). Each is contract-compatible: existing queries continue to work, and the new columns enable new queries. Together they take the pipeline from "catches 30–40% of what a cold agent would find on a frontend codebase" to (predicted) "catches ~80%."

The Python extractor, per [`python-extractor-design-notes.md`](./python-extractor-design-notes.md), is itself a Path-2 problem ("parse + recognize contracts") with its own real surface of decisions — FastAPI route composition, Pydantic codegen+override, PyO3 boundaries, Alembic migrations. Building Python *and* TypeScript both at half-coverage is worse than building TypeScript at full coverage first. The path forward is: ratify the contract additions above on TypeScript, then re-run this experiment, then build Python with the lessons in hand.

## See also

- [`case-study.md`](./case-study.md) — the original audit and the deterministic-extraction principle that the dj-site run tests.
- [`pipeline-contract.md`](./pipeline-contract.md) — the JSON contract whose proposed additions are listed above.
- [`swift-extractor-design-notes.md`](./swift-extractor-design-notes.md) — the Swift feasibility study; converged on the "parse + recognize contracts" middle ground.
- [`python-extractor-design-notes.md`](./python-extractor-design-notes.md) — the Python feasibility study; same convergence point.
- [`future-directions.md`](./future-directions.md) — the roadmap. §1 (time as a first-class dimension; `--diff-against` lives here) and §2 (function-signature clustering, route handlers, SQL ASTs) are the items this experiment most directly motivates. The case study's [roadmap section](./case-study.md#roadmap) item 6 (eslint/biome-compatible rule emitter) becomes more attractive once the contract additions above land.
- Raw experimental outputs: `/tmp/wxyc-audit/dj-site/results/{exp1a,exp1b,exp2a,exp2b}.md`. Cluster query outputs and the catalog itself: `/tmp/wxyc-audit/dj-site/`.
- The dj-site repo: [`WXYC/dj-site`](https://github.com/WXYC/dj-site).
- The shared-types package this experiment kept pointing at: [`WXYC/wxyc-shared`](https://github.com/WXYC/wxyc-shared), specifically `src/auth-client/authorization.ts`, `src/auth-client/auth.ts`, and the OpenAPI-generated `dtos/`.
