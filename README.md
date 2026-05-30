# code-audit-pipeline

A recipe for converting a codebase into **actionable refactor recommendations**. AST extractors emit a canonical type/function catalog; `jq` queries cluster the rhymes — duplicate types, parallel protocols, name-without-shape collisions, missed abstractions; an agent reads each cluster and proposes a concrete refactor with grounded rationale. The `audit` binary glues these stages into one command line.

## The principle

**Deterministic extraction, agentic synthesis.** A 200-line AST extractor will reproducibly enumerate every type in your repo. An LLM won't. Reserve agents for the judgment step at the end — "should these three duplicates be extracted to a common package, or are they a PAT-shaped pair with one differing type slot?" — and use ordinary tools for everything upstream.

The lit-test before fan-out: *can the question be answered by clustering structured rows?* If yes, write the extractor. If no, agents earn their keep.

## The deliverable, in two layers

Two distinct things must work for the pipeline to be useful, and the project measures them separately:

1. **Input layer — does the substrate find the rhymes?** The extractors and cluster queries surface every structurally-parallel pair, every duplicated shape, every potential missed abstraction. Measured by **plant-recall**: inject synthetic rhymes into a real codebase, count how many surface in the right cluster. Validated by the [V6 Swift substrate experiment](docs/wxyc-ios-64-experiment-results.md) at 19/20 plants on a 350-file Swift codebase across 22 packages.
2. **Output layer — does the agent turn cluster rows into actionable recommendations?** For each cluster row, the agent emits a structured refactor recommendation (category + specifics + grounded rationale + alternative). Measured by **recommendation correctness** plus **restraint** (no false-positive recommendations on intentional duplication). The [V7 refactor-recommendation experiment](docs/refactor-recommendation-experiment-methodology.md) is the methodology for this.

Both layers are necessary; neither is sufficient on its own.

## Install

```bash
brew install jakebromberg/tap/audit            # macOS / Linux
go install github.com/jakebromberg/code-audit-pipeline/cmd/audit@latest
```

Or download a tarball from [Releases](https://github.com/jakebromberg/code-audit-pipeline/releases).

The binary embeds the full `pipeline/queries/*.jq` set, so cluster queries work immediately against any catalog you already have. Extractors live external (each has its own runtime — Node, Swift toolchain, future Python) and are bootstrapped via `audit init`.

## Quick start

```bash
# One-time: copy queries + extractors into ~/.config/audit/ from a local checkout.
audit init --from /path/to/code-audit-pipeline

# Run the TypeScript extractor against your repo; output is cached under .audit/.
audit extract typescript --root /path/to/your/repo

# Inspect cached state and the resolved query/extractor sources.
audit status

# Run an individual query interactively (text-mode output, ergonomic for humans).
audit query exact-duplicates
audit query near-duplicates --arg threshold=0.7

# Run every applicable query and write a single markdown report.
audit report
# → .audit/reports/findings-2026-05-30.md
```

The full subcommand surface:

| Subcommand | Purpose |
|---|---|
| `audit extract <name>` | Run an extractor; caches its catalog under `.audit/catalogs/`. |
| `audit query <name>` | Evaluate a query against cached catalogs (or `--catalog <path>` override). |
| `audit status` | Show `.audit/` state, resolved query/extractor sources, and staleness. |
| `audit report` | Run every runnable query and write a markdown report to `.audit/reports/`. |
| `audit init` | Bootstrap `~/.config/audit/` (extractors + queries) from a local source tree. |
| `audit version` | Print binary version. |

Per-command flags follow the long-form GNU convention (`--root`, `--queries-dir`, `--catalog`, etc.); run any subcommand with `--help` for the full list.

## How discovery works

Both queries and extractors are resolved via a lookup-order chain ([ADR-0006](docs/adr/0006-bundling-and-discovery.md)):

1. Explicit `--queries-dir` / `--extractors-dir` flag.
2. `pipeline/queries/` and `extractors/` rooted at the audit cwd (when present).
3. `$AUDIT_HOME` if set.
4. **Fallback:** embedded queries (always present); `~/.config/audit/extractors/` (populated by `audit init`).

`audit status` always prints the resolved source for both. The cwd-relative path makes contributor edits live without rebuilding the binary; the embedded fallback means a brewed binary works against any pre-existing catalog with no install steps.

## What the catalog contains

Top-level JSON is `{schema_version: "1.1", extractor: {...}, entries: [...]}` — one record per declared type inside `entries`. The contract is in [`docs/pipeline-contract.md`](docs/pipeline-contract.md). Core fields every extractor emits:

| Field | Meaning |
|---|---|
| `name` | declared identifier |
| `kind` | `interface` / `type-alias-object` / `type-alias-union` / `zod-object` / `drizzle-table` / language-specific variants |
| `package` | which root the file came from (e.g., `main`, `shared`) |
| `file`, `line` | relative-to-package-root path and 1-indexed line |
| `fields` | sorted `name:type` list, or `null` for non-shape types |
| `shape_sig` | `fields.join("|").lower` — deterministic hash for exact-duplicate clustering |
| `touched_in_window` | true if `file` appears in the `--touched` JSON list |
| `generated` | true for `.d.ts` or files under `generated/` |
| `is_test` | true if `file` matches test/fixture path patterns (see contract for the normative set) |
| `exported` | from-file export status |
| `extends` | sorted array of direct supertype names — empty if the declaration has no heritage |
| `references` | sorted array of `{name, kind: "type-ref"}` — names referenced in the declaration body, type-parameter-scoped, deny-listed against built-ins |
| `references_count` | `references \| length` — derived; emitted explicitly so queries don't pay the inline length call |

Sibling artifacts: `references.json` (inverted edge list, `--emit-references-graph`), `files.json` (per-file import edges, `--emit-files`), `function-catalog.json` (signature + body data, separate extractor), `file-hashes.json` (raw + normalized content hashes).

## Cluster queries

All operate on the JSON catalog and emit human-readable text mode or `OUTPUT_FORMAT=jsonl` for the report path. Each `.jq` file carries a `#! shape: cluster|pair|metric` front-matter line per [ADR-0003](docs/adr/0003-canonical-cluster-envelope.md); `audit report` dispatches every JSONL row through one of three shape renderers.

| Query | What it finds | Catalog |
|---|---|---|
| `exact-duplicates.jq` | Same `shape_sig` across ≥2 declarations | type |
| `name-collisions.jq` | Same `name` across multiple files | type |
| `cross-package-shadows.jq` | Type in `main` whose name exists in `shared` | type |
| `near-duplicates.jq` | Pairs with Jaccard ≥ threshold on field-name sets (default `0.7`) | type |
| `subset-pairs.jq` | Pairs (A, B) where A's field-name set is a strict subset of B's | type |
| `cross-package-shape-near-duplicates.jq` | main↔shared pairs with different names but Jaccard ≥ threshold | type |
| `function-duplicates.jq` | Exact body-hash clusters + pairwise Jaccard near-duplicates on function bodies | function |
| `file-duplicates.jq` | Exact byte-equal files + whitespace-normalized-only matches | file-hash |
| `cross-catalog-name-collisions.jq` | Type names declared in TWO catalogs (cross-repo, cross-language) | type, two-catalog |
| `migration-progress.jq` | Counts decls on old vs new `shape_sig`, computes % migrated, lists touched-in-window stragglers | type |
| `shape-sig-frequency.jq` | Lists `shape_sig` values by count desc with sample names | type |
| `generic-arity-drift.jq` | Declarations sharing a name but differing in type-parameter arity | type |
| `generic-convention-bound.jq` | Declarations whose field types reference a type-parameter-shaped identifier not bound by `generics` | type |
| `touched-window-debt-summary.jq` | PR-time meta-query: for each cluster type, fraction with ≥1 touched-in-window member | type |
| `orphan-infer-model.jq` | Drizzle tables nothing in the catalog derives a TS type from | type |
| `test-prod-drift.jq` | Near-duplicate pairs where exactly one side is in a test path | type |
| `dead-code.jq` | Exported, non-generated declarations with zero resolved incoming references | type + references |
| `public-api-leaks.jq` | Exported functions whose param or return types reference a non-exported same-package type | function + type |
| `cross-package-backward-imports.jq` | `shared/*` files importing from `main/*` — layering violation | files |

## Adding a new extractor

Any language with an AST library works. Each extractor must:

1. Accept `--root <path>`, optional `--shared <path>`, optional `--touched <json-file>`, optional `--output <path>`.
2. Walk source files under each root, skipping `node_modules`/`dist`/`.git`/etc.
3. For each type-equivalent declaration, emit one JSON record matching the contract.
4. Print summary stats to stderr; the JSON catalog to stdout (or `--output`).

Drop a `manifest.toml` in the extractor directory ([ADR-0002](docs/adr/0002-hybrid-registration.md)) so `audit extract <name>` knows the invocation. The contract doc has the full schema. The TypeScript extractor (~280 lines, uses `typescript`) is the reference. Suggested next:

- **Python** — `ast` (stdlib). Feasibility study: [`docs/python-extractor-design-notes.md`](docs/python-extractor-design-notes.md).
- **Rust** — `syn` crate, or treesitter-rust.
- **Go** — `go/ast` + `go/parser` (stdlib).
- **Swift** — `SwiftSyntax`. Feasibility study: [`docs/swift-extractor-design-notes.md`](docs/swift-extractor-design-notes.md).

## Hand-run mode

The binary delegates to the same extractors and queries that have always lived under `extractors/` and `pipeline/queries/`. For development work, one-off audits without installing the binary, or pipelines that need bespoke composition, the bash recipe still works end-to-end:

```bash
# 1. Manifest — every PR merged in the last 5 weeks
gh pr list --state merged --search "merged:>=$(date -v-5w +%Y-%m-%d)" --limit 300 \
  --json number,title,mergedAt,author,headRefName,files,closingIssuesReferences,labels \
  > prs.json

# 2. Classify PRs by file-path signal (adapt path patterns to your repo)
jq -f pipeline/classify.jq prs.json > prs-classified.json

# 3. Enumerate candidate .ts files touched by code-touching PRs
jq -s '
  .[0] as $cls | .[1] as $prs
  | ($cls | map(select(.primary == "code-touching" or .primary == "code")) | map(.number)) as $nums
  | $prs | map(select(.number as $n | $nums | index($n)))
  | map(.files[].path) | unique
  | map(select(test("\\.(ts|mts|cts)$")))
  | map(select(test("\\.(test|spec)\\.ts$") | not))
' prs-classified.json prs.json > candidates.json

# 4. Run the catalog (npm install inside extractors/typescript first)
cd extractors/typescript && npm install
node type-catalog.mjs \
  --root /path/to/your/repo \
  --shared /path/to/sibling/shared-package \
  --touched ../../candidates.json \
  --output ../../catalog.json

# 5. Cluster (queries emit multi-line strings — use -r for readable output)
jq -L pipeline/queries -rf pipeline/queries/exact-duplicates.jq catalog.json
jq -L pipeline/queries -r --argjson threshold 0.7 -f pipeline/queries/near-duplicates.jq catalog.json
```

The binary path produces the same artifacts under `.audit/catalogs/` and accepts JSONL on every query (`OUTPUT_FORMAT=jsonl` for the bash recipe, `--format jsonl` for `audit query`).

## Provenance

Extracted from a 5-week type-duplication audit of a TypeScript monorepo (179 source files, 595 type declarations indexed, 10 exact-dupe clusters and 15 near-dupe clusters found). The full origin story — what the audit found, why agent fan-out was the wrong reach, what to build next — is in [`docs/case-study.md`](docs/case-study.md).

## Experiment series

The project's validation track. Each experiment doc records its setup, plant set, results, and what changed about the methodology.

| Experiment | Layer | Question | Doc |
|---|---|---|---|
| V2 | input | Does broader substrate (function bodies, file hashes, cross-package shapes) catch what V1 missed? | [V2 results](docs/dj-site-divergence-experiment-v2-results.md) |
| V3 | input | Does plant-recall hold up under synthetic ground-truth methodology? | [V3 results](docs/dj-site-divergence-experiment-v3-results.md) |
| V4 | input | Does V3's recall hold up after contamination vectors are removed? | [V4 results](docs/dj-site-divergence-experiment-v4-results.md) |
| V5 | input | Do the four V4-flagged substrate gaps close? | [V5 results](docs/dj-site-divergence-experiment-v5-results.md) |
| V6 | input | Does the substrate transfer to Swift (wxyc-ios-64, 350 files, 22 packages)? | [V6 results](docs/wxyc-ios-64-experiment-results.md) |
| V7 | **output** | Does the substrate's cluster output feed actionable refactor recommendations, by category? | [V7 methodology](docs/refactor-recommendation-experiment-methodology.md) |

V2–V6 validate the input layer. V7 is the first experiment on the output layer.

## Architecture decisions

The binary's design is captured in seven ADRs under [`docs/adr/`](docs/adr/):

1. [`.audit/`](docs/adr/0001-audit-cache-directory.md) — per-repo cached state directory.
2. [Hybrid registration](docs/adr/0002-hybrid-registration.md) — front-matter for queries, `manifest.toml` for extractors.
3. [Cluster envelope](docs/adr/0003-canonical-cluster-envelope.md) — three shape renderers (cluster, pair, metric).
4. [Router architecture](docs/adr/0004-router-architecture.md) — subcommand dispatch.
5. [Go binary + gojq engine](docs/adr/0005-go-binary-gojq-engine.md) — embedded jq vs. system shell-out.
6. [Bundling + discovery](docs/adr/0006-bundling-and-discovery.md) — bundle queries, leave extractors external, lookup-order chain.
7. [Reconciliation with snapshot family](docs/adr/0007-reconciliation-with-snapshot-family.md) — catalog envelope vs. cluster envelope.

## Future directions

A ranked map of where this project could grow — temporal indexing, broader extractor kinds, queryable substrate, an evolved agent layer, and what to keep out — is in [`docs/future-directions.md`](docs/future-directions.md).

## License

[Anti-Capitalist Software License v1.4](https://anticapitalist.software/). See [LICENSE](LICENSE) for the full text. Use is permitted for individuals, non-profits, educational institutions, and worker-owned cooperatives; not permitted for capitalist organizations, law enforcement, or military.
