# code-audit-pipeline

A recipe for converting a codebase into **actionable refactor recommendations**. AST extractors emit a canonical type/function catalog; `jq` queries cluster the rhymes — duplicate types, parallel protocols, name-without-shape collisions, missed abstractions; an agent reads each cluster and proposes a concrete refactor with grounded rationale.

## The principle

**Deterministic extraction, agentic synthesis.** A 200-line AST extractor will reproducibly enumerate every type in your repo. An LLM won't. Reserve agents for the judgment step at the end — "should these three duplicates be extracted to a common package, or are they a PAT-shaped pair with one differing type slot?" — and use ordinary tools for everything upstream.

The lit-test before fan-out: *can the question be answered by clustering structured rows?* If yes, write the extractor. If no, agents earn their keep.

## The deliverable, in two layers

Two distinct things must work for the pipeline to be useful, and the project measures them separately:

1. **Input layer — does the substrate find the rhymes?** The extractors and cluster queries surface every structurally-parallel pair, every duplicated shape, every potential missed abstraction. Measured by **plant-recall**: inject synthetic rhymes into a real codebase, count how many surface in the right cluster. Validated by the [V6 Swift substrate experiment](docs/wxyc-ios-64-experiment-results.md) at 19/20 plants on a 350-file Swift codebase across 22 packages.
2. **Output layer — does the agent turn cluster rows into actionable recommendations?** For each cluster row, the agent emits a structured refactor recommendation (category + specifics + grounded rationale + alternative). Measured by **recommendation correctness** plus **restraint** (no false-positive recommendations on intentional duplication). The [V7 refactor-recommendation experiment](docs/refactor-recommendation-experiment-methodology.md) is the methodology for this.

Both layers are necessary; neither is sufficient on its own.

## The pipeline

```
1. Manifest      gh pr list --json …             → prs.json
2. Classify      jq filter on file paths         → prs-classified.json
3. Enumerate     jq join over candidate PRs      → candidates.json
4. Catalog       AST extractor (per language)    → catalog.json
5. Cluster       jq queries over catalog         → cluster rows (JSONL)
6. Recommend     agent → per-cluster JSON recs   → refactor-recommendations.json
```

Steps 1–5 are the deterministic substrate. Step 6 is where LLM judgment lands — per-cluster, with cluster-row evidence as input and a structured JSON recommendation as output. The only language-specific phase is **4**. Everything else is `gh` + `jq` + the agent step.

## Quick start (TypeScript repo, 5-week audit window)

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

# 4. Run the catalog
cd extractors/typescript && npm install
node type-catalog.mjs \
  --root /path/to/your/repo \
  --shared /path/to/sibling/shared-package \  # optional
  --touched ../../candidates.json \           # optional
  --output ../../catalog.json

# 5. Cluster (queries emit multi-line strings — use -r for readable output)
jq -rf pipeline/queries/exact-duplicates.jq catalog.json
jq -rf pipeline/queries/name-collisions.jq catalog.json
jq -rf pipeline/queries/cross-package-shadows.jq catalog.json
jq -r --argjson threshold 0.7 -f pipeline/queries/near-duplicates.jq catalog.json
jq -rf pipeline/queries/subset-pairs.jq catalog.json
jq -r --argjson threshold 0.7 -f pipeline/queries/cross-package-shape-near-duplicates.jq catalog.json
```

For function-body and file-content duplicates (separate catalogs):

```bash
node extractors/typescript/function-catalog.mjs --root /path/to/your/repo --output function-catalog.json
jq -r --argjson threshold 0.7 -f pipeline/queries/function-duplicates.jq function-catalog.json

node extractors/file-hashes/file-hashes.mjs --root /path/to/your/repo --output file-hashes.json
jq -rf pipeline/queries/file-duplicates.jq file-hashes.json
```

## What the catalog contains

One JSON record per declared type. The contract is in [`docs/pipeline-contract.md`](docs/pipeline-contract.md). Core fields every extractor emits:

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
| `exported` | from-file export status |

## Cluster queries

All operate on the JSON catalog and emit human-readable output. Drop into a chat or report.

| Query | What it finds | Catalog |
|---|---|---|
| `exact-duplicates.jq` | Same `shape_sig` across ≥2 declarations | type |
| `name-collisions.jq` | Same `name` across multiple files (often signals shadowing or naming-by-accident) | type |
| `cross-package-shadows.jq` | Type in `main` whose name exists in `shared` — likely should be an import | type |
| `near-duplicates.jq` | Pairs with Jaccard ≥ threshold on field-name sets (default `0.7`) | type |
| `subset-pairs.jq` | Pairs (A, B) where A's field-name set is a strict subset of B's. Surfaces unrealized `extends` / `Pick<…>` relationships | type |
| `cross-package-shape-near-duplicates.jq` | main↔shared pairs with different names but Jaccard ≥ threshold on field-name sets — re-typed contracts | type |
| `function-duplicates.jq` | Exact body-hash clusters + pairwise Jaccard near-duplicates on function bodies | function |
| `file-duplicates.jq` | Exact byte-equal files + whitespace-normalized-only matches | file-hash |

## Adding a new extractor

Any language with an AST library works. Each extractor must:

1. Accept `--root <path>`, optional `--shared <path>`, optional `--touched <json-file>`, optional `--output <path>` (default stdout)
2. Walk source files under each root, skipping `node_modules`/`dist`/`.git`/etc.
3. For each type-equivalent declaration, emit one JSON record matching the contract
4. Print summary stats to stderr; the JSON catalog to stdout (or `--output`)

The contract doc has the minimum schema. The TypeScript extractor (~280 lines, uses `typescript`) is the reference. Suggested next:

- **Python** — `ast` (stdlib): `ClassDef`, `AnnAssign`, Pydantic `BaseModel` subclasses, SQLAlchemy declarative bases, FastAPI route handlers
- **Rust** — `syn` crate, or treesitter-rust
- **Go** — `go/ast` + `go/parser` (stdlib): `*ast.StructType`, `*ast.InterfaceType`
- **Swift** — `SwiftSyntax`

## Provenance

Extracted from a 5-week type-duplication audit of a TypeScript monorepo (179 source files, 595 type declarations indexed, 10 exact-dupe clusters and 15 near-dupe clusters found). The full origin story — what the audit found, why agent fan-out was the wrong reach, what to build next — is in [`docs/case-study.md`](docs/case-study.md).

## Experiment series

The project's validation track. Each experiment doc records its setup, plant set, results, and what changed about the methodology. Read in order if you want the full development arc:

| Experiment | Layer | Question | Doc |
|---|---|---|---|
| V2 | input | Does broader substrate (function bodies, file hashes, cross-package shapes) catch what V1 missed? | [V2 results](docs/dj-site-divergence-experiment-v2-results.md) |
| V3 | input | Does plant-recall hold up under synthetic ground-truth methodology? | [V3 plant manifest](docs/dj-site-divergence-experiment-v3-plant-manifest.md), [V3 results](docs/dj-site-divergence-experiment-v3-results.md) |
| V4 | input | Does V3's recall hold up after contamination vectors (plant comments, git history) are removed? | [V4 results](docs/dj-site-divergence-experiment-v4-results.md) |
| V5 | input | Do the four V4-flagged substrate gaps close — function bodies, file hashes, cross-package shape near-duplicates, intersection-type resolution? | [V5 results](docs/dj-site-divergence-experiment-v5-results.md) |
| V6 | input | Does the substrate transfer to Swift (wxyc-ios-64, 350 files, 22 packages)? | [V6 plant manifest](docs/wxyc-ios-64-experiment-plant-manifest.md), [V6 results](docs/wxyc-ios-64-experiment-results.md) |
| V7 | **output** | Does the substrate's cluster output feed actionable refactor recommendations, by category? | [V7 methodology](docs/refactor-recommendation-experiment-methodology.md), [V7 plan](plans/v7-refactor-recommendation-implementation-plan.md) |

V2–V6 validate the input layer. V7 is the first experiment on the output layer.

## Future directions

A ranked map of where this project could grow — temporal indexing, broader extractor kinds, queryable substrate, an evolved agent layer, and what to keep out — is in [`docs/future-directions.md`](docs/future-directions.md).

## License

[Anti-Capitalist Software License v1.4](https://anticapitalist.software/). See [LICENSE](LICENSE) for the full text. Use is permitted for individuals, non-profits, educational institutions, and worker-owned cooperatives; not permitted for capitalist organizations, law enforcement, or military.
