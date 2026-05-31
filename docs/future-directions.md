# Future Directions

> Where this pipeline could grow, in order of priority.

The code-audit-pipeline began as a recipe for finding duplicate types in a TypeScript monorepo. Its shape, however, generalizes far beyond that one use case. What follows is a ranked map of directions the project could grow in. The directions are listed roughly by where the highest-leverage near-term work lives, with the more speculative and foundational directions further down. A short rationale for the ordering closes the document.

## 1. Time as a first-class dimension

A single audit answers the question "what's the current state of the codebase?" That is useful, but the temporal version of the same machinery is far more useful — and currently unbuilt.

- **Snapshot per commit, stored.** Once the catalog has a time index, it becomes possible to plot type count, duplication count, cross-package-shadow count, and other structural metrics over the project's history. Trends become visible.
- **Diff between snapshots.** "Show every cluster that grew this quarter." "Show the exact commit at which `SyncResult` acquired its second incompatible shape." This is *audit-as-changelog*, and it is powerful for retrospectives: it allows naming the moment at which drift started, which is the moment at which a conversation should have happened.
- **PR-level "what did this introduce?"** A PR's diff against the pre-PR catalog reports things like: "this PR added 7 types, 4 of which are ≥0.7 Jaccard-similar to existing types." This is a substantially stronger CI signal than the conventional "no lint errors."
- **Debt-budget metrics.** For each duplication cluster, compute a debt score — for instance, lines of code × number of call sites × divergence rate over time. Plot it. Once duplication has a number, it can have a budget, which means it can have an actual conversation in planning.

**Storage shape is scale-dependent.** At commit rates below roughly 50 per day, snapshots can stay as flat JSON files written to a directory; total volume remains small enough that filesystem walks and `jq` queries remain tractable. At higher rates — hundreds of commits per day across an organization — this approach hits practical limits quickly: a year's worth of full per-commit snapshots can easily exceed 100GB before deduplication. The substrate question (direction #3 below) becomes mandatory rather than optional once time-series is in scope at that scale. A diff-based storage pattern — storing only what changed per snapshot, rather than the full catalog each time — collapses the footprint by two orders of magnitude or more and is the design that keeps time-series workable indefinitely.

**Granularity choice matters.** Per-commit snapshots give forensic precision (the ability to identify exactly when a type first acquired a divergent shape) at higher cost. Per-PR snapshots are 5–7× cheaper and sufficient for routine audits. A useful default is per-PR snapshots in normal operation, with per-commit recomputation available on demand for forensic investigation.

The temporal extension reframes the project's purpose: from *find current duplication* to *manage structural debt as a measurable, addressable quantity over time*.

## 2. Beyond types: the catalog as a universal structural index

The pipeline's only language-specific phase walks abstract syntax trees and emits records. Today it captures types. There is no reason it cannot capture every structural thing the compiler already knows about — side by side, in one catalog — and let cross-cutting questions become joins rather than audits.

Candidate extractor kinds:

- Function signatures (parameters, return type, error channel, async-ness)
- Route handlers (method, path, query/body/response shapes)
- SQL queries parsed as ASTs, with SELECT structure, table set, and WHERE shape — not as strings
- Configuration consumption: which environment variables each module reads
- Permission / role middleware sites
- Logging emissions: which fields each log statement carries
- Telemetry and metric calls (name and labels)
- Error envelope shapes
- Migration operations
- Cache key generators
- Test assertions
- Import-graph edges

Once these all live in one catalog, cross-cutting questions stop being audits and start being queries. "Which routes lack a permission check?" becomes `routes ⨝ permission_sites` (anti-join). "Which slow queries lack a corresponding index?" becomes `queries ⨝ migrations`. "Which fields appear in our logs but not in our metrics?" becomes a column difference.

This reframes the project's identity. It is not a type-duplication tool — it is a recipe for *cross-cutting structural extraction*, and types are merely the first instance. The case-study Roadmap items (function-signature variant, route variant, migration variant) stop reading as "more queries" and start reading as "growing the substrate."

## 3. From flat JSON to a first-class substrate

The catalog is currently a regeneratable JSON file. That works well up to roughly 10,000 rows. The next plateaus, in increasing ambition:

- **SQLite-backed catalog with diff-based snapshots.** The same rows, properly indexed; time-series becomes a `snapshot_id` column. The load-bearing pattern is storing only what *changed* per snapshot — one row per `(snapshot, file, name)` for additions, modifications, and deletions — rather than re-storing the full catalog at each commit. This makes time-series tractable even at hundreds of commits per day: a typical 5-year history compresses from roughly 200GB (full snapshots) to roughly 100MB (diff-based). Near-duplicate search by field-name overlap becomes a self-join on a fields table. `jq` queries become SQL views — mildly more verbose, but far more composable. Once this exists, the time-series extension (#1) is feasible at scale; the two are coupled at high commit velocity.
- **An MCP server fronting the catalog.** Other agents query it via tool calls without having to re-parse the codebase. Catalog freshness becomes a first-class concern (regenerate on commit), but the per-query cost drops to a network call. The agentic synthesis step gets faster and cheaper.
- **A graph index.** Types and functions become nodes; references, `Pick<>`/`Extends`/`Implements` relationships become edges. Then "find all types reachable from this route handler's request body" is a graph traversal, not an N-pass `jq` merge. This is where it becomes possible to ask "what would break if I deleted this type?" *before* deleting it.
- **A versioned, first-class API.** A documented JSON schema for catalog records, semantically versioned. Lint rules, codemods, dashboards, and agents all consume it. The catalog becomes infrastructure.

The trajectory is: audit artifact → reproducible artifact → query substrate → organizational infrastructure. Each step represents a meaningful inflection in what the project enables.

## 4. The agent layer's evolving role — late, bounded, contract-bound

Today, agents are absent from cataloging and optionally present at synthesis. The right evolution holds that boundary while expanding what "synthesis" can mean:

- **Cluster triage.** Given a cluster of four candidate types, an agent says "merge these three, leave the fourth — here is the reason" with cited evidence. Cheap, scoped, auditable.
- **Refactor proposal.** The agent emits a pull-request draft for the safest cases (exact-shape duplicates collapsed into an import; field-subset shapes rewritten as `Pick<>` over the canonical type).
- **Refactor evaluation.** The agent runs the test suite, re-runs the pipeline, verifies that the post-refactor catalog shows the expected change, and reports up.
- **Continuous backlog maintenance.** Weekly: re-cluster, re-rank, refresh open refactor tickets. Surface to humans only when scores cross a threshold.
- **PR-time review companion.** When a new type lands in a pull request, the agent flags the clusters it would join. The output lives in PR comments, not in the developer's editor.

The constant across all of these: agents always come *after* the deterministic catalog. The catalog is the contract. This bounds agent cost (small inputs, focused questions) and keeps outputs auditable (anyone can re-run the catalog and verify the cluster). The anti-pattern is letting agents back upstream into the extraction step; the pipeline's identity is the line drawn there.

## 5. Discovering what the substrate should learn to find

Each new technique the pipeline gains — every new extractor field, every new cluster query, every new validator heuristic — has to come from somewhere. The case studies (#6) are one source. The codebase under audit is another. But once a target codebase has been worked over for any length of time, the obvious shape-duplication candidates dry up, and the next round of techniques has to come from somewhere outside the source itself. Mining what the maintainer already knows, and surfacing what the maintainer does not yet know, become distinct disciplines.

**Mining what already exists.** A maintainer's GitHub history, code comments, deprecation markers, ADRs, and project-level rules carry information the substrate has no direct view of. Each closed refactor pull request is a template — the diff captures both the wrong shape and the chosen fix, and the rest of the codebase can be searched for other sites matching the same before-shape. Each `TODO` / `FIXME` / `HACK` comment older than some threshold is a refactor candidate the maintainer has already partially acknowledged. Each `@available(*, deprecated)` marker with active callers in the workspace is a stalled migration. These mine cheaply, run deterministically, and surface candidates the pure-structural queries cannot.

**Lens agents grounded in archaeology.** When a codebase is well-factored, the remaining issues live in lens-specific blind spots: concurrency drift, half-rolled-out platform migrations, accepted but undocumented coupling, testability gaps the maintainer has worked around rather than addressed. Each lens has its own technique vocabulary. A lens-focused agent pass *grounded in the project's own archaeology* — open issues, recent commit messages, deprecation map — produces dramatically more targeted findings than open-ended "find refactors" prompts. The agent gains a basis on which to distinguish the things the maintainer has not yet noticed from the things the maintainer has already documented as accepted.

**Skeptic with evidence base.** The substrate's failure mode at this layer is precision: false positives on already-abstracted clusters, on intentional design splits, on deliberate concurrency-discipline asymmetries. The countermove is a second agent pass armed with the same archaeology corpus, whose only job is to ground each candidate finding in existing maintainer intent. A finding the skeptic can tie to a CLAUDE.md rule, an ADR, or a doc comment gets downranked. A finding without such grounding survives. The skeptic is not generating rebuttals from intuition; it is doing evidence lookup against a curated corpus. This makes the skeptic cheaper and more reliable, and the precision filters it produces are anchored in real maintainer decisions rather than agent guesses.

**Plant injection closes the measurement loop.** Every new technique should carry measured precision and recall. The V6 plant-recall methodology established this discipline at the substrate level (19/20 plants on a 350-file Swift codebase); the same framework extends to validators, lens agents, and skeptic passes. Without it, every new technique above is unmeasured, and the pipeline's quality claims revert to anecdote.

The composed workflow these techniques add up to:

1. **Substrate** runs deterministically — produces duplication clusters plus stalled-migration markers plus an archaeology bundle (open issues, TODO inventory, deprecation map, recent PR diffs).
2. **Archaeology-loaded lens agents** read the substrate output plus the archaeology, and run targeted searches per lens.
3. **Skeptic pass** reviews lens findings against the archaeology corpus, downranking anything explained by existing maintainer decisions.
4. **Human** reads the survivors.

Each layer's job is to make the next layer's input smaller and higher-signal. The substrate's role in this composition is no longer just "find duplicates" but "find duplicates plus the context that lets cheaper validators make precision calls." The agent layer in #4 above does not move; what moves is the substrate's surface area, which grows to include archaeology and the maintainer's prior decisions as first-class inputs.

This direction overlaps with #4 (the agent layer) but is distinct in scope: #4 is about what agents do given catalog data; this section is about what the catalog itself should learn to contain so that agents and humans operating on it can navigate well-factored codebases without burning the maintainer's attention on already-settled questions.

The rolling tracker for this agenda is #226; the first granular sub-item is #225 (find-next-instance).

## 6. The pipeline as a polemic

This is the speculative-but-foundational direction.

The repository, as it stands, is a working argument: for enumeration-shaped questions about a codebase, LLM fan-out is the wrong reach, and a small AST script plus `jq` dominates it on every dimension that matters — cost, recall, reproducibility, re-runnability. That argument generalizes far beyond code cataloging. It applies wherever a language model is being used as a glorified `grep`: data extraction, ETL design, monitoring instrumentation, knowledge-base curation, telemetry mining.

If the project leans into the polemic, it grows in two complementary directions:

- **A case-study library.** Each new audit — different repo, different language, different goal — lands as a document under `docs/case-studies/`. They compound. After five of them, the lesson is undeniable.
- **Comparative experiments.** For a given problem, run both the agent fan-out and the deterministic pipeline. Report cost, recall, and agreement. This is the data that turns the polemic from assertion into evidence. The kind of result that gets cited internally when someone proposes spawning twelve agents for the next analysis task.

The deeper observation underneath this direction: most existing code-quality tools operate *intra-file* (linters) or *intra-pull-request* (reviewers). The empty space — codebase-wide structural questions that require whole-state input — is poorly served by existing tools, and is exactly where missed imports, redundant scaffolding, scope creep, and architectural drift accrete. The pipeline's contribution is showing that, for enumeration questions in this empty space, compilers and small queries beat language models.

There are other empty spaces. Each one is a project.

## What to keep out

A project like this is at risk of sprawling, and resisting feature creep is itself a design choice. The explicit non-goals:

- **Not a linter.** ESLint and Biome do intra-file rules better, and statefully.
- **Not a refactoring tool.** ts-morph and jscodeshift do that better.
- **Not a code search engine.** Sourcegraph and Comby do that better.
- **Not a build tool, test runner, or deployer.** Those belong to other tools.

The lane this project occupies is *cross-cutting structural analysis*: work that requires the whole codebase as input and produces structured intermediate output that other tools — or humans — consume.

## Ordering rationale

The directions above are listed roughly in priority order, with the highest-leverage near-term work first and the more speculative or foundational directions further down.

**(1) Time as a first-class dimension** and **(2) broader catalog kinds** are the right starting points, in that order. A temporally-indexed catalog turns the project from "interesting one-shot audit" into "ongoing measurable thing" — the difference between a tool people try once and a tool teams build practice around. Once the temporal layer exists, the marginal cost of adding new extractor kinds (#2) drops sharply, because each new kind immediately inherits time-series, diff, and CI-gate behavior for free.

**Direction (3) substrate is coupled to (1) time-series at high commit velocity.** Below roughly 50 commits per day, time-series can run on flat JSON; above that threshold, the substrate question is forced rather than optional. At hundreds of commits per day across an organization, (1) and (3) collapse into a single first deliverable: a SQLite-backed catalog with diff-based per-commit storage. Treat the sequencing as "build (3) *as part of* (1) when commit pace requires it" rather than as serial priorities; below the threshold, (3) remains downstream of (1) as originally ordered.

**(4) The agent layer** becomes valuable once there is enough catalog data and enough cluster output to justify the heavier infrastructure investment. It remains downstream of the temporal layer regardless of commit velocity.

**(5) Discovering what the substrate should learn to find** runs in parallel with the other directions and feeds into all of them. It is the methodology by which the pipeline keeps growing techniques rather than going stale on a fixed query set. The first concrete sub-items — the find-next-instance feature, the archaeology bundler, and stalled-migration substrate queries — are deterministic substrate features with low cost and high immediate yield; the lens-and-skeptic infrastructure follows once the archaeology bundle exists. The rolling tracker is #226.

**(6) The polemic and case-study library** is the doc-and-content track that should run in parallel with everything else. Every audit done in anger should land as a case study, because that is what makes the argument concrete to readers who do not already accept it.

## Active decompositions

The V8 strategic expansion lives in GitHub as direction trackers, each with its own decomposition. Direction-tracker map: #115 (language extractors, direction #2) → #135–#140; #116 (depth queries) → #125–#129, #131–#134; #117 (time, direction #1) → #141, #142, #148–#150; #118 (cross-repo) → #152–#159; #119 (interface / usability layer) → #143–#147; #120 (dev-flow integration) → #123, #124, #130; #226 (discovery agenda, direction #5) → #225. #114 (agent-as-filter, direction #4) is undecomposed. The rolling per-triage tracker supersedes from #98 → #107 → #160; the latest issue carries the current open-count and P0 sequencing. GitHub is authoritative for structural state; this doc remains the strategic narrative.
