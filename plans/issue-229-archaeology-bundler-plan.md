# Implementation plan: `audit archaeology` (issue #229, under #226)

## Goal

Add `audit archaeology`, a deterministic substrate step that produces a per-audit context blob downstream consumers (lens agents, the skeptic-with-evidence pass) load as pre-context. Output is a single `archaeology.json` under the audit directory, with raw per-PR diffs spilled to sibling files so the JSON stays parseable.

The bundle answers six questions the structural catalog can't:

1. What does the team think the open problems are? (open issues)
2. What did the team just change, and why? (recent merged PR bodies + diffs)
3. Where has the team annotated "this is wrong, fix later"? (TODO / FIXME / HACK)
4. Where has the team annotated "this is going away"? (deprecation markers)
5. What design constraints has the team written down? (ADRs)
6. What working agreements has the team encoded? (CLAUDE.md text)

This is the second item under #226 and a hard prerequisite for the lens-agent runner and the skeptic-with-evidence pass — both consume the archaeology bundle as pre-loaded context.

## Non-goals (v1)

- LLM summarization of any source. The blob is raw substrate, not pre-digested. Summarization is the lens / skeptic step, not the bundler.
- Per-line git blame for TODO age (file-mtime via `git log -1 --format=%ci -- <file>` is sufficient for v1).
- Issue / PR comment threads. Body + metadata only.
- Cross-repo PR discovery (e.g., issues / PRs in dependency repos).
- Secret redaction in body text. The user runs this on their own repo and opts in; we do not try to redact.
- Closed-issue mining ("closed as duplicate of …" — that's the *issue archaeology* checklist item under #226, separate scope).
- Output formats other than the single JSON blob (no JSONL stream in v1; no per-source sibling artifacts).

## CLI

```
audit archaeology --root <path> [--output <path>] [--window-days N]
                  [--repo <owner/repo>] [--max-prs N] [--max-issues N]
                  [--no-prs] [--no-issues] [--no-todos]
                  [--no-deprecations] [--no-adrs] [--no-rule-text]
                  [--no-pr-diffs]
```

| Flag | Default | Meaning |
|---|---|---|
| `--root` | required | Audit root. |
| `--output` | `<root>/.audit/archaeology.json` | Bundle output. Per-PR diffs always written under `dirname(output)/archaeology/prs/<N>.diff`. |
| `--window-days` | `90` | Recency window for issues and merged PRs. Filter is on `updated_at` for issues and `merged_at` for PRs. |
| `--repo` | derived via `gh repo view --json nameWithOwner -q .nameWithOwner` inside `--root` | `owner/repo` to query gh against. |
| `--max-prs` | `50` | Cap on merged PRs to fetch. |
| `--max-issues` | `100` | Cap on open issues to fetch. |
| `--no-prs` / `--no-issues` / `--no-todos` / `--no-deprecations` / `--no-adrs` / `--no-rule-text` | off | Skip a source. Useful for offline runs and partial regeneration. |
| `--no-pr-diffs` | off | Skip the per-PR `gh pr diff` calls but **keep** the PR metadata. `recent_prs[]` is still populated; each entry's `diff_path` is `null`. Differs from `--no-prs`, which omits the section entirely. |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Bundle written successfully. |
| `1` | Runtime failure: a source-gather step failed, disk write failed, or `gh` returned non-zero on a required source. |
| `2` | Usage error: missing or malformed flags. |
| `3` | `gh` not on PATH and one of the gh-dependent sources is enabled. |

Sources that legitimately produce no rows (no ADRs in tree, no deprecation markers, no TODO matches) emit empty arrays and log a single line to stderr — not an error.

### Stderr contract

Mirrors the rest of the binary: one human-readable summary line per source on success, plus a trailing total. Example:

```
audit archaeology: open_issues  =  37 (gh)
audit archaeology: recent_prs   =  18 (gh, window=90d)
audit archaeology: todos        = 142 (file-walk)
audit archaeology: deprecations =   6 (file-walk)
audit archaeology: adrs         =   8 (docs/adr/)
audit archaeology: rule_text    =   4 (CLAUDE.md walk)
audit archaeology: wrote bundle to .audit/archaeology.json (98.4 KiB) + 18 diff(s)
```

## Output schema

Single `archaeology.json` (path defaults to `<root>/.audit/archaeology.json`).

```jsonc
{
  "schema_version": "1",
  "generated_at": "2026-05-30T12:00:00Z",            // RFC3339 UTC; redacted from golden tests
  "window": {
    "days": 90,
    "since": "2026-03-01T00:00:00Z"                  // generated_at - window_days, UTC
  },
  "repo": "jakebromberg/code-audit-pipeline",        // null if --no-issues and --no-prs both set
  "root": "/abs/path/to/audit/root",                  // absolute
  "sources": {                                        // per-source provenance
    "open_issues":  { "tool": "gh",         "ok": true, "count": 37, "skipped": false, "error": null },
    "recent_prs":   { "tool": "gh",         "ok": true, "count": 18, "skipped": false, "error": null },
    "todos":        { "tool": "file-walk",  "ok": true, "count": 142,"skipped": false, "error": null },
    "deprecations": { "tool": "file-walk",  "ok": true, "count": 6,  "skipped": false, "error": null },
    "adrs":         { "tool": "file-read",  "ok": true, "count": 8,  "skipped": false, "error": null },
    "rule_text":    { "tool": "file-read",  "ok": true, "count": 4,  "skipped": false, "error": null }
  },
  "open_issues": [
    {
      "number": 226,
      "title": "Research agenda: discovering what the substrate should learn to find",
      "labels": ["research", "tracker"],
      "created_at": "2026-05-30T12:00:00Z",
      "updated_at": "2026-05-30T12:30:00Z",
      "body": "..."                                   // raw, not truncated
    }
  ],
  "recent_prs": [
    {
      "number": 228,
      "title": "...",
      "merged_at": "2026-05-30T11:45:00Z",
      "files": ["cmd/audit/main.go", "internal/cli/findnextinstance.go"],
      "body": "...",
      "diff_path": "archaeology/prs/228.diff",        // relative to dirname(output); null when --no-pr-diffs
      "diff_size_bytes": 12345                         // null when diff_path is null
    }
  ],
  "todos": [
    {
      "file": "internal/extractor/swift.go",
      "line": 142,
      "marker": "TODO",                                // TODO | FIXME | HACK | XXX
      "text": "extend AST-based XCTestCase detection",
      "age_days": 312                                  // file-mtime-derived; -1 if git log fails or file untracked
    }
  ],
  "deprecations": [
    {
      "file": "Shared/Core/Sources/Core/AsyncMessage.swift",
      "line": 87,
      "kind": "annotation",                            // annotation | comment
      "symbol": "AsyncNotificationMessage",            // best-effort; "" when not extractable
      "message": "use MainActorNotificationMessage"     // verbatim trailing text after the marker
    }
  ],
  "adrs": [
    {
      "file": "docs/adr/0001-canonical-cluster-envelope.md",
      "title": "Canonical cluster envelope",
      "status": "accepted",                            // accepted | proposed | superseded | deprecated | unknown
      "body": "..."                                    // full markdown body, comment-free
    }
  ],
  "rule_text": [
    {
      "file": "CLAUDE.md",
      "scope": "repo",                                  // "repo" or "package:<segment>"
      "body": "..."                                    // raw markdown
    },
    {
      "file": "Shared/Core/CLAUDE.md",
      "scope": "package:Core",
      "body": "..."
    }
  ]
}
```

### Field semantics

- `generated_at` is the moment of the run, RFC3339 UTC. Replaced by `"<REDACTED-FOR-GOLDEN>"` in the golden test fixture comparator.
- `window.since = generated_at - window_days`. Both filters (`updated_at >= since` for issues, `merged_at >= since` for PRs) live in the CLI so the substrate doesn't have to re-derive them.
- `sources` carries per-source `{tool, ok, count, skipped, error}` so consumers can tell "this source ran and found nothing" apart from "this source was skipped" apart from "this source failed." When `ok: false`, the corresponding section is `[]` and `error` carries the gh / file-system error message.
- Determinism: every array is sorted by a documented key (see source-rule sections). Two runs over the same input on the same day produce byte-identical output (excluding `generated_at`).

## Source rules

### 1. Open issues — `internal/archaeology/issues.go`

```
gh issue list --state open --repo <repo> --limit <max-issues> \
              --json number,title,labels,createdAt,updatedAt,body
```

- Filter to `updatedAt >= window.since`.
- Map `labels[].name` to a flat `string[]`.
- Sort by `(updated_at desc, number asc)` so the most-recently-touched issues sit at the top.
- v1 limit: gh's `--limit` already caps the page; we do not paginate further. If a repo has more than `max-issues` open issues matching the window, the oldest tail is dropped silently (stderr summary still reports the count).

### 2. Recent merged PRs — `internal/archaeology/prs.go`

```
gh pr list --state merged --repo <repo> --limit <max-prs> \
           --json number,title,mergedAt,files,body
```

- Filter to `mergedAt >= window.since`.
- `files` from gh is `[{path}]`; flatten to `string[]` of file paths.
- For each PR (unless `--no-pr-diffs`): `gh pr diff <N> --repo <repo>` (via the existing `ghclient.PRDiff`). Spill stdout to `dirname(output)/archaeology/prs/<N>.diff`. The diff body is intentionally not inlined into `archaeology.json` — diffs can be megabytes and inlining them would make the bundle unparseable in editors.
- `diff_size_bytes` is the byte length of the spilled file.
- Sort by `(merged_at desc, number asc)`.

### 3. TODO / FIXME / HACK — `internal/archaeology/todos.go`

- Walk the audit root, respecting the same dotdir-skip rules as the existing extractors: skip any directory beginning with `.` (`.git`, `.audit`, `.claude`, `.cursor`, `.idea`, `.next`, `.vscode`, `.svn`) plus `node_modules`, `dist`, `build`, `coverage`, `target`, `vendor`, `Pods`, `DerivedData`.
- Skip binary files: heuristic is "first 8 KiB contains a 0x00 byte → binary, skip."
- Match `TODO|FIXME|HACK|XXX` as **standalone tokens inside comment lines**. The token must be preceded by start-of-line or non-word characters and followed by `[:( \t]` or end-of-line. This avoids matching `TODOLIST` or `XXX_PASSWORD`.
- A comment line is one of: starts with `//`, starts with `#` (Python / shell / Ruby / TOML), starts with `--` (SQL / Haskell), starts with `/*` or `*` (block-comment continuation), starts with `<!--` (HTML / Markdown). Trailing same-line comments (`x = 1  // TODO foo`) also count — match on the marker appearing **after** one of those comment-introducer tokens within the line.
- `text` is the post-marker text up to end-of-line, stripped of the marker punctuation (`TODO:`, `TODO -`, `TODO(name)` — strip the punctuation, keep the message). For `TODO(name)`, the assignee is dropped; preserving it is a v2 (see issue-archaeology, the next checklist item).
- `age_days` derived once per file via `git log -1 --format=%ct -- <file>` (Unix timestamp of last commit touching the file). If the file is untracked or `git log` errors, `age_days = -1`. Per-line blame is explicitly v2.
- Sort by `(age_days desc, file asc, line asc)`. Stalest-first puts the long-festering markers at the top of the list.

### 4. Deprecation markers — `internal/archaeology/deprecations.go`

Heuristic scan; recall over precision for v1. Match any of these patterns on a single line:

| Language | Pattern | `kind` |
|---|---|---|
| Swift | `@available(*, deprecated, …)` / `@available(*, deprecated)` | `annotation` |
| Kotlin / Java | `@Deprecated` | `annotation` |
| C# | `[Obsolete]` / `[Obsolete(...)]` | `annotation` |
| TypeScript / JS | `@deprecated` inside a `/** … */` or `//` comment | `comment` |
| Python | `@deprecated` decorator, `warnings.warn(.*DeprecationWarning)` | `annotation` |
| All | `Deprecated:` / `DEPRECATED:` in a comment line | `comment` |

`symbol` is the identifier on the **next non-blank, non-comment line** after the marker — extracted via a small per-language token scrape (`func <Name>`, `class <Name>`, `let <Name>`, `var <Name>`, `def <Name>`, `function <Name>`, `interface <Name>`, `type <Name>`, `const <Name>`). When no symbol is extractable (e.g., the marker sits inside a doc-comment for a property already handled), `symbol = ""`. False negatives on `symbol` are acceptable in v1 — the file:line is the load-bearing field.

`message` is the trailing free-text inside the annotation, stripped of quotes and parens (`@available(*, deprecated, message: "use Foo")` → `"use Foo"`). Empty when none.

Sort by `(file asc, line asc)`.

### 5. ADRs — `internal/archaeology/adrs.go`

- If `<root>/docs/adr/` does not exist, source emits `[]` and stderr notes `adrs: directory not found (skipped)`.
- Otherwise walk `<root>/docs/adr/*.md`. For each file:
  - `title` = first H1 heading (line starting with `# `), or the filename stem if no H1.
  - `status` = case-insensitive match against `accepted`, `proposed`, `superseded`, `deprecated` inside the first 50 lines. Match strategies (any of):
    - Front-matter `status: <value>` (if file starts with `---` front-matter).
    - A line matching `^Status: <value>` (case-insensitive).
    - A line matching `^\*\*Status:?\*\* <value>` (bold inline).
  - Falls back to `unknown`.
  - `body` = the full markdown body verbatim, including the heading and status line. Comment stripping is intentionally NOT applied — ADR text often uses `<!-- … -->` to mark editorial notes that downstream consumers should see.
- Sort by `file asc`.

### 6. Rule text (`CLAUDE.md`) — `internal/archaeology/rules.go`

- Walk the audit root for every file basename `CLAUDE.md`. Respect the same dotdir-skip and built-dir-skip rules as the TODO walker.
- `scope` is `"repo"` for the root-level file (`<root>/CLAUDE.md`) and `"package:<segment>"` otherwise, where `<segment>` is the last path segment of the directory containing the `CLAUDE.md` (e.g., `Shared/Core/CLAUDE.md` → `package:Core`). This mirrors the package-naming convention the rest of the substrate uses.
- `body` is the file contents verbatim.
- Sort by `file asc`.

## Internal architecture

```
cmd/audit/main.go
  └─ switch case "archaeology": cli.Archaeology(ctx, args, stdout)

internal/cli/archaeology.go
  ├─ Archaeology(ctx, argv, stdout) int         // CLI entry, flag parsing, dispatch
  └─ flag handling, exit codes, stderr summary

internal/archaeology/
  ├─ bundle.go        // Bundle struct + Assemble(opts, sources) function
  ├─ issues.go        // OpenIssues(ctx, gh, repo, dir, since, limit) -> []Issue
  ├─ prs.go           // MergedPRs(ctx, gh, repo, dir, since, limit, fetchDiffs, diffDir) -> []PR
  ├─ todos.go         // ScanTODOs(root) -> []TODO
  ├─ deprecations.go  // ScanDeprecations(root) -> []Deprecation
  ├─ adrs.go          // ReadADRs(root) -> []ADR
  ├─ rules.go         // ReadRuleText(root) -> []RuleText
  ├─ walk.go          // shared dotdir-skip + binary-skip walker
  └─ types.go         // Bundle, SourceProvenance, Issue, PR, TODO, Deprecation, ADR, RuleText
```

`internal/ghclient/client.go` gains two methods (no breaking changes to the existing interface):

```go
// OpenIssues runs `gh issue list --state open --repo <repo> --limit <limit>`
// in `dir` and returns the raw JSON payload. Caller decodes.
func (c *Client) OpenIssues(ctx context.Context, dir, repo string, limit int) ([]byte, error)

// MergedPRs runs `gh pr list --state merged --repo <repo> --limit <limit>`
// in `dir` and returns the raw JSON payload. Caller decodes.
func (c *Client) MergedPRs(ctx context.Context, dir, repo string, limit int) ([]byte, error)
```

Both methods take the same `dir, repo, limit` shape as `PRDiff` so the test seam (the existing `Exec` field stub) stays uniform. `Exec` already accepts `dir`; assertions on the call's `dir` argument carry over from the existing `client_test.go` pattern.

### Why a separate `internal/archaeology/` package

- The per-source gatherers each have non-trivial logic and benefit from their own test file. Tucking them into `internal/cli/archaeology.go` would balloon a single file past 1500 lines.
- The package is consumed by exactly one CLI today; co-locating per-source code keeps `internal/cli/` focused on flag parsing and exit-code dispatch (the pattern already used by `extract.go`, `findnextinstance.go`, etc.).
- Tests can drive `internal/archaeology/*.go` directly without going through the CLI surface — much cleaner than the find-next-instance pattern which mixes CLI tests and gatherer tests in one file.

## Determinism contract (for the golden test)

The bundle must be byte-identical across runs with the same inputs, except for:

- `generated_at` — RFC3339 timestamp, replaced by a stable string in the golden comparator.
- `sources[*].count` and the array lengths — these reflect actual data, not run-to-run drift.
- `root` — absolute path; the golden comparator either pins it to a fixed value via the test harness, or asserts `root` is some absolute path and otherwise ignores it.

Every other field is deterministic by construction:

- Arrays are sorted by documented keys (see source-rule sections above).
- gh JSON payloads are decoded into Go structs and re-serialized; gh's own key ordering doesn't leak.
- File-walk results sort `file:line` ascending.
- `git log` is invoked with `-1 --format=%ct` (numeric Unix timestamp), which is stable per-file across runs.

## Testing strategy

### Unit tests (per source)

`internal/archaeology/issues_test.go`:
- Drive `OpenIssues` with a stub `ghclient` returning a canned `gh issue list --json` payload.
- Assert sorting, window filter (`updated_at < since` issues are excluded), label flattening.
- Assert that a gh failure surfaces as `SourceProvenance{ok: false, error: …}` rather than panicking.

`internal/archaeology/prs_test.go`:
- Mirror of issues. Additionally: assert per-PR diff spill paths are correct, `diff_size_bytes` matches the spilled file's size, `--no-pr-diffs` mode leaves `diff_path: null`.

`internal/archaeology/todos_test.go`:
- `testdata/archaeology/repo/` seeded with Go, Swift, Python, TypeScript, Markdown, and SQL fixtures containing TODO / FIXME / HACK / XXX in various comment forms.
- Assert match-only-in-comments (a code line `let x = "TODO bake bread"` does NOT match).
- Assert the standalone-token rule (`TODOLIST` does NOT match; `TODO:` does).
- Assert `age_days >= 0` for tracked files, `age_days == -1` for untracked.

`internal/archaeology/deprecations_test.go`:
- Per-language fixtures (Swift `@available`, TS `@deprecated`, Java `@Deprecated`, C# `[Obsolete]`, Python `@deprecated`, plain-comment `Deprecated:`).
- Assert `symbol` extraction across `func`, `class`, `let`, `var`, `def`.
- Assert no false positives on inline strings (`let msg = "Deprecated: use Foo"` does NOT match).

`internal/archaeology/adrs_test.go`:
- Fixtures: front-matter form, inline `Status:`, bold `**Status:**`, no-status (→ `unknown`).
- Empty `docs/adr/` directory → `[]` with stderr note.
- Missing `docs/adr/` directory → `[]` with stderr note (different error path).

`internal/archaeology/rules_test.go`:
- Root `CLAUDE.md` only → one row, `scope: "repo"`.
- Nested `Shared/Core/CLAUDE.md` → second row, `scope: "package:Core"`.
- Skip rule: `node_modules/foo/CLAUDE.md` (if any) does NOT appear.

### Integration test (bundle-level)

`internal/cli/archaeology_test.go`:
- Spin up a temporary directory mimicking a small repo (seeded `CLAUDE.md`, `docs/adr/0001.md`, a Go file with a TODO, a Swift file with `@available(*, deprecated)`).
- Stub `ghclient` to return canned issue / PR JSON.
- Run `cli.Archaeology(...)` end-to-end.
- Golden test: compare emitted `archaeology.json` against `testdata/archaeology/bundle.golden.json` after redacting `generated_at` and `root`.
- Smaller scoped tests: each `--no-*` flag actually skips its source (verify via `sources[*].skipped == true`).

### CI integration

A new shell-script test under `cmd/audit/audit_test.go` (or a sibling `archaeology_integration_test.go`) runs `audit archaeology --root <pipeline-repo-root> --no-prs --no-issues` (offline mode) and asserts:
- Exit code 0.
- `archaeology.json` exists and parses as JSON.
- `sources.open_issues.skipped == true`, `sources.recent_prs.skipped == true`.
- `sources.rule_text.count >= 1` (the repo's own `CLAUDE.md` is found).
- `sources.adrs.count >= 1` (the repo has `docs/adr/`).

Online integration against `gh` is **not** added to CI in v1 — it would require a GH token and rate-limit considerations. A documented manual smoke test (`audit archaeology --root . --max-prs 5 --max-issues 5`) covers the gh paths during development.

## Acceptance

- `audit archaeology --root <a-repo>` produces `<root>/.audit/archaeology.json` with all six sections populated (or `[]` when a section legitimately has no rows).
- Unit tests cover each source individually; bundle-level golden test passes.
- CI integration test runs against this repo and produces a non-empty bundle in offline mode.
- No regressions in existing CI (Go vet/test/build, jq integration, goreleaser check).
- `audit help` lists `archaeology` in its subcommand summary.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| `gh` rate-limit on large PR backlogs when `--max-prs` is high. | v1 caps default at 50; per-PR diff fetches sleep 100ms between calls (rate-limit-friendly without blowing run time). The `--no-prs` flag lets the user skip entirely. |
| `git log` invocations for TODO age add up on large repos. | One call per touched file, cached in a map. Worst case: `O(files-with-TODOs)`, which on a 100k-line repo is typically < 1000 files. |
| Deprecation marker false positives (e.g., `"DEPRECATED"` in a doc-comment example). | Documented in non-goals as v1 limitation. The CLI emits to stderr how many matches were found; downstream consumers can re-filter. |
| Binary-file detection heuristic (`0x00` in first 8 KiB) misses some binaries (UTF-16 text files, for example). | Acceptable — UTF-16 source is rare in audited repos. The walker errs on the side of scanning; mismatched encodings produce noise rows, not crashes. |
| Bundle size on large repos. | Per-PR diffs are spilled to sibling files. The bundle itself stays in the low MB even on repos with 1000+ TODOs. |
| Concurrent writes to the same `<root>/.audit/archaeology/` dir during testing. | Tests use `t.TempDir()`; production runs serialize on the `.audit/` lock that `auditdir.Open` already provides. |

## Resolved decisions (post-review)

1. **Schema version** — `schema_version: "1"`. Archaeology evolves independently of the catalog schema; downstream consumers (lens agent, skeptic pass) must treat the two as separate schema families.
2. **Diff-spill directory creation** — `internal/cli/archaeology.go` calls `os.MkdirAll(filepath.Join(dirname(output), "archaeology", "prs"), 0o755)` before invoking `MergedPRs`. The bundle assembler does not create directories.
3. **`sources` shape** — object keyed by source name. Easier to consume from jq (`.sources.todos.count`). Pivot to array if a future source needs an order-sensitive flag.
4. **TODO age fallback** — when `git log` fails on an untracked file, `age_days = -1`. mtime fallback rejected because it's meaningless for freshly-cloned repos.
5. **Diff-spill path inside the bundle** — `diff_path` is relative to `dirname(output)` (e.g., `archaeology/prs/228.diff`). Keeps the bundle portable across working directories.

## Sequencing inside the implementation

1. Land `internal/archaeology/types.go` + `walk.go` (shared infra) and `rules.go` (simplest source, no `gh` dependency). Tests for both.
2. `adrs.go` and `todos.go` (file-system only). Tests.
3. `deprecations.go`. Tests.
4. `internal/ghclient/client.go` extensions (`OpenIssues`, `MergedPRs`). Tests.
5. `issues.go` and `prs.go` (consume new ghclient methods). Tests.
6. `bundle.go` (assembly). Bundle-level test.
7. `internal/cli/archaeology.go` (CLI: flag parsing, `os.MkdirAll` for the diff-spill directory, source dispatch, exit codes). Integration test.
8. `cmd/audit/main.go` dispatch: add `case "archaeology": os.Exit(cli.Archaeology(ctx, args, stdout))` to the switch (mirroring the find-next-instance entry) and add a usage line to the help text. End-to-end CI integration test.
9. Local CI run, push, PR with `Closes #229`, gh run watch, merge.
