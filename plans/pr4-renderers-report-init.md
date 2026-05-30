# PR 4 — Renderers + `audit report` + `audit init` + release pipeline + README rewrite

> **Note on the split.** This plan describes the full PR 4 scope. If the diff approaches the 1000-line budget mid-implementation, the work ships as two chained PRs:
>
> - **PR 4a** — `internal/render/` shape renderers and `audit report`. The user-visible payoff is "run audit report and get findings-<date>.md".
> - **PR 4b** — `audit init`, `.goreleaser.yaml`, release workflow, and README rewrite. The payoff is "install from Homebrew / go install and bootstrap extractors without cloning the repo."
>
> Both PRs together close the tracker. A single PR is preferred when the diff fits.

## Scope

PR 3 landed the binary substrate: `audit extract`, `audit query`, `audit status`, lookup-order discovery, embedded gojq, `.audit/` cache. PR 4 lands what makes the binary user-facing:

1. Three shape renderers (`cluster`, `pair`, `metric`) per [ADR-0003](../docs/adr/0003-canonical-cluster-envelope.md). One markdown writer per shape; the report dispatches purely on each row's `shape:` field.
2. `audit report` — runs every runnable query in JSONL mode, dispatches rows to the renderers, writes `.audit/reports/findings-<YYYY-MM-DD>.md`.
3. `audit init` — bootstraps `~/.config/audit/extractors/` (and the `queries/` tree) from the project source per [ADR-0006](../docs/adr/0006-bundling-and-discovery.md). Non-destructive on re-run; warns loudly when local modifications exist.
4. `.goreleaser.yaml` + a release workflow — produces Homebrew tap entries and GH Releases artifacts; `go install` already works for any tagged release.
5. README rewrite — the binary becomes the documented entry point; the bash-recipe path stays available under a "hand-run mode" section.

Out of scope (recorded so the boundary is visible): folding `pipeline/snapshot.mjs` → `audit snapshot capture` (ADR-0007's "future integration"); folding `pipeline/diff.mjs` → `audit diff`; supporting non-default reports (e.g., `--shape pair` filtered runs are a follow-up); custom Homebrew formula templates beyond goreleaser's defaults.

## Renderer contract

### Inputs

Each renderer consumes one parsed JSONL row (a `map[string]any` from `encoding/json`). Every row carries the envelope trio:

- `cluster_id` (string)
- `query` (string)
- `shape` (string — one of `cluster`, `pair`, `metric`)

Plus shape-specific envelope fields (per the catalog contract):

| Shape | Envelope fields | Notes |
|---|---|---|
| `cluster` | `members[]` — array of decl objects | Each member typically has `name`, `kind`, `package`, `file`, `line`, `touched_in_window`. Some queries carry larger projections (e.g., function-duplicates members carry `async`, `param_count`). |
| `pair` | `left`, `right` — decl objects | Optional paired companion fields with `left_*` / `right_*` prefixes: `left_fields`/`right_fields`, `left_only`/`right_only`, `left_slots`/`right_slots`, `left_swap_tokens`/`right_swap_tokens`. |
| `metric` | (none beyond envelope) | Arbitrary payload; some metric queries (e.g. `touched-window-debt-summary`) nest cluster-shaped objects under a payload field. |

Plus arbitrary query-specific payload: `jacc`, `intersection`, `union`, `shape_sig`, `field_count`, `body_hash`, `body_line_count`, `count`, `sample_names`, etc.

### Outputs

Each renderer returns a markdown string for one row. The report driver concatenates rows under one section per query.

### Renderer dispatch

```go
// internal/render/render.go
package render

type Row map[string]any

type Renderer func(r Row) (string, error)

var byShape = map[string]Renderer{
    "cluster": Cluster,
    "pair":    Pair,
    "metric":  Metric,
}

func Dispatch(r Row) (string, error) {
    s, _ := r["shape"].(string)
    fn, ok := byShape[s]
    if !ok {
        return "", fmt.Errorf("render: unknown shape %q (cluster_id=%v)", s, r["cluster_id"])
    }
    return fn(r)
}
```

Single dispatch table. Adding a new shape requires one new function plus one map entry; no per-query branching anywhere.

### Cluster renderer

```
### <cluster_id>

<header summary line>

- *<name> (<kind>) — <package>:<file>:<line>
-  <name> (<kind>) — <package>:<file>:<line>
- ...
```

Header summary fields (when present on the row): `<members | length> decl(s)`, `field_count=N`, `body_line_count=N`, `body_hash=<short8>`, `shape_sig=<value>`. Whichever are present and non-zero get joined with `, ` separators.

Member line prefix:
- `*` if `touched_in_window: true`
- ` ` otherwise (single space to align)

Optional member sub-fields (when present): `async`, `param_count`. Rendered after the `kind` in brackets.

### Pair renderer

```
### <cluster_id>

<header summary line>

- left:  <name> (<kind>) — <package>:<file>:<line>
- right: <name> (<kind>) — <package>:<file>:<line>

<companion-fields block>
```

Header summary fields (when present): `jacc=<percent>`, `intersection=<n>`, `union=<n>`, `overlap=<n>`. Joined with `, `.

Companion-fields block emitted when paired `left_*` / `right_*` arrays exist:

```
- left fields:   <comma list>
- right fields:  <comma list>
```

(Or `left only` / `right only` / `left slots` / `right slots` / `left swap tokens` / `right swap tokens`, picking up whichever pairs are present. The renderer walks the row for keys matching `left_<X>` and emits an aligned pair line when `right_<X>` exists.)

`touched_in_window` markers (`*` / ` `) appear on the `left:` / `right:` lines.

### Metric renderer

```
### <cluster_id>

<payload-as-key-value list>

<optional nested cluster block>
```

Payload rendering: every non-envelope, non-array key on the row becomes a `- key: value` line. Strings render as-is; numbers as their JSON form; objects compacted as JSON.

Nested cluster block: if a payload field is an array of objects whose elements look cluster-shaped (carry `cluster_id` and `members`), recursively render each via `Cluster()` and emit them as a nested `#### ` block under a sub-heading derived from the parent payload key (`touched_clusters` → "Touched clusters").

This handles `touched-window-debt-summary`'s nested `touched_clusters[]` field without special-casing the query. If a future metric query nests pairs, extend the recursion in one place.

### Why generic dispatch rather than per-query rendering

ADR-0003 chose shape-typed dispatch over (a) verbatim text concatenation, (b) one renderer per query, and (c) markdown templates in front-matter. The N-renderers-for-N-queries option fails the cost calculus: adding a query that fits an existing shape requires zero binary-side code. Shape-typed dispatch is also more honest about the cluster envelope — the renderer treats every row as a structured snapshot rather than mining query-specific fields.

The trade-off is that the rendered output is uniform across queries but slightly less rich than the bespoke text mode each `.jq` already emits. That trade is acceptable for `audit report` because the report is the post-PR-time deliverable, not the interactive surface — the interactive surface stays `audit query <name>` which still renders the .jq's text mode.

## `audit report` subcommand

### CLI

```
audit report [flags]

Flags:
  --output PATH      Destination file (default: .audit/reports/findings-YYYY-MM-DD.md)
  --queries-dir DIR  Explicit queries directory (lookup-order override)
  --query NAME       Run only this query (repeatable). Default: every runnable query.
  --shape SHAPE      Only run queries whose front-matter shape includes SHAPE (repeatable; cluster|pair|metric).
  --root PATH        Audit root (default: cwd).
  --arg NAME=VALUE   Forwarded to query (repeatable).
  --argjson NAME=JSON Forwarded to query (repeatable).
  --env NAME=VALUE   Forwarded to query (repeatable).
  --skip-missing-args  Skip queries with unsatisfied required args instead of failing.
```

### Algorithm

1. Resolve the queries source via `discovery.ResolveQueriesDir` (same lookup order `audit query` uses).
2. Enumerate `.jq` files in the queries source.
3. For each query:
   - Parse front-matter via `internal/frontmatter`. Skip silently if parse fails (the file may be `_canonical.jq` or a partial draft).
   - Skip if `--query` filter is set and the query name isn't in it.
   - Skip if `--shape` filter is set and the query's declared shape doesn't intersect.
   - Skip if `formats` doesn't include `jsonl` (some queries are text-only; document the gap rather than synthesize JSONL).
   - For each declared catalog kind: confirm a cached path via `auditdir.Cache.CatalogPath`. If any is missing, record "skipped (catalog <kind> not cached)" and continue.
   - For each required `--arg` without a default: confirm a binding was provided via the report's `--arg`/`--argjson`. If missing and `--skip-missing-args` is set, record "skipped (requires --arg <name>)"; otherwise return a non-zero exit code with a clear error.
4. Run the query via the existing `engine.Run` path, capturing stdout into a buffer.
5. Parse each captured line as JSON. Render via `render.Dispatch`. Accumulate markdown.
6. After every query completes, write the report file (atomic via tmp-then-rename) with the structure below.

The driver re-uses `internal/cli/query.go`'s `wireCatalogs` / `buildBindings` / `engine.Run` paths verbatim — no duplication. `wireCatalogs` and `buildBindings` are already package-private in `internal/cli`, so `report.go` (same package) calls them directly without exporting anything new. Before adding `report.go`, lift these helpers and the supporting `splitKV` / `parseDefault` / `typecheckBinding` / `slurpfileVar` into a new `internal/cli/common.go` file so `query.go` and `report.go` each become a single subcommand's worth of code. A small `runEngineCapture(opts, dst io.Writer) error` helper isolates the "execute and capture stdout" phase so the report driver and `audit query` share the same prelude.

### Report structure

```
# Audit findings

_Generated <ISO-8601 timestamp> by audit <version>. Root: <absolute path>._

<one section per query that produced rows>

## <query-name>

_<desc from front-matter>. <N> rows, shape: <cluster|pair|metric>._

<one rendered block per row>

## <next query>
...

## Skipped queries

<one line per skipped query: "name — reason">
```

When no query produced rows and none were skipped, the body reads `_No findings._` under the header.

### Edge cases

- **Empty result set per query.** The query produced zero JSONL rows. Don't emit a section header; record under "Skipped queries" as `<name> — no rows`.
- **JSONL with non-row text.** Some queries print a banner before the rows (e.g. `touched-window-debt-summary` has a `note:` line in text mode but not in JSONL — JSONL is strict). The driver expects pure JSONL in JSONL mode. If a line fails to parse, treat the line as a hard error (point at the offending query) — front-matter validation already requires `formats: text, jsonl`, so a JSONL-mode failure is a bug in the query.
- **Dual-section queries.** `function-duplicates` and `file-duplicates` declare two shapes (e.g. `cluster, pair`). Their JSONL output contains rows of both shapes. The renderer dispatches each row by its own `shape` field; the section header in the report names the query once and contains a mix of cluster and pair blocks. Acceptable — the cluster_id prefix already disambiguates (`function-duplicates-exact` vs `function-duplicates-near`).
- **Long member lists.** A cluster with 50 members renders all 50; no truncation. The report file is checked into a `.audit/reports/` directory that is gitignored anyway. A `--max-members-per-cluster` flag is a follow-up.
- **Unicode in fields.** Markdown rendering passes through verbatim. The cluster envelope contract already commits to UTF-8 throughout.
- **Concurrent runs.** Two `audit report` invocations writing the same file collide. The atomic tmp-then-rename means the loser still gets a well-formed file, just clobbered. A timestamp-based default filename (`findings-YYYY-MM-DDTHHMMSS.md`) would avoid collisions; the simpler date-only default is preferred since the dominant flow is one report per audit window. Document the collision behavior; revisit if it bites.

### Exit codes

- `0` — report written; every selected query either ran or was recorded as skipped with a reason.
- `1` — at least one query failed at the engine level (gojq error, missing catalog, etc.) and `--skip-missing-args` did not cover the failure class.
- `2` — usage error (bad flag, output path unwritable, queries source unresolved).

### Integration test

End-to-end: extract → query → report. Asserts:

1. `audit report` produces a non-empty file at the default path.
2. The file contains a `## exact-duplicates` section when the catalog has duplicate shapes.
3. The "Skipped queries" section names each query that was skipped with a reason.
4. The header line carries the audit version and root.
5. Re-running `audit report` overwrites the prior file (mtime advances).

## `audit init` subcommand

### CLI

```
audit init [flags]

Flags:
  --dest PATH        Destination root (default: $XDG_CONFIG_HOME/audit or ~/.config/audit).
  --from PATH        Source: a local checked-out copy of code-audit-pipeline. Required in v1.
  --upgrade          Refresh dest from source even when files already exist. Warns about local mods.
  --force            Overwrite locally-modified files without prompting. Implies --upgrade.
  --dry-run          Print what would copy without writing.
```

`--from PATH` is required in v1 — the binary doesn't yet know how to fetch a pinned release tarball. Released binaries can shell out to `git clone` in the future; recording the design here so the v2 path is unambiguous.

### Algorithm

1. Resolve destination: `--dest` flag → `$XDG_CONFIG_HOME/audit` → `~/.config/audit`.
2. Resolve source: `--from <path>` must exist and contain `extractors/` and `pipeline/queries/` subdirectories. Otherwise exit 2.
3. Walk source `extractors/` and `pipeline/queries/`; build a copy plan:
   - Each file under `<src>/extractors/<lang>/...` maps to `<dest>/extractors/<lang>/...`.
   - Each file under `<src>/pipeline/queries/...` maps to `<dest>/pipeline/queries/...`.
   - Skip per-extractor `node_modules/`, `.build/`, `DerivedData/`, dotfiles (`.npmrc` etc.), and the extractor-emitted scratch outputs.
4. For each destination file: classify against the state file (`<dest>/.audit-init/state.json`), which is the authoritative lookup table. The state file's `files` object is keyed by destination-relative forward-slash path, with each value carrying the pristine `sha256` recorded at last apply. Classification rules:
   - **NEW** — the state file is missing OR the destination path is absent from `state.files`. Copy unconditionally.
   - **CLEAN** — the path exists in `state.files` AND the destination file's current sha256 matches the recorded value. Copy unconditionally (treat as upgrade).
   - **DIRTY** — the path exists in `state.files` AND the destination file's current sha256 differs (locally modified). Without `--force`: print a warning, skip the file, mark report exit code 1. With `--force`: overwrite.

   An absent state file therefore reconciles cleanly: every destination file classifies as NEW, copies in, and a fresh state file is written at the end. This is the manual-setup-then-init-later case.
5. After copying, write `<dest>/.audit-init/state.json`:
   ```json
   {
     "audit_version": "<binary version>",
     "source_repo_root": "<absolute --from path>",
     "source_commit_sha": "<git HEAD of --from, if available>",
     "applied_at": "<RFC3339 timestamp>",
     "files": {
       "extractors/typescript/type-catalog.mjs": {"sha256": "..."}
     }
   }
   ```
6. Print a summary: `init: copied N new, M upgraded, K skipped (dirty), L would-overwrite (dirty)`.

The state file is the "pristine sha" cache that lets the next `--upgrade` distinguish CLEAN from DIRTY without re-reading the source repo. Convention borrowed from `rustup`'s `~/.rustup/settings.toml` and `nvm`'s `~/.nvm/alias/`.

### Why a state file rather than re-fetching source

ADR-0006 says `audit init` "nukes-and-re-clones the canonical paths but warns loudly when locally-modified files exist." That's the right policy. The state file is what makes the warning possible without an active source-of-truth: if we only knew the destination's current state, we couldn't tell "user edited the typescript extractor" from "the bundled extractor changed between versions and the user is running an older binary." The state file pins the per-file sha at install time so subsequent invocations have a baseline to compare against.

If the state file is absent (manual setup, or first-time install before `audit init` existed), every existing destination file classifies as DIRTY. The user runs `--force` once to reconcile, and from then on the state file makes upgrades safe.

### Edge cases

- **Destination is a symlink to source.** Detected via `os.Lstat`; refuse to operate (developer setup, would copy in a loop).
- **Destination outside HOME.** Allowed (per `--dest` flag). The init isn't security-sensitive — it copies query and extractor files.
- **Read-only destination.** Surface the OS error verbatim; exit 2.
- **Partial copy on interruption.** Files are written atomically (tmp-then-rename). The state file is the last thing written, so an interruption leaves the destination in a "some files copied, state stale" state that the next `--upgrade` reconciles by treating untracked-in-state files as NEW.
- **Cross-platform path separators.** Source walks use `filepath.Walk`; destination paths are joined via `filepath.Join`. The state file records forward-slash relative paths so the same state file works across platforms (queries don't, but this is a v1 punt — Homebrew users are macOS/Linux).

### Integration test

1. Create a temp `dest/`. Run `audit init --from <repo-root> --dest <dest>`. Assert files exist under `<dest>/extractors/typescript/` and `<dest>/pipeline/queries/`.
2. Re-run with no changes. Assert exit 0 and "copied 0 new" reported.
3. Modify one file in `<dest>`. Re-run with `--upgrade`. Assert exit 1 and the modified file is reported as DIRTY-skipped.
4. Re-run with `--force`. Assert the file is overwritten and exit 0.
5. State file content matches expected sha256s.

## Release pipeline (goreleaser)

### `.goreleaser.yaml`

Lives at the repo root. Configures:

- **builds**: one entry building `cmd/audit/`. Targets `darwin/amd64`, `darwin/arm64`, `linux/amd64`, `linux/arm64`. CGO disabled. `ldflags` pin `cli.Version` to the git tag via `-X github.com/jakebromberg/code-audit-pipeline/internal/cli.Version=<tag>`.
- **archives**: tar.gz with `audit` binary, `LICENSE`, `README.md`.
- **checksums**: SHA256 alongside each archive.
- **brews**: one entry for the Homebrew tap at `jakebromberg/homebrew-tap` (separate repo, manually created before the first release). Formula installs the `audit` binary; no caveats.
- **release**: GitHub Releases with the standard goreleaser changelog (commits since last tag, grouped by conventional-commit prefix when present).

```yaml
version: 2

project_name: audit

builds:
  - id: audit
    main: ./cmd/audit
    binary: audit
    env:
      - CGO_ENABLED=0
    goos: [darwin, linux]
    goarch: [amd64, arm64]
    ldflags:
      - -s -w
      - -X github.com/jakebromberg/code-audit-pipeline/internal/cli.Version={{.Version}}

archives:
  - id: audit
    format: tar.gz
    name_template: >-
      audit_{{ .Version }}_{{ .Os }}_{{ .Arch }}
    files:
      - LICENSE
      - README.md

checksum:
  name_template: 'checksums.txt'

brews:
  - name: audit
    repository:
      owner: jakebromberg
      name: homebrew-tap
    homepage: https://github.com/jakebromberg/code-audit-pipeline
    description: Cross-cutting structural analysis of codebases.
    license: Anti-Capitalist-Software-License-1.4
    install: |
      bin.install "audit"

release:
  github:
    owner: jakebromberg
    name: code-audit-pipeline
  draft: false
  prerelease: auto
```

### Release workflow

`.github/workflows/release.yml`:

```yaml
name: release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
        with: { fetch-depth: 0 }
      - uses: actions/setup-go@v5
        with: { go-version: '1.24' }
      - run: cd <repo-root> && go generate ./...
      - uses: goreleaser/goreleaser-action@v6
        with: { version: latest, args: release --clean }
        env:
          # GITHUB_TOKEN is auto-provided by Actions and is enough to publish
          # the GitHub Release on this repo. HOMEBREW_TAP_GITHUB_TOKEN is a
          # user-provisioned fine-grained PAT scoped to push to the separate
          # jakebromberg/homebrew-tap repo; goreleaser uses it to update the
          # formula. Without it, the Brew step skips with a warning rather
          # than failing the release.
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          HOMEBREW_TAP_GITHUB_TOKEN: ${{ secrets.HOMEBREW_TAP_GITHUB_TOKEN }}
```

`HOMEBREW_TAP_GITHUB_TOKEN` is a fine-grained PAT scoped to push to `jakebromberg/homebrew-tap`. Documented in CONTRIBUTING.md (added in this PR if absent) so the repo owner can rotate it.

`go install` works out of the box for any tagged version once `go.mod` is at the repo root (PR 3 placed it correctly). No additional config needed.

### v0 release tag

This PR's merge does NOT cut a release; releases happen via tag-push after merge. The first tag is `v0.1.0` (semver pre-1.0 to signal substrate-not-yet-stable).

### Why goreleaser rather than hand-rolled scripts

Goreleaser is the standard Go release tool; its Homebrew integration handles SHA256s, formula updates, and tap-repo PRs automatically. Hand-rolling would mean reproducing those mechanics for marginal control. The single config file is auditable.

## README rewrite

The current README documents the bash-recipe path: `gh pr list` → `jq classify` → `node extractor` → `jq query`. PR 3 made `audit extract` / `audit query` the primary surface; PR 4 makes `audit report` the deliverable. The rewrite reflects that.

### New structure

```
# code-audit-pipeline

<one-paragraph pitch>

## Install

  brew install jakebromberg/tap/audit       # macOS / Linux
  go install github.com/.../cmd/audit@latest # from source

## Quick start

  audit init --from <path/to/code-audit-pipeline>     # one-time, bootstraps extractors
  audit extract typescript --root /path/to/your/repo  # produces .audit/catalogs/type-catalog.json
  audit query exact-duplicates                         # interactive: prints clusters
  audit report                                         # writes .audit/reports/findings-<date>.md

## The principle

<unchanged — deterministic extraction, agentic synthesis>

## The deliverable, in two layers

<unchanged — input and output layers>

## Subcommands

<short table — extract, query, status, report, init>

## Catalog contract

<short pointer to docs/pipeline-contract.md; preserve the field table>

## Cluster queries

<unchanged table of queries with one-line descriptions>

## Adding a new extractor

<unchanged — pointers to docs/pipeline-contract.md>

## Hand-run mode

For development or one-off audits without installing the binary:

<the existing bash recipe — gh pr list, jq classify, etc. — preserved verbatim under this section>

## Provenance / Experiment series / Future directions / License

<all unchanged>
```

### What gets cut

Nothing is deleted. The bash recipe migrates from "Quick start" to "Hand-run mode". The Quick start becomes the binary path. Every existing section heading is preserved or absorbed.

### Why preserve hand-run mode rather than retire it

The bash recipe still works because the binary delegates to the same extractors and queries. Removing it would break a contributor flow (edit the .jq, rerun without rebuilding the binary), and the contract docs already point at the `.jq` files directly. Keeping the section as a sub-section costs ~30 lines and preserves the deterministic-substrate audit trail.

## File-by-file change list

```
.goreleaser.yaml                                            new (~60 lines)
.github/workflows/release.yml                               new (~30 lines)
README.md                                                   rewritten (~150-line net delta)
plans/pr4-renderers-report-init.md                          this plan (~700 lines)

cmd/audit/main.go                                           +20 lines (report, init dispatch + usage)

internal/render/render.go                                   new (~40 lines)
internal/render/cluster.go                                  new (~80 lines)
internal/render/pair.go                                     new (~110 lines)
internal/render/metric.go                                   new (~90 lines)
internal/render/render_test.go                              new (~120 lines)
internal/render/cluster_test.go                             new (~80 lines)
internal/render/pair_test.go                                new (~100 lines)
internal/render/metric_test.go                              new (~100 lines)

internal/cli/report.go                                      new (~220 lines)
internal/cli/report_test.go                                 new (~150 lines)

internal/cli/init.go                                        new (~210 lines)
internal/cli/init_test.go                                   new (~140 lines)

cmd/audit/audit_test.go                                     +60 lines (e2e: extract → report; init from repo root)
```

Estimated diff: ~700 lines code + 700 lines plan + ~150 lines README delta = ~1500 lines total.

**Generated artifacts are gitignored and do not enter the diff.** `cmd/audit/queries/` (~172KB after `go generate ./...` populates it from `pipeline/queries/`) is gitignored — PR 3 set up the rule in `.gitignore` line 20. Only the `pipeline/queries/*.jq` sources count toward diff size, and PR 4 doesn't modify them.

If the code+test diff (excluding the plan and README) approaches 1000 lines, split into PR 4a (render + report) and PR 4b (init + release + README). The split is a budget check, not a primary goal.

## Test strategy

### Renderers — fixture-driven

For each shape, fixtures live in `internal/render/testdata/`:

```
internal/render/testdata/
  cluster/
    exact-duplicates.jsonl
    function-duplicates-exact.jsonl
    cross-package-shadows.jsonl
  pair/
    near-duplicates.jsonl
    subset-pairs.jsonl
    test-prod-drift.jsonl
    function-duplicates-near.jsonl
  metric/
    shape-sig-frequency.jsonl
    touched-window-debt-summary.jsonl
```

Each `.jsonl` contains one or more representative rows captured from running the .jq against the test catalog under `pipeline/queries/_tests/`. Each fixture pairs with a golden `.md` file. Tests assert byte-equality between the rendered output and the golden.

Golden files are regenerated via a `-update` flag on the test binary; the regenerator is checked in alongside the tests. The same pattern as Go's `go test ./internal/render -update`.

### Report — integration test

In `cmd/audit/audit_test.go`:

```
1. Bootstrap a temp .audit/ with cached type-catalog.json from the existing test fixture.
2. Run `audit report --queries-dir <embedded-or-pipeline/queries> --root <tmp>`.
3. Assert exit code 0.
4. Read .audit/reports/findings-<today>.md.
5. Assert it contains "## exact-duplicates" and at least one cluster_id line.
6. Assert "## Skipped queries" lists queries with unsatisfied required args.
```

### Init — integration test

In `internal/cli/init_test.go`:

```
1. Create tmp source/ and tmp dest/. Populate source/ with a minimal extractors/typescript/manifest.toml and pipeline/queries/exact-duplicates.jq.
2. Run audit-init --from source --dest dest. Assert files copied.
3. Re-run. Assert no-op (state matches).
4. Modify one file under dest/. Re-run with --upgrade. Assert exit 1 and DIRTY warning.
5. Re-run with --force. Assert overwrite, exit 0.
6. Assert dest/.audit-init/state.json shape matches the documented schema.
7. Delete dest/.audit-init/state.json (simulating manual setup or a previous-version install). Re-run audit-init --upgrade. Assert exit 0, every destination file is reported as NEW, and a fresh state file is written. This exercises the state-absent reconciliation path.
```

### CI wiring

The release workflow is gated by tag push; CI runs the existing `go test ./...` against PR commits and additionally `go vet`. No new jobs needed for PR 4; the release workflow only fires post-tag.

## Risks

- **Goreleaser tap dependency.** First release requires `jakebromberg/homebrew-tap` to exist and be writable by the workflow's PAT. Document this in CONTRIBUTING.md and verify the tap is created before tagging v0.1.0.
- **Renderer drift from .jq text mode.** The report's markdown intentionally diverges from each .jq's interactive text output. A user accustomed to the interactive output may be surprised by the report shape. Mitigation: report header preamble points at `audit query <name>` for the interactive form.
- **Metric renderer nested-cluster recursion.** Only one production query (`touched-window-debt-summary`) currently nests. If a future query nests differently (e.g., nests pairs instead of clusters), the recursion needs an arm. Acceptable: when that query lands, add the arm.
- **`audit init` source path requirement.** Until release-tarball fetching lands, every install needs `audit init --from <local path>`. Document prominently in README; a brewed binary user without a checked-out repo can't bootstrap. Mitigation: ship the queries embedded (PR 3 already does this), so the binary works for cluster queries on day one — only the extractors require `init`.

## Review-plan loop

Submit this plan via `/review-plan plans/pr4-renderers-report-init.md` before implementation begins. Iterate on feedback until approval. Implement; commit; create issue; rebase against origin/main; create PR with `Closes #N`.

The PR description should link this plan and ADR-0003 / ADR-0006 / ADR-0007. The pre-PR review hook will check action pins (already at v6/v5/v5 per the PR 3 fix) and any new `-X ldflags` paths.
