# code-audit-pipeline

A recipe for finding duplicate types, missed abstractions, and pattern drift in a codebase — without spending agent budget on extraction.

## The principle

**Deterministic extraction, agentic synthesis.** A 200-line AST extractor will reproducibly enumerate every type in your repo. An LLM won't. Reserve agents for the judgment step at the end — "is this 85%-Jaccard cluster actually consolidate-worthy, or are these semantically distinct?" — and use ordinary tools for everything upstream.

The lit-test before fan-out: *can the question be answered by clustering structured rows?* If yes, write the extractor. If no, agents earn their keep.

## The pipeline

```
1. Manifest    gh pr list --json …             → prs.json
2. Classify    jq filter on file paths         → prs-classified.json
3. Enumerate   jq join over candidate PRs      → candidates.json
4. Catalog     AST extractor (per language)    → catalog.json
5. Cluster     jq queries over catalog         → findings
   (LLM judgment, optionally, on cluster output)
```

The only language-specific phase is **4**. Everything else is `gh` + `jq`.

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

| Query | What it finds |
|---|---|
| `exact-duplicates.jq` | Same `shape_sig` across ≥2 declarations |
| `name-collisions.jq` | Same `name` across multiple files (often signals shadowing or naming-by-accident) |
| `cross-package-shadows.jq` | Type in `main` whose name exists in `shared` — likely should be an import |
| `near-duplicates.jq` | Pairs with Jaccard ≥ threshold on field-name sets (default `0.7`) |

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

Extracted from a 5-week type-duplication audit of a TypeScript monorepo (179 source files, 578 type declarations indexed, 10 exact-dupe clusters and 15 near-dupe clusters found). See [`docs/philosophy.md`](docs/philosophy.md) for the design choices.

## License

MIT
