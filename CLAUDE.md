# code-audit-pipeline

A recipe for cross-cutting structural analysis of codebases. AST extractors emit a canonical JSON catalog; `jq` queries cluster duplicates and surface drift. The guiding principle is **deterministic extraction, agentic synthesis** — compilers do the enumeration, humans (or LLMs, sparingly) do the judgment.

Before doing meaningful work here, read:

- [`README.md`](README.md) — user-facing description and quick start.
- [`docs/case-study.md`](docs/case-study.md) — origin story; what the pipeline found in its first audit and why agent fan-out was the wrong reach.
- [`docs/future-directions.md`](docs/future-directions.md) — ranked roadmap.
- [`docs/pipeline-contract.md`](docs/pipeline-contract.md) — the JSON schema every extractor must emit. **Required reading before authoring or modifying an extractor.**

## The principle (do not violate)

The pipeline draws a sharp line: deterministic tools do cataloging, LLMs do small, focused judgment. If you find yourself proposing N parallel agents to enumerate types, functions, routes, migrations, or anything else structural — stop. Write the AST extractor. The development cost pays back on the second run, and the output is byte-reproducible.

Lit test before reaching for agents: *can the question be answered by clustering structured rows?* If yes, extract deterministically. If no — if the question is genuinely "why was this designed this way?" or "is this pattern intentional?" — agents earn their keep.

The anti-pattern is letting agents creep back upstream into the extraction step. The project's identity is the line drawn there.

## Layout

| Path | Purpose |
|---|---|
| `extractors/<lang>/` | One self-contained extractor per language. TypeScript reference: `extractors/typescript/type-catalog.mjs`. |
| `pipeline/classify.jq` | Bucket PRs by file-path signal. Path patterns are project-specific — adapt per audit. |
| `pipeline/queries/*.jq` | Cluster queries: exact duplicates, name collisions, cross-package shadows, near-duplicates (Jaccard). |
| `docs/pipeline-contract.md` | The catalog JSON schema. Non-negotiable; downstream queries depend on it. |
| `docs/case-study.md` | Origin-story white paper. |
| `docs/future-directions.md` | Ranked roadmap. |

## Adding a new extractor

1. Read [`docs/pipeline-contract.md`](docs/pipeline-contract.md). The schema is non-negotiable — cluster queries assume it.
2. Use the language's compiler or parser API directly. Recommended:
   - Python: `ast` (stdlib)
   - Rust: `syn` crate, or treesitter-rust
   - Go: `go/ast` + `go/parser` (stdlib)
   - Swift: `SwiftSyntax`
   - Kotlin/Java: kotlinc PSI, JavaParser
   - C#: Roslyn (`Microsoft.CodeAnalysis`)
3. **Do not use regex grep for cataloging.** Recall is unreliable; it misses generics, sees comments, can't compute shapes. Use the AST.
4. CLI contract: `--root <path>`, optional `--shared <path>`, optional `--touched <json>`, optional `--output <path>`, optional `--include-tests`. Match the TypeScript reference's flags.
5. Skip dotdirs by default (`.git`, `.claude`, `.next`, `.cursor`, `.idea`, `.vscode`, and similar IDE/agent state). These commonly contain worktree clones that inflate catalogs with near-duplicate copies of the same repo.
6. Summary stats to stderr; JSON catalog to stdout (or `--output`). Exit non-zero if no files were successfully indexed.

## Adding a new cluster query

- New `.jq` file under `pipeline/queries/`.
- Document the run invocation in the file header — always include `-r` (raw output) for queries that emit multi-line strings.
- Operate on the canonical catalog schema. Resist adding extractor-specific fields to queries; if you need one, generalize the schema first.
- Use the `touched_in_window` flag to distinguish "introduced this audit window" from "long-standing."

## jq gotchas (encountered, not theoretical)

- **String interpolation:** inside `"\(...)"`, the embedded expression's strings are plain `"..."` — *not* escaped `\"...\"`. Over-escaping produces "INVALID_CHARACTER (Unix shell quoting issues?)" errors.
- **Raw output mode:** without `-r`, multi-line interpolated strings come back JSON-quoted with literal `\n`. Always use `-r` for human-readable cluster output.
- **Pipe-context `.`:** in `.kind | startswith("X") or . == "Y"`, the `.` after the pipe refers to `.kind`'s value, not the parent object. This is correct (both clauses operate on `.kind`), but easy to misread.

## Non-goals

This project does NOT replicate, and should not grow toward:

- **Linters** (ESLint, Biome) — those do intra-file rules better and statefully.
- **Refactoring tools** (ts-morph, jscodeshift) — those execute changes; this project surfaces candidates.
- **Code search engines** (Sourcegraph, Comby) — those serve interactive search; this project produces structured catalogs.
- **Build / test / deploy tooling** — out of lane entirely.

The lane is *cross-cutting structural analysis*: work that requires the whole codebase as input and produces structured intermediate output that other tools (or humans) consume. Resist scope creep.

## License implications

This repo uses the [Anti-Capitalist Software License v1.4](https://anticapitalist.software/). It permits use by individuals, non-profits, educational institutions, and worker-owned cooperatives; it does not permit use by capitalist organizations, law enforcement, or military. When fielding contribution discussions or considering downstream uses, factor in the license's restrictions.

## Operational notes

- Source build: `go generate ./... && go install ./cmd/code-audit`. The `go generate` step runs `internal/genembed` to copy `pipeline/queries/*.jq` and `extractors/<lang>/*` into `cmd/code-audit/{queries,extractors}/` for the `//go:embed` in `embed.go`; skipping it fails with `pattern queries/*.jq: no matching files found`.
- The TypeScript extractor's `node_modules/` is gitignored. `npm install` runs automatically via the manifest's `[runtime].bootstrap` on first `code-audit extract`. Contributors editing extractor source via `code-audit init --from <checkout>` get the same bootstrap pass — no manual `npm install` step.
- Pipeline outputs (`prs.json`, `prs-classified.json`, `candidates.json`, `catalog.json`, `findings.md`) are gitignored — they are regeneratable and not for version control.
- Generated `//go:embed` sources (`cmd/code-audit/queries/`, `cmd/code-audit/extractors/`) are gitignored; canonical sources are `pipeline/queries/` and `extractors/`.
- Per-run scratch directory convention: `/tmp/wxyc-audit/` (or rename per project). Documented in the case study's reproducibility footer.
