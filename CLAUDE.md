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
| `hooks/pre-commit-audit.mjs` | Local pre-commit hook (#124). Non-blocking digest of cluster signals on staged TypeScript files. Distributed via the `pre-commit` framework using `.pre-commit-hooks.yaml` at the repo root. |
| `docs/pipeline-contract.md` | The catalog JSON schema. Non-negotiable; downstream queries depend on it. |
| `docs/integrations/pre-commit-hook.md` | User-facing install + configuration guide for the hook. |
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
7. Register and wire it (these are enforced by CI, and easy to miss):
   - Add `extractors/<lang>/manifest.toml` (per ADR-0002; schema 2 if it needs a `[runtime].bootstrap` build step, like the Swift/Rust compiled extractors). The first `requires` token is the binary `doctor` probes on `PATH` — use the tool the invocation actually runs (e.g. `cargo`, not `rust`).
   - If the extractor has a build-output dir that is **not** a dotdir (Rust's `target/`, etc.), add it to `internal/initstate/skipdirs.go` **and** the `genembed` `-skip` list in `cmd/code-audit/embed.go`. A drift test (`internal/genembed`) enforces that the two stay in sync.
   - Run `go generate ./...` and commit the regenerated `cmd/code-audit/extractors/<lang>/` tree in the same PR (CI gate: `git status --porcelain` over the embed dirs).
   - Bump the expected allowlist in `pipeline/_tests/test_audit_core.sh` — `detect-languages.sh --extractors-dir` now sees the new manifest, so the polyglot-filter assertion changes.
   - Add a per-extractor CI job in `.github/workflows/ci.yml` (mirror the `python` / `swift` / `rust` jobs) so the extractor's own tests run.

## Adding a new cluster query

- New `.jq` file under `pipeline/queries/`.
- Document the run invocation in the file header — always include `-r` (raw output) for queries that emit multi-line strings.
- Operate on the canonical catalog schema. Resist adding extractor-specific fields to queries; if you need one, generalize the schema first.
- Use the `touched_in_window` flag to distinguish "introduced this audit window" from "long-standing."

## jq gotchas (encountered, not theoretical)

- **String interpolation:** inside `"\(...)"`, the embedded expression's strings are plain `"..."` — *not* escaped `\"...\"`. Over-escaping produces "INVALID_CHARACTER (Unix shell quoting issues?)" errors.
- **Raw output mode:** without `-r`, multi-line interpolated strings come back JSON-quoted with literal `\n`. Always use `-r` for human-readable cluster output.
- **Pipe-context `.`:** in `.kind | startswith("X") or . == "Y"`, the `.` after the pipe refers to `.kind`'s value, not the parent object. This is correct (both clauses operate on `.kind`), but easy to misread.
- **Set-membership argument scope:** in `$set | has(fn_location_key(.))`, the argument expression `fn_location_key(.)` is evaluated with `.` bound to **`$set`**, not to the outer record being tested — `has`'s argument is evaluated in the context piped into `has`, same as any other filter argument. When `$set` is an object (the `from_entries`-built lookup this codebase's queries use), this does not error: `loc_key`/`fn_location_key` interpolates fields off `$set`, gets nulls, and the lookup silently misses on every call, so the `select(... | not)` guard passes every row instead of filtering any of them — quiet over-inclusion, not a crash. (When `$set` is an array instead, `has` errors loudly — `jq: error: Cannot index array with string "..."` — so the object case is the one that hides.) Fix: bind the record to a variable **before** entering the `$set | has(...)` pipe and reference the variable, not `.`, inside the argument — `. as $r | select($set | has(fn_location_key($r)) | not)`. Found in `function-duplicates.jq`'s exact-cluster exclusion (issue #337).

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

- Source build: prefer `./install.sh` — it runs `go generate ./...` first, rewriting the tracked embed trees under `cmd/code-audit/` in place so they match the checkout's canonical sources (a byte-level no-op on a clean checkout), and stamps `internal/cli.Version` with `git describe` of the checkout plus `-dirty` whenever `git status --porcelain` reports anything, untracked files included — a stamp the Go toolchain's own VCS detection gets wrong inside linked worktrees (it attributes the build to the parent checkout's HEAD, `+dirty`). Raw `go install ./cmd/code-audit` still works from a clean checkout; the `//go:embed` targets under `cmd/code-audit/{queries,extractors}/` are committed to the repo. `go install github.com/jakebromberg/code-audit-pipeline/cmd/code-audit@<tag>` works against the Go module proxy for the same reason. Tests: `bash pipeline/_tests/test_install.sh`.
- The canonical sources for embed content are `pipeline/queries/*.jq` and `extractors/<lang>/*`. The generated copies under `cmd/code-audit/{queries,extractors}/` are produced by `go generate ./...` (driven by `internal/genembed`) and **must be regenerated and committed in the same PR** whenever a canonical source changes. CI enforces this with `git status --porcelain -- cmd/code-audit/queries cmd/code-audit/extractors` (which surfaces untracked embed files — `git diff` would silently ignore them) after running `go generate ./...`.
- The TypeScript extractor's `node_modules/` is gitignored. `npm install` runs automatically via the manifest's `[runtime].bootstrap` on first `code-audit extract`. Contributors editing extractor source via `code-audit init --from <checkout>` get the same bootstrap pass — no manual `npm install` step.
- Pipeline outputs (`prs.json`, `prs-classified.json`, `candidates.json`, `catalog.json`, `findings.md`) are gitignored — they are regeneratable and not for version control.
- Per-run scratch directory convention: `/tmp/wxyc-audit/` (or rename per project). Documented in the case study's reproducibility footer.
- The pre-commit hook (`hooks/pre-commit-audit.mjs`) keeps its cache under the consumer repo's `.git/audit/` (catalog.json, catalog.meta.json, last-report.md, timing.log). The cache is invalidated by any relevant-file mtime change or a 24h TTL. The hook ALWAYS exits 0 — every defensive path (extractor crash, jq error, wall-clock overrun) collapses to `code-audit: skipped (<reason>)` on stderr. Treat this as a non-negotiable invariant when extending the hook: a blocking warning trains users to `--no-verify`, and the hook stops being read at all. Tests live under `hooks/test/` and run via `npm run test:hooks` (node --test).
