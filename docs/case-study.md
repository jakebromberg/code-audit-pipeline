# Origin Story: Auditing a TypeScript Monorepo

> A case study in why this pipeline exists, what it found, and what to build next.

## Summary

A TypeScript monorepo had 253 PRs merged over five weeks. The question: had the team reinvented types or missed shared abstractions during the sprint? Reading the PRs end-to-end was infeasible, and the natural instinct — spawn many LLM subagents to catalog types per directory — was wrong for the task. A 280-line TypeScript AST extractor plus four `jq` queries cataloged **595 type declarations** across two packages in 2 seconds, surfacing **10 exact-duplicate clusters** and **15 near-duplicate clusters** with no LLM in the cataloging loop. The judgment calls — which clusters are actually consolidate-worthy — were the only place an LLM earned its keep. This repository is the resulting pipeline, packaged for reuse.

The lesson is broader than types: **deterministic extraction, agentic synthesis.** Use compilers, not language models, to enumerate things. Use language models, sparingly, to decide what the enumeration means.

## The problem

The codebase under audit was a TypeScript Express monorepo with three workspaces (`apps/`, `shared/`, `jobs/`) and a sibling package (`@wxyc/shared`) holding the canonical API DTOs. Development velocity over the window was high — 432 commits across 253 PRs, including new ETL jobs, new backfill jobs, schema migrations, and a major architectural pivot. No one had paused to look across the diff and ask, "did we just declare the same shape three times?"

The signal we wanted to recover — type duplication, missed imports, shared scaffolding waiting to happen — has an awkward property: **it lives between PRs, not within them.** PR A introduces `LogLevel`; the reviewer approves it. PR B introduces the same `LogLevel` in a different file; that reviewer approves it. Each PR is locally correct. The duplication only becomes visible when you can see the final state of the codebase as a whole. Reading PRs sequentially won't catch it.

That observation determines what a useful audit must do: enumerate *all* type-equivalent declarations in the current code, compare them, and surface clusters. The PR window is just a way to scope the inquiry ("changes made during this period") — the analysis itself operates on the codebase, not on diffs.

## A tempting wrong turn

The first plan was to fan out subagents. One agent per workspace directory; each emits a structured catalog of types declared in its slice; an orchestrator merges and clusters. It felt natural: code understanding is judgment-heavy, LLMs are good at code, fan-out gives parallelism, and the work seemed to want a smart reader.

It would have worked, in the sense of producing some output. But for cataloging specifically, agent fan-out is a poor fit:

1. **Variable recall.** An agent reading a directory may emit 40 types or 60 types from the same source. You usually can't tell which it missed without an authoritative second pass — which defeats the point of running it.
2. **Output drift.** Even with a strict-JSON template, two agents will subtly diverge — different field-order conventions, different escaping, different choices about whether to include re-exports. That divergence breaks orchestrator-side clustering.
3. **Re-run cost.** Tuning the prompt is iteration cost in tokens. Adjusting the threshold or the kind taxonomy means re-running every agent.
4. **Wrong tool.** Cataloging is structured extraction. Compilers do this exhaustively and deterministically by design. Asking an LLM to extract is like asking it to grep — it can, just worse.

The same instinct shows up in other contexts: "we have a hard analysis problem, let's parallelize agents at it." For cataloging — where the question reduces to "list every X, record property Y" — that instinct is the trap.

## What worked

The pipeline that emerged has five phases. Only one of them is language-specific.

```
1. Manifest       gh pr list --json                 → prs.json
2. Classify       jq filter on file paths           → prs-classified.json
3. Enumerate      jq join: candidate files          → candidates.json
4. Catalog        AST extractor (per language)      → catalog.json
5. Cluster        jq queries over catalog           → findings
```

**Phase 1–3** use `gh` and `jq` — no language awareness. The classifier buckets PRs by what file paths they touched (`docs`, `ci`, `test`, `code`, `schema`, `migration`, etc.). The enumerator intersects the manifest with the classification to produce a deduplicated list of source files touched by code-changing PRs.

**Phase 4** is the only language-specific part. For TypeScript, we use the TypeScript compiler API directly (`ts.createSourceFile`, no `ts-morph`, no `ast-grep`). The walker visits every `InterfaceDeclaration`, `TypeAliasDeclaration`, and `VariableStatement` whose initializer is a `z.object(...)` or `pgTable(...)` / `someSchema.table(...)` call. For each, it emits one JSON record:

```jsonc
{
  "name": "FlowsheetEntry",
  "kind": "interface",
  "package": "main",
  "file": "src/services/flowsheet.service.ts",
  "line": 42,
  "exported": true,
  "fields": ["album_title:string | null", "artist_name:string | null", "id:number"],
  "shape_sig": "album_title:string | null|artist_name:string | null|id:number",
  "touched_in_window": false,
  "generated": false
}
```

The trick is `shape_sig`: the sorted, lowercased, pipe-joined list of `name:type` field strings. Identical shapes hash identically regardless of declaration order. Once every type in the codebase carries a `shape_sig`, finding exact duplicates is one `jq` line:

```
group_by(.shape_sig) | map(select(length > 1))
```

**Phase 5** is a small handful of `jq` queries — exact-shape clusters, name collisions, cross-package shadows, near-duplicates by Jaccard similarity on field-name sets. They operate on the catalog JSON, take milliseconds, and produce human-readable output.

The cost: ~280 lines of TypeScript for the extractor, ~50 lines of `jq` for the classifier, ~20 lines each for the four cluster queries. End-to-end runtime on the case-study repo: under 2 seconds. Reproducible to the byte. Re-runnable for free.

## What it found

The pipeline indexed 194 source files in the main repo and 125 in the canonical-types sibling, producing **595 type declarations**. Distribution:

| Kind | Count |
|---|---|
| `interface` | 195 |
| `type-alias-other` | 153 |
| `type-alias-object` | 117 |
| `type-alias-infer-model` | 54 |
| `type-alias-union` | 36 |
| `drizzle-table` | 34 |
| `type-alias-intersection` | 6 |

**Zero parse errors** across the run.

Cluster findings, ranked by mechanical clarity:

### Backfill-job scaffolding duplication

Four backfill jobs each declare a byte-identical logger triplet:

- `BaseTags = { repo: string; run_id: string; tool: string }`
- `LoggerConfig = { repo: string; runId?: string; tool: string }`
- `LogLevel` union (same variants)

…in `jobs/{flowsheet-etl, flowsheet-metadata-backfill, library-artwork-url-backfill, library-identity-backfill}/logger.ts`. Roughly 600 lines of pure copy-paste. The right move is to extract a `shared/observability/logger.ts` package and import from there.

Adjacent finding: the orchestrator scaffolding (`RunResult`, `LookupFn`, `Totals`) repeats across the same four jobs, with `Totals` varying slightly per job because counter shapes differ. That points at a missing `BackfillOrchestrator<TInput, TOutput, TTotals>` base.

### LML client redeclared three ways

Three jobs that call into LML each declare their own response types (`LmlLookupResponse`, `LmlLookupResultItem`) in a local `lml-types.ts`. The shapes are nearly identical. The underlying issue is that LML's API contract has no single source of truth on the consumer side — each job invented its own. The right fix is either to consume types from a shared LML client module, or to have LML's contract live in `@wxyc/shared` and be regenerated from its OpenAPI.

### Pure missed imports

`DiscogsTrackItem` (interface, 3 fields) in `apps/backend/services/requestLine/types.ts` has **the exact shape** of `@wxyc/shared`'s `DiscogsTrack`. The author simply didn't know — or didn't notice — that the type already existed in the shared package. A one-line fix: replace the local declaration with an import. The cross-package shadow query catches this class of error reliably.

### Drift-risk near-duplicates

`FSEntryRaw` in `apps/backend/services/flowsheet.service.ts:99` is **86% Jaccard-similar** to the underlying `flowsheet` Drizzle table. It is a manually-maintained mirror of an auto-inferable shape. Every schema change risks the two falling out of sync silently; the type checker won't catch it because the manual one is sufficient on its own. Replacing it with `type FSEntryRaw = typeof flowsheet.$inferSelect` (or a narrowed pick of it) eliminates the drift class entirely.

### Name-overloading antipattern

`SyncResult` is declared four times — `shared/database/src/legacy/etl-utils.ts:120`, `jobs/artist-identity-etl/runIncremental.ts:21`, `jobs/flowsheet-etl/job.ts:309`, `jobs/rotation-etl/job.ts:57` — with **completely different shapes** each time. Same name, semantically incompatible payloads. A reader importing `SyncResult` from one place gets a different type than importing it from another. The right fix is one generic `SyncResult<TStats> = { ok: boolean; stats: TStats }` with stats parameterized.

The cluster queries surfaced 15 near-duplicate pairs in total. Each was a specific, citeable refactor candidate, with file:line for both sides.

## The principle

**Deterministic extraction, agentic synthesis.**

The pipeline draws a sharp line between two kinds of work:

- **Enumeration.** "What types exist? What are their shapes? Which are exported? Where are they declared?" Pure data engineering. The right tool is a compiler API.
- **Judgment.** "These two types have 85% overlapping fields — should we merge them, or are they intentionally separate?" Pure judgment. The right tool is a human, or an LLM, looking at a small structured cluster.

LLM fan-out tries to do both at once and ends up doing neither well. Splitting the work means each tool runs at its strengths: the AST script gives you complete, reproducible, byte-stable output; the LLM judgment step operates on small, well-defined inputs (a cluster of 4 nearly-identical types, a name collision across 3 files) where its job is to apply taste, not to recall.

A useful lit test, before reaching for agent fan-out: **can the question be answered by clustering structured rows?** If yes, write the extractor — even if you've never written that AST walk before, it pays off on the second run, and it lets you tighten the schema until clustering becomes trivial. If no — if the question is genuinely "why was this designed this way" or "is this pattern intentional" — agents earn their keep.

A second test, more cynical: **if you re-ran the agent fan-out tomorrow, would you get the same output?** If not, the work probably belonged in a script.

## Cost comparison

The hypothetical agent fan-out, sized:

- Phase-3 catalog agents: 6–10 (one per package/directory)
- Phase-5 pattern agents: 4–6 (one per pattern category)
- Each agent reads a directory tree and produces several KB of structured-but-narratively-decorated output
- Wall-clock: ~30–60 minutes for both waves
- Token cost: ~$5–15 in API
- Output: not byte-reproducible; recall not measurable

The actual pipeline:

- 1 AST extractor (~280 lines, ~1 hour of development time, one-time)
- 1 jq classifier (~50 lines, ~10 minutes)
- 4 jq cluster queries (~20 lines each, ~30 minutes total)
- Wall-clock per run: under 2 seconds
- Token cost per run: $0
- Output: byte-reproducible, complete, can re-cluster with different thresholds for free

The development cost dominates the first run. After that, the marginal cost is effectively zero — and the script can be re-pointed at a different repo by changing one CLI flag.

## Generalization

The pipeline architecture is portable across languages, audit goals, and repos because it factors cleanly.

**By language.** Each language adds one extractor in `extractors/<lang>/`, emitting the same JSON contract. Recommended candidates in rough order of payoff:

- **Python** — `ast` stdlib. Walk `ClassDef`, `AnnAssign`, dataclass-decorated classes, Pydantic `BaseModel` subclasses, SQLAlchemy declarative bases, FastAPI route handlers. Probably the second highest-value extractor for any team using a Python service layer.
- **Rust** — `syn` crate or treesitter-rust. Walk `ItemStruct`, `ItemEnum`, `ItemTrait`. Catalog `#[derive(…)]` attributes alongside.
- **Go** — `go/ast` + `go/parser` stdlib. Walk `*ast.StructType`, `*ast.InterfaceType`. Tag-based ORMs (GORM, ent) are easy to surface.
- **Swift** — `SwiftSyntax`, the official parser library. Walk `StructDeclSyntax`, `ProtocolDeclSyntax`, `ClassDeclSyntax`.

**By audit goal.** The schema and the cluster queries change; the architecture doesn't.

| Goal | Catalog schema | Cluster queries |
|---|---|---|
| Type duplication (this case) | `{name, kind, fields, shape_sig}` | exact shape, Jaccard, name collision |
| Dead code | `{name, file, exported, references_count}` | `references_count == 0` |
| API surface drift | `{exported_symbol, signature, version}` | diff across runs |
| Route duplication | `{method, path, handler, params}` | normalize path, group |
| Migration drift | `{migration, tables_touched, ops}` | group by table, conflicting ops |
| Function-signature duplication | `{name, params_sig, return_type}` | `params_sig` clustering |

**By window.** The PR-date window is a parameter. Anchor the window on a release tag, a commit SHA, or just walk the whole repo with no window at all (in which case `touched_in_window` is uniformly `false` and you're auditing all-time state).

## Roadmap

What this repository should grow into:

1. **A Python extractor.** Most teams running a TS service layer also run Python (FastAPI, data jobs, ML). A second extractor proves the contract and unlocks polyglot-repo audits.
2. **A `cluster-functions.jq` query family.** Same shape-signature trick applied to function signatures: `(params_types_sorted) -> return_type` as the signature. Catches duplicate helper implementations.
3. **A `cross-repo.jq` mode.** Run extractors over several repos, tag each catalog row with its repo, and run cross-package-shadows across the union. Surfaces "this type defined in repo A also exists in repo B" — the multi-service version of the missed-import problem.
4. **A `report.sh` orchestrator.** A bash wrapper that runs all five phases and emits a single Markdown report. Currently the user composes the steps; a one-command driver would lower the threshold from "interesting experiment" to "standard quarterly review."
5. **A `--diff-against <previous-catalog>.json` mode.** Compare a fresh catalog against last quarter's. Surface: types added, types removed, types whose shape changed. Audit-as-changelog.
6. **An eslint/biome-compatible rule emitter.** Once the catalog has identified e.g. `DiscogsTrackItem` as a missed import of `DiscogsTrack`, emit a project-local lint rule that fails CI if the local declaration creeps back in. The pipeline becomes preventive, not just diagnostic.

None of these require fundamental redesign. They're all variations on "swap the extractor" or "add another query."

## A final note on tool choice

The default reach for LLM-backed analysis is now strong enough that it's worth being explicit about when it's the wrong reach. The reach is correct when the question is judgment-heavy and the input is small. The reach is wrong when the question is enumeration-heavy and the input is large. For the latter, the boring tools — compilers, `jq`, `gh` — are still better, faster, and cheaper than any LLM, and they leave the LLM available for the part of the problem where its judgment actually matters.

A 280-line script wrote the catalog. Six lines of `jq` clustered it. One conversation with a language model decided what to do about the results. That's the proportion this pipeline is built around.
