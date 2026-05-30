# PR 3 — Binary skeleton: cmd/audit/ Go module embedding gojq

> **Note on the split.** This plan describes the full PR 3 scope. To keep the reviewable surface manageable, the implementation ships as two chained PRs:
>
> - **PR 3a (this PR)** — substrate parsers (front-matter, `manifest.toml`, catalog envelope), discovery, `.audit/` cache, extractor subprocess runner, and the `extract` + `status` subcommands. `audit query` is stubbed to print "lands in the follow-up PR". `gojq` is not yet a dependency.
> - **PR 3b (follow-up)** — embedded `gojq` engine, `audit query` (with the slurpfile / catalog-input wiring per the table below), and the end-to-end integration test exercising `extract → query`. Adds `gojq` to `go.mod` and wires `cmd/audit/main.go`'s `query` case to the new handler.
>
> Acceptance criteria below cover the full scope; PR 3a delivers everything except the engine and the `query` handler.

## Parent

Tracker: #177 (Audit binary implementation). Previous steps: PR 1 (#180, cluster envelope, merged), PR 2 (#185, front-matter + manifest.toml, merged), gojq compatibility verification (#188, merged — confirmed all 27 queries × 2 modes parity-clean, no `#! engine: jq` opt-outs needed at this snapshot).

Source ADRs: 0001 (`.audit/` cache directory, amended by 0007), 0002 (hybrid registration), 0003 (cluster envelope), 0004 (router architecture), 0005 (Go + gojq), 0006 (bundling + discovery), 0007 (reconciliation with snapshot family).

## Scope

Stand up the `audit` binary in Go. Three subcommands ship in this PR: `extract`, `query`, `status`. `report` lands in PR 4; `init` lands in PR 4. The binary does not yet have a goreleaser pipeline — that is also PR 4.

What this PR delivers, end-to-end, after `go build -o audit ./cmd/audit`:

1. `audit extract typescript --root <path> [--shared <path>] [--touched <path>]` — runs every `[[command]]` block in `extractors/typescript/manifest.toml` as subprocesses, materializes catalogs into `.audit/catalogs/<output_file>`, updates `.audit/meta.json`.
2. `audit query <name> [--arg/--argjson/--env knobs] [--format text|jsonl]` — resolves the named query via lookup-order discovery, parses its front-matter to know which catalog(s) to feed, evaluates with embedded `gojq`, prints to stdout.
3. `audit status` — prints what is cached under `.audit/`, the resolved source paths for queries and extractors, source-mtime staleness vs each catalog, and cwd-vs-`meta.json.root` mismatch warnings.

Naked `jq` and direct extractor invocations remain unaffected. `.jq` files and `manifest.toml` files are not edited in this PR.

## ADR alignment

| ADR | Decision PR 3 implements |
|---|---|
| 0001 (amended by 0007) | Per-repo `.audit/` is the canonical cache. `meta.json` carries `audit_version`, `last_touched_at`, `root`, `catalogs[<kind>]` (with `path`, `source_sha`, `envelope_summary`, `cli_args`). |
| 0002 | Two parsers: `#! key: value` front-matter on `.jq` files; TOML `manifest.toml` on extractor dirs. |
| 0003 | The binary does not invent shapes — it reads queries' `#! shape:` for `audit status` listing and routes JSONL evaluation through gojq unchanged. The shape-typed markdown renderer is PR 4's responsibility; the JSONL envelope itself flows through this PR transparently. |
| 0004 | Router: binary owns dispatch, `.audit/`, manifest parsing, lookup-order discovery. Extractors are `os/exec` subprocesses per manifest's `invocation`. Queries are evaluated by embedded `gojq`. |
| 0005 | gojq is embedded. The front-matter parser recognizes `#! engine: jq` (no current query uses it; the verification step confirmed parity); when present, the binary `os/exec`s system `jq` for that one query. |
| 0006 | Queries are embedded via `//go:embed`. Extractors are not embedded — they require host-language runtimes (npm, swift). Discovery is lookup-order: explicit flag → `$AUDIT_HOME` → cwd-relative → embedded (queries only) / `~/.config/audit/` (extractors; PR 4's `init` populates this, PR 3 only reads from it). |
| 0007 | `meta.json` carries `envelope_summary` cached from each catalog file's #141 envelope; the catalog file is authoritative and re-read on every `audit status` / `audit query` to refresh the cache when it differs. |

## Go module layout

```
go.mod                       # at repo root; module github.com/jakebromberg/code-audit-pipeline
go.sum
cmd/
└── audit/
    ├── main.go              # package main; cobra-free; flag.NewFlagSet per subcommand
    ├── embed.go             # package main; //go:generate + //go:embed
    └── queries/             # gitignored; populated by `go generate`
internal/
├── frontmatter/
│   ├── parser.go
│   └── parser_test.go
├── manifest/
│   ├── parser.go
│   └── parser_test.go
├── engine/
│   ├── engine.go            # gojq wrapper; jq shell-out for engine:jq opt-outs
│   └── engine_test.go
├── discovery/
│   ├── discovery.go         # lookup-order resolution for queries + extractors
│   └── discovery_test.go
├── auditdir/                # avoids name collision with /cmd/audit
│   ├── cache.go             # .audit/ read/write, meta.json schema
│   └── cache_test.go
├── extractor/
│   ├── runner.go            # token substitution + subprocess
│   └── runner_test.go
├── catalog/
│   ├── envelope.go          # parse #141 catalog envelope head; compute envelope_summary
│   └── envelope_test.go
└── cli/
    ├── extract.go
    ├── query.go
    └── status.go
testdata/                    # tiny fixture catalogs + tiny TS root for integration tests
```

Module path: `github.com/jakebromberg/code-audit-pipeline`. (Confirmed against repo origin URL.)

Dependencies (pinned):

- `github.com/itchyny/gojq v0.12.19` — already the verified version from PR step 3.
- `github.com/BurntSushi/toml v1.4.0` — stdlib-grade TOML parser. No reflection magic beyond what we exercise on `manifest.toml`.

No cobra, no urfave/cli. Subcommand dispatch is hand-rolled in `cmd/audit/main.go` over `flag.NewFlagSet` — three subcommands don't justify a framework, and the dispatch logic stays under 80 lines.

## Subcommand contracts

### `audit extract <extractor>`

Flags:

| Flag | Type | Meaning |
|---|---|---|
| `--root <path>` | string, required | Audited repo root. |
| `--shared <path>` | string, optional | Secondary package root; passed to extractor when manifest's `optional_args` declares a `--shared` activation. |
| `--touched <path>` | string, optional | JSON file with touched-in-window file list. Same condition. |
| `--include-tests` | bool, optional | Flag-only activation. |
| `--extractors-dir <path>` | string, optional | Override the extractors directory; bypasses lookup order. |
| `--catalog <kind>` | string, optional, repeatable | Limit to specific `[[command]]` block(s) within the extractor manifest. Default: run all. |

Behavior:

1. Resolve `extractors/<name>/manifest.toml` via lookup-order discovery (see Discovery section).
2. Parse the manifest.
3. For each `[[command]]` block (filtered by `--catalog` if provided):
   - Substitute placeholders (`{root}`, `{output}`, `{shared}`, `{touched}`, `{extensions}`, `{min_body_lines}`, `{references_output}`, `{files_output}`) into the `invocation` token list.
   - Apply `optional_args` whose `when` conditions match (`shared_set`, `touched_set`, `include_tests_set`, `references_enabled`, `files_enabled`, `min_body_lines_set`, `extensions_set`).
   - `os/exec` the resulting argv with cwd = the extractor directory. Stream stderr through; capture stdout to the temp file `<.audit/catalogs/<output_file>>.tmp`. Atomic rename on success.
4. After each successful subprocess, read the produced catalog's envelope head (top JSON object, `entries` not yet streamed), compute `envelope_summary`, compute the file's sha256.
5. Update `.audit/meta.json` (read, merge, write) with one `catalogs[<kind>]` entry per produced catalog plus any sibling outputs (`references-graph`, `files`) the manifest declares.
6. Manage `.gitignore`: append `.audit/` if not present.

Exit code: non-zero if any subprocess exits non-zero, or if the produced catalog fails to parse, or if the placeholder substitution leaves an unresolved `{...}` token.

### `audit query <name>`

Flags:

| Flag | Type | Meaning |
|---|---|---|
| `--arg NAME VALUE` | repeatable | Passed to gojq as a string binding. Validated against front-matter `arg:` declarations. |
| `--argjson NAME VALUE` | repeatable | Passed to gojq as a JSON-parsed value. Validated similarly. |
| `--env NAME=VALUE` | repeatable | Sets `os.Environ` for gojq's `$ENV.NAME` lookups, layered over the inherited environment. |
| `--format text\|jsonl` | optional, default text | Maps to `OUTPUT_FORMAT` env var seen by the query. |
| `--queries-dir <path>` | optional | Override; bypasses lookup order. |
| `--catalog <path>` | repeatable, optional | Explicit catalog input override. Order matches the front-matter `catalog:` list. Useful for CI driving the binary against a catalog that isn't under `.audit/`. |

Behavior:

1. Resolve the query file via discovery (see Discovery section).
2. Parse its front-matter.
3. Validate `--arg` / `--argjson` against the front-matter `arg:` lines. Required args missing → exit 2 with `audit query --help <name>`-style error. Type mismatches (e.g., `--arg X "abc"` where front-matter says `X number`) → exit 2.
4. Determine catalog inputs:
   - Front-matter `catalog: A` → positional input is `.audit/catalogs/A.json` (or `--catalog` override #1).
   - Front-matter `catalog: A, B, C` → positional is `A.json`; trailing kinds are mounted as `--slurpfile`-equivalent variables. The slurpfile variable name is the kind's underscore-form: `references-graph` → `$refs`, `type-catalog` → `$types`, `function-catalog` → `$functions`. Exception: `cross-catalog-name-collisions` (`catalog: type-catalog, type-catalog`) takes left/right slurpfiles bound as `$left` / `$right` and uses null input (`-n`-equivalent); the binary recognizes the two-of-same-kind case and switches to that wiring. The mapping is in `internal/engine/engine.go`'s catalog-to-variable table; PR 3 covers the **seven distinct catalog declarations** produced by PR 2's front-matter (verified by `grep '^#! catalog:' pipeline/queries/*.jq | sort -u`):

     | Declaration | Positional input | Slurpfile bindings | Null input? |
     |---|---|---|---|
     | `type-catalog` | type-catalog.json | — | no |
     | `function-catalog` | function-catalog.json | — | no |
     | `file-hashes` | file-hashes.json | — | no |
     | `files` | files.json | — | no |
     | `type-catalog, references-graph` | type-catalog.json | `$refs` ← references.json | no |
     | `function-catalog, type-catalog` | function-catalog.json | `$types` ← type-catalog.json | no |
     | `type-catalog, type-catalog` | (none) | `$left`, `$right` ← user-supplied | yes |

     The last row is the `cross-catalog-name-collisions` case. Both slurpfiles are user-supplied (via `--catalog <path>` overrides) because the audit cache holds only one type-catalog at a time; cross-catalog comparison is between two separate audit roots and the user names both. Any new query that adds a novel combination requires a one-line addition to this table.
   - `--catalog` overrides apply in declaration order.
5. Apply `--env` to the process env for the duration of the query evaluation.
6. If front-matter declares `#! engine: jq`, shell out to system `jq` with the constructed argv. Otherwise, use embedded `gojq`.
7. Stream output to stdout.

Exit code: 0 on success; 1 if the query errors at evaluation time; 2 on argument validation failure; 3 if the required catalog inputs aren't present under `.audit/` and `--catalog` wasn't given.

### `audit status`

No flags beyond `--root <path>` (defaults to cwd).

Output: human-readable, one section per concern:

```
Audit root:        /Users/jake/Developer/wxyc-ios-64
Cache:             .audit/   (initialized 2026-05-30T14:22:11Z, audit-version 0.1.0)
Queries source:    embedded (use --queries-dir to override; or set AUDIT_HOME)
Extractors source: ./extractors/   (cwd-relative)

Catalogs cached:
  type-catalog       2026-05-30T14:22:11Z  schema=1.1  extractor=typescript@0.5.0  3 files newer than catalog
  function-catalog   2026-05-30T14:22:11Z  schema=1.1  extractor=typescript@0.5.0  ok
  references-graph   2026-05-30T14:22:11Z  schema=1.1  (sibling of type-catalog)   ok

Warnings:
  type-catalog: 3 source files modified since extraction. Run `audit extract typescript` to refresh.
```

Exit code: 0 if all-clean; 1 if any catalog is stale or the cwd doesn't match `meta.json.root`.

## Front-matter parser (`internal/frontmatter`)

Surface: `Parse(reader io.Reader) (*Header, error)`.

Grammar: lines starting with `#! ` (hash, bang, space) up to the first non-`#!`-prefixed non-blank line. Other lines (regular jq comments, query body) are not consumed. Each `#!` line is `#! <key>: <value>`. Whitespace around the colon is stripped. The value is taken verbatim from the first non-space character after the colon to end-of-line.

Recognized keys (per PR 2's grammar, plus `engine` from ADR-0005):

| Key | Cardinality | Parsed form |
|---|---|---|
| `query` | 1 | string |
| `shape` | 1, comma-sep | one or two of `cluster\|pair\|metric` |
| `catalog` | 1, comma-sep | one or more catalog-kind strings |
| `arg` | 0..N | triplet: `<name> <type> <default-or-"required">`; type ∈ `number\|string\|json` |
| `env` | 0..N | triplet: `<NAME> <type> <default>`; type as above, default is empty string when value is `""` |
| `formats` | 1, comma-sep | subset of `text\|jsonl` |
| `desc` | 1 | string |
| `version` | 0..1 | integer; absent means 1 (PR-3 only recognizes grammar version 1) |
| `engine` | 0..1 | `jq` (only legal value; absent means embedded gojq) |

Unrecognized keys are an error in PR 3, not a warning. (Future grammar growth bumps `version`; the parser rejects unknown keys at the current version to surface typos.) When `version` is absent, the parser uses 1; when `version: 2` (or higher) appears, the parser errors with "front-matter version N not supported by this audit-version" so old binaries fail loudly against newer queries rather than silently mis-interpreting.

Validation:

- `query`, `shape`, `catalog`, `formats`, `desc` all required.
- `shape` value(s) must come from the legal set.
- `arg`/`env` triplets must have exactly 3 whitespace-separated tokens.
- `query` must be unique across the discovered query corpus (validated at the discovery layer when listing queries; the parser itself just records the value).

Test fixtures live in `internal/frontmatter/testdata/` — three valid headers (one of each shape) plus negative cases (missing required key, bad arg triplet, unknown key, double `query:`).

## Manifest parser (`internal/manifest`)

Surface: `Parse(path string) (*Manifest, error)`.

Schema mapped to Go structs:

```go
type Manifest struct {
    SchemaVersion int                `toml:"schema_version"`
    Extractor     ExtractorBlock     `toml:"extractor"`
    Commands      []CommandBlock     `toml:"command"`     // [[command]]
    Runtime       RuntimeBlock       `toml:"runtime"`
}
type ExtractorBlock struct {
    Name, Language, Version, Description string
}
type CommandBlock struct {
    Catalog        string               `toml:"catalog"`
    OutputFile     string               `toml:"output_file"`
    Invocation     []string             `toml:"invocation"`
    OptionalArgs   []OptionalArgEntry   `toml:"optional_args"`
    SiblingOutputs []SiblingOutputEntry `toml:"sibling_outputs"`
}
type OptionalArgEntry struct {
    Flag        string `toml:"flag"`
    Placeholder string `toml:"placeholder"`
    When        string `toml:"when"`
}
type SiblingOutputEntry struct {
    Catalog string `toml:"catalog"`
    File    string `toml:"file"`
    When    string `toml:"when"`
}
type RuntimeBlock struct {
    Requires   []string `toml:"requires"`
    SetupHint  string   `toml:"setup_hint"`
}
```

Validation:

- `schema_version == 1`. Future bumps gated explicitly.
- `extractor.name`, `extractor.version` required.
- At least one `[[command]]`.
- Every command's `invocation` must contain `{output}` (so the binary knows where to redirect). `{root}` is recommended but not required (file-hashes uses `--root`; future extractors may use a different convention).
- Every `optional_args[].when` and `sibling_outputs[].when` must come from a recognized set (`shared_set`, `touched_set`, `include_tests_set`, `references_enabled`, `files_enabled`, `min_body_lines_set`, `extensions_set`). Unknown values are an error — PR 3 closes the set by exhausting the three manifests in tree.

Test fixtures live in `internal/manifest/testdata/`.

## Discovery (`internal/discovery`)

Two surfaces:

- `ResolveQueriesDir(opts) (source string, fs fs.FS, err error)` — returns the directory (or `embed.FS` slice) holding `_canonical.jq` + queries.
- `ResolveExtractorsDir(opts) (string, error)` — returns the absolute directory holding per-language extractor subdirectories.

Lookup order (per ADR-0006):

1. Explicit flag (`--queries-dir` / `--extractors-dir`). Wins absolutely.
2. `$AUDIT_HOME/pipeline/queries/` and `$AUDIT_HOME/extractors/`.
3. cwd-relative `./pipeline/queries/` and `./extractors/`. Picks up local edits when running from a checkout.
4. Fallback:
   - Queries: bundled `embed.FS` (always present).
   - Extractors: `~/.config/audit/extractors/` (populated by `audit init` — PR 4). If absent, `audit extract` errors with a message pointing at `audit init`.

Resolution stops at the first hit. The chosen source path is surfaced in `audit status` so the lookup order is never invisible.

## gojq engine (`internal/engine`)

Surface: `Run(ctx, opts) error`.

`opts` carries:
- Query source (file path or in-memory string).
- `-L` library directory (for `include "_canonical";`).
- Variable bindings: `argjson` / `arg` / `slurpfile` / null-input flag.
- Output sink: writer for raw strings (`-r` equivalent).
- Engine selection: `embedded` (default) or `system` (when front-matter declares `engine: jq`).

Embedded path implementation:

- Parse query source into `*gojq.Query` via `gojq.Parse`.
- Compile with `gojq.WithModuleLoader(gojq.NewModuleLoader([]string{libDir}))`.
- For slurpfiles: read file, parse JSON into `interface{}`, wrap as `[value]` (matching jq's slurpfile semantics).
- Iterate with the appropriate input: positional catalog file, or `null` when the front-matter shape mandates `-n`-style invocation.
- `-r` semantics: when the iterator yields a string, write it raw (no JSON-encoding) plus newline. Non-strings emit `gojq`'s default JSON encoding.

System-jq path implementation:

- Build argv: `jq -L <libDir> -rf <queryPath>` plus `--slurpfile NAME path` per binding, plus `--argjson` / `--arg`, plus positional catalog file or `-n`.
- Inherit env, overlaying any `--env` overrides.
- Pipe stdout/stderr through; preserve exit code.

The two paths share a small driver that builds the variable-binding plan from the front-matter; the only divergence is "how do we apply this plan to gojq's Code/Run versus jq's argv?" This keeps the engine-switch behavior auditable.

## `.audit/` cache (`internal/auditdir`)

Surface:

- `Open(root string) (*Cache, error)` — reads `meta.json` if present; bootstraps an empty one if not. Auto-appends `.audit/` to `.gitignore` on first write.
- `(c *Cache) PutCatalog(kind string, args CLIArgs, envelopeHead json.RawMessage, fileSHA string) error`
- `(c *Cache) CatalogPath(kind string) (string, ok bool)`
- `(c *Cache) Status() ([]CatalogStatus, error)` — runs source-mtime staleness check, returns a list.
- `(c *Cache) Save() error` — atomic write.

`meta.json` schema (per ADR-0001 amended by ADR-0007):

```jsonc
{
  "audit_version": "0.1.0",
  "last_touched_at": "2026-05-30T14:22:11Z",
  "root": "/Users/jake/Developer/wxyc-ios-64",
  "catalogs": {
    "type-catalog": {
      "path": "catalogs/type-catalog.json",
      "source_sha": "<sha256 of catalogs/type-catalog.json>",
      "envelope_summary": {
        "schema_version": "1.1",
        "extractor": { "name": "type-catalog", "language": "typescript", "version": "0.5.0" },
        "fingerprint_v": "<from envelope>",
        "generated_at": "2026-05-30T14:22:11Z"
      },
      "cli_args": { "root": "/Users/jake/Developer/wxyc-ios-64", "shared": null, "touched": null }
    }
  }
}
```

Staleness checks:

- **Source-mtime.** For each catalog, walk the audit `root` (skipping the default skip-list documented in `docs/pipeline-contract.md`: `.git`, `node_modules`, `dist`, `build`, `coverage`, dotdirs) and count files whose mtime exceeds `envelope_summary.generated_at`. Report the count; ≥1 is "stale" (warning, exit 1 from `audit status`).
- **Root mismatch.** Compare cwd's nearest enclosing `.audit/`'s `meta.json.root` against the actual absolute path. Hard mismatch → exit non-zero from `audit status` and `audit query` (the silent-wrong-answer case ADR-0001 closes).

## Extractor subprocess invocation (`internal/extractor`)

Surface: `Run(ctx, manifestPath string, cmdSel CommandSelector, args CLIArgs) ([]CatalogResult, error)`.

Token substitution table:

| Token | Source |
|---|---|
| `{root}` | `args.Root` (required by every manifest in tree). |
| `{output}` | absolute path to `<auditdir>/catalogs/<command.output_file>` |
| `{shared}` | `args.Shared`; activated by `when = "shared_set"`. |
| `{touched}` | `args.Touched`; activated by `when = "touched_set"`. |
| `{extensions}` | `args.Extensions`; activated by `when = "extensions_set"`. |
| `{min_body_lines}` | `args.MinBodyLines`; activated by `when = "min_body_lines_set"`. |
| `{references_output}` | absolute path to `<auditdir>/catalogs/references.json`; activated by `when = "references_enabled"`. |
| `{files_output}` | absolute path to `<auditdir>/catalogs/files.json`; activated by `when = "files_enabled"`. |

Substitution leaves no `{...}` tokens behind; if any remain (e.g., a future manifest references `{unknown}`), the binary errors before exec.

Subprocess execution:

- `cwd` = the extractor directory (so relative invocations like `node type-catalog.mjs` find the script).
- Inherits environment, then overlays `AUDIT_VERSION` so extractors can record provenance in their own envelopes if they want.
- Stdout → captured to `<output>.tmp`; on success, atomic rename to `<output>`. Stderr → streamed through (so users see progress).
- Exit code propagated. Non-zero subprocess → no catalog written; tmp file removed.

## Embedded queries (`cmd/audit/embed.go`)

```go
package main

import "embed"

//go:generate go run ./internal/genqueries -src ../../pipeline/queries -dst ./queries

//go:embed queries/*.jq
//go:embed queries/_canonical.jq
var embeddedQueries embed.FS
```

The embed lives in `cmd/audit/` (package `main`) because `//go:embed` patterns must be in a subtree of the embedding file's directory and cannot use `..` — so `pipeline/queries/` cannot be referenced directly from a Go file that lives under `internal/` or `cmd/audit/`. The canonical source remains `pipeline/queries/`; `cmd/audit/queries/` is a build-artifact copy.

`internal/genqueries/main.go` is a tiny Go program (~30 lines) that:

1. Removes `cmd/audit/queries/` if it exists.
2. Copies every `*.jq` file (including `_canonical.jq`) from the configured `-src` directory into `-dst`.
3. Refuses to operate if `-src` is missing or empty.

Why a Go program rather than `cp` / `rsync`: portable across platforms (no `cp -R` quirks; tested by `go test` on every CI platform), no shell dependency, no `.bat` for Windows.

`cmd/audit/queries/` is added to `.gitignore`. `go generate ./...` is run as the first step in CI and is a documented one-time setup for local development. Whether the symlink-or-generate approach is right vs. relocating to a top-level package is the most likely review point — flagged.

A small helper exposes the embedded FS plus a query-name lister (basename minus `.jq`, excluding `_canonical.jq` since it's a library, not a runnable query).

## Tests

Two layers.

### Unit (per-package)

- `internal/frontmatter`: parse every PR-2-shipped header pattern (`testdata/headers/*.jq` mirroring real production headers); negative cases listed above. Runs in <50ms.
- `internal/manifest`: parse all three in-tree `manifest.toml` files (re-used via `testdata` symlinks); negative cases for missing fields, unknown `when` values, bad schema_version. Runs in <50ms.
- `internal/discovery`: resolve queries+extractors under each of the four lookup precedence levels using `t.TempDir()` setups. Runs in <100ms.
- `internal/engine`: a tiny synthetic catalog (`testdata/tiny-type-catalog.json`, 5 entries) plus three queries pulled from the embedded FS (`exact-duplicates`, `migration-progress`, `cross-catalog-name-collisions` — covers the three shapes and the slurpfile/null-input paths). Verifies byte-equality against the same query run through system `jq` on the same fixtures (the same parity check PR step 3 validated, now in Go's test runner). Runs in <500ms.
- `internal/auditdir`: read-modify-write `meta.json`; staleness check using `t.TempDir` with controlled mtimes. Runs in <100ms.
- `internal/extractor`: substitute placeholders against an in-memory manifest; check argv equality. No actual subprocess (mocked via interface). Runs in <50ms.
- `internal/catalog`: parse an envelope head; compute `envelope_summary`. Runs in <50ms.

### Integration (`cmd/audit_test.go`)

Spins up `t.TempDir()` as a fake repo containing:

- `extractors/typescript/` symlinked in from the real tree (so the real `manifest.toml` and `type-catalog.mjs` drive the test — same approach the existing integration tests use).
- A minimal `src/` with three `.ts` files (~30 lines total) that produce a deterministic type-catalog.
- The `node_modules/` install is gated behind an env var (`AUDIT_INTEGRATION=1`) so CI runs it but local-dev `go test` skips it.

Asserts:

1. `audit extract typescript --root <tmp>/src` produces `<tmp>/.audit/catalogs/type-catalog.json` with non-empty entries.
2. `audit extract` updates `meta.json` correctly (catalogs entry shape per the schema above).
3. `audit query exact-duplicates` (no clusters expected on the trivial fixture) prints nothing in JSONL mode, exits 0.
4. `audit query migration-progress --arg old_sig <s1> --arg new_sig <s2> --arg label test` prints a parseable percent line.
5. `audit query <name> --catalog <abs/path/to/catalog.json>` works even without `.audit/` cache.
6. `audit status` reports the catalogs correctly.

The full integration suite (the existing `test_queries_integration.sh` running 27 runnable queries × 2 modes — `pipeline/queries/` contains 28 `.jq` files, but `_canonical.jq` is a shared library, not a runnable query) is not Go-test-runtime; it stays as a separate shellcheck/CI step and is unaffected by this PR. PR 3 does not duplicate that coverage in Go.

## CI integration

New job appended to `.github/workflows/ci.yml`:

```yaml
go:
  name: go binary
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-go@v5
      with:
        go-version: '1.23'
        cache: true
    - name: Generate embedded queries
      run: go generate ./...
    - name: Go vet
      run: go vet ./...
    - name: Go test
      run: go test ./...
    - name: Go build
      run: go build -o /tmp/audit ./cmd/audit
    - name: Smoke test
      env:
        AUDIT_INTEGRATION: "1"
      run: |
        cd extractors/typescript && npm ci && cd -
        go test -tags integration ./cmd/audit/...
```

Existing `shellcheck`, `pipeline`, `swift` jobs unchanged.

## What's NOT in this PR

| Concern | Where it lives |
|---|---|
| `audit report` | PR 4 |
| `audit init` | PR 4 |
| Shape-typed markdown renderers (cluster/pair/metric) | PR 4 |
| goreleaser config, Homebrew tap | PR 4 |
| README rewrite around the binary | PR 4 |
| Cross-platform release matrix | PR 4 |
| Adding `--engine` opt-out queries | none (verification confirmed parity; the parser supports `#! engine: jq` so a future query can declare it without a binary change) |
| Snapshot/diff folding (`audit snapshot capture`, `audit diff`) | Out of scope for #177 entirely; see ADR-0007 "Future integration." |

## Acceptance criteria

- [ ] `go build -o audit ./cmd/audit` produces a binary on Linux and macOS.
- [ ] `go test ./...` passes with `-race`.
- [ ] `audit extract typescript --root <real repo>` populates `.audit/catalogs/type-catalog.json` whose byte content matches the catalog produced by running `node type-catalog.mjs --root <same>` directly (same extractor, same wiring, same output).
- [ ] `audit query <name>` for each of the 27 queries produces byte-identical output to the equivalent naked-`jq` invocation against the same catalog, in both text and jsonl modes, for the case-study TypeScript catalog. (The verification step proved this for the engine; PR 3 proves the wiring.)
- [ ] `audit status` warns when source files have been modified since extraction and exits non-zero on hard cwd-vs-root mismatch.
- [ ] `.audit/` is auto-added to `.gitignore` on first extract; idempotent on subsequent runs.
- [ ] CI's new `go` job passes on first push.
- [ ] PR delta is under 1000 lines (Go + tests + CI yaml + plan doc).

## Risk notes

- **`go generate` ordering.** Forgetting to run `go generate ./...` before `go build` produces a binary with stale or empty embedded queries — silently. Mitigations: CI runs `go generate` as step 1; the embedded helper's tests assert a known query is reachable so missing-files surfaces as a test failure rather than a runtime mystery; the README will document the `go generate` step alongside `npm install` for the TypeScript extractor.
- **gojq goroutine cancellation.** `gojq.Code.RunWithContext` honors `ctx.Done()`, but iterator drain after cancellation is the caller's responsibility. The engine wrapper consumes the iterator in a tight loop with a `select{ctx, iter}` switch so SIGINT exits cleanly.
- **TOML re-parsing on each invocation.** Three manifests, each <50 lines — measurably free. No caching layer needed in PR 3.
- **`engine: jq` shell-out path is untested at integration level.** No query currently declares it. PR 3 includes a unit test that exercises the shell-out code path against a synthetic query file, so the branch isn't dead code.
