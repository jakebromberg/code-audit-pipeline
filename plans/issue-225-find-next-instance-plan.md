# Issue #225 — `audit find-next-instance`: turn each closed PR into a micro-audit

## Parent

Tracker: #226 ("Discovery agenda: mining what already exists"). #225 is the first granular sub-issue of direction #5 in `docs/future-directions.md`.

Source ADRs: 0004 (router architecture — binary owns dispatch), 0005 (Go binary), 0006 (bundling + discovery).

## Motivation (verbatim from #225)

Each closed refactor PR is a template. The diff captures both the pattern that was wrong and the maintainer's chosen fix. The same pattern often appears in other parts of the codebase that weren't touched. A query that takes a PR as input and surfaces other call sites matching its *before* shape converts each merged refactor into a micro-audit that ships in seconds.

The PR has already passed maintainer review, so the pattern is known-good. The query inherits that confidence.

## Scope

A new top-level subcommand `audit find-next-instance` that:

1. Fetches a closed PR's diff via `gh pr diff <N> --repo <OWNER/REPO>`.
2. Parses the unified diff into per-file removed/added chunks.
3. Classifies each chunk as `function-body`, `type-shape`, or `convention-swap` (per-chunk, not per-PR — a single PR can carry several kinds).
4. Joins the *before*-side patterns against the cached `.audit/` catalogs and emits a ranked list of candidate file:line matches.

Aligns with the project's identity (cross-cutting structural analysis): the PR diff is the *pattern*, the catalogs are the *index*, the result is a structured cluster list that a human (or LLM) consumes.

### Out of scope (this PR)

- **Token-level identifier normalization** (the `rename locals to v1, v2, …` step described in #225). Done correctly it requires a language-aware AST pass — Swift via SwiftSyntax, TypeScript via the existing ts-morph harness. Tracked as a follow-up; v1 ships with line-level normalization (the same normalization the function-catalog already applies to `body_lines`: comment-strip, whitespace-collapse, trim, blank-drop, dedupe + sort). Recall is good enough on first inspection because the function-catalog already pre-sorts `body_lines`, so "removed lines are a subset of some catalog body's `body_lines`" is a meaningful join.
- **Convention-swap matching** beyond a stub. The grammar is "lines that look exactly like this, except for one substring" — that brushes against the linter non-goal. v1 detects the chunk-shape but emits a deferral note for it; full implementation tracked separately if useful.
- **Semantic understanding of *why* the PR was made** (LLM-layered enhancement). The query treats the diff as a pattern, not as a fix.
- **Filtering tests / generated code**: leans on the existing `is_test` / `generated` flags on catalog rows. No new filtering logic.
- **Cross-repo audits**: assumes the cached `.audit/` catalogs and the PR diff describe the same checkout. Fetching arbitrary remote PRs and joining against a local catalog is a different feature.

## CLI surface

```
audit find-next-instance --pr <N> [--repo <owner/repo>] [--diff <path>]
                         [--kind function-body|type-shape|all]
                         [--min-match-lines N] [--min-jaccard F]
                         [--format text|jsonl]
                         [--root <path>]
```

- `--pr <N>` (required unless `--diff` is given) — the PR number to fetch via `gh pr diff`.
- `--repo <owner/repo>` — optional. When absent, derive from `gh repo view --json nameWithOwner -q .nameWithOwner` of the audited repo's root. Errors loudly if neither is resolvable.
- `--diff <path>` — escape hatch for offline use (and tests): read the unified diff from a file instead of fetching. Mutually exclusive with `--pr`/`--repo` for fetching, but `--pr` may still be passed to populate the output metadata.
- `--kind` — restrict to one classifier. Default `all`.
- `--min-match-lines N` — minimum number of removed-block lines that must match a candidate body. Default 3 (mirrors `--min-body-lines` on the function-catalog).
- `--min-jaccard F` — minimum Jaccard score (removed-line set ∩ candidate body_lines / union). Default 0.6.
- `--format text|jsonl` — text by default; JSONL for the cluster envelope (see Output).
- `--root <path>` — audit root (defaults to cwd). Used to find `.audit/` cache.

Exit code: 0 on success (even when no matches found — empty output is a valid signal); non-zero on diff-fetch / parse / catalog-load failure.

## Catalog-shape dependencies (citing `docs/pipeline-contract.md`)

- **`function-catalog`**: relies on `body_hash`, `body_lines`, `body_line_count`, `name`, `kind`, `package`, `file`, `line` (pipeline-contract.md §"Function catalog"). `body_lines` is **already sorted, deduped, and comment-stripped** by the extractor (§"Body normalization"), so the Go-side normalizer only needs to reproduce that on the diff's removed lines — not on the catalog side.
- **`type-catalog`**: relies on `fields_structured[].name`, `name`, `kind`, `package`, `file`, `line` (pipeline-contract.md §"V7 §6.1: `fields_structured`"). Falls back to splitting `fields[]` on `:` (taking the prefix before `?`) when `fields_structured` is absent — keeps the matcher honest against extractors that haven't shipped V7 §6.1 yet.
- **Schema-version gate**: the catalog's top-level `schema_version` is read from the wrapper; the matcher refuses to operate on anything other than `"1.1"` (the only currently-emitted version per pipeline-contract.md §"Schema versioning and back-compat"). Failing loudly is preferable to silently relying on field shapes that may have moved.

## Normalization-spec contract

The function-catalog extractors (Swift via SwiftSyntax, TypeScript via ts-morph) normalize each function body's lines into the `body_lines` array — comment-strip, whitespace-collapse, trim, blank-drop, dedupe, sort. This algorithm is the **load-bearing join** between extractor output and diff input for `find-next-instance`. If extractor normalization drifts from the binary's normalizer, every match silently degrades.

V1 ownership:

- **Authoritative spec**: a top-of-file doc comment in `internal/diffmatch/normalize.go` enumerates each step with examples, and points at the function-catalog extractor source files (`extractors/typescript/function-catalog.mjs`, `extractors/swift/Sources/.../function-catalog.swift`) as the cross-language references. The spec is provisional v1 — if a third language extractor is added, the spec graduates to `docs/normalization-contract.md` and gets cited by every implementation.
- **Parity test**: `internal/diffmatch/normalize_parity_test.go`. Tagged `//go:build parity` (off by default to avoid making the unit-test suite depend on the Node / Swift toolchains). When run, it invokes the TypeScript function-catalog extractor against a tiny fixture, captures `body_lines`, runs the original source through the Go normalizer, and asserts byte-equality. The Swift parity test is gated on `command -v swift` and skips when absent.
- **CI trigger**: the parity test runs in CI under a dedicated `parity` job that has Node and Swift installed. Local `go test ./...` skips it by default. Failure surfaces as a clear "Go normalizer drifted from extractor X" message.
- **Versioning**: `internal/diffmatch.NormalizationVersion = "1"`. Embedded in any cache-eligible output and bumped if either side's spec changes — so downstream consumers can detect drift without reading source.

This contract is what makes the deferred "identifier-rename normalization" follow-up tractable: when it lands, both sides will bump `NormalizationVersion` together and the parity test will catch any divergence.

## Algorithm

### Phase 1 — Acquire diff

- If `--diff <path>` is set: read it.
- Else: shell out to `gh pr diff <N> --repo <owner/repo>` and capture stdout. Fail loudly on non-zero exit. (`gh` is a precondition; errors mention how to install.)

### Phase 2 — Parse unified diff

Walk the diff and emit a sequence of per-file chunks:

```go
type FileDiff struct {
    Path     string   // "a/path" form from "+++ b/<path>"
    Hunks    []Hunk
}
type Hunk struct {
    OldStart, OldLines int
    NewStart, NewLines int
    Removed []string   // lines with leading "-" stripped, no trailing newline
    Added   []string   // lines with leading "+" stripped
    Context []string   // surrounding context (no leading marker)
}
```

Parser uses `bufio.Scanner`; no regex except for the `@@ -A,B +C,D @@` header. Standard, well-trodden territory — no external dep. The `--- a/foo` / `+++ b/foo` header pair gives the file path.

### Phase 3 — Classify per hunk

A hunk's classification is independent per hunk. Rules in priority order (first match wins):

1. **function-body** — the hunk has ≥ `--min-match-lines` removed lines AND the surrounding context indicates a function body. Detection: the hunk header's `@@ … @@ <context-suffix>` line (when present) typically names the enclosing function; failing that, the hunk lives entirely inside a single function-catalog entry whose `body_lines` would contain (a superset of) the removed lines. Use the latter as the definitive test — it doesn't depend on git's hunk-header heuristic.
2. **type-shape** — the hunk's removed lines parse as field declarations (Swift `var x: T`, TS `x: T;`, etc.) and live inside a type-catalog entry's location. Detection: file matches a type-catalog row, removed-line range overlaps `[line, line + field_count]` window. Removed lines are parsed into a removed-field name set.
3. **convention-swap** (stub only in v1) — short hunk (≤ 3 removed, ≤ 3 added) with substring-replacement character. Emit a `kind=convention-swap, deferred=true` placeholder row so the operator sees the chunk wasn't dropped silently.

Hunks that match no classifier are emitted as `kind=unclassified, deferred=true` (single-line summary in text mode; JSONL row with `shape: metric`).

### Phase 4 — Match against catalogs

#### function-body

Inputs:
- Removed lines, normalized per the [Normalization-spec contract](#normalization-spec-contract) above.
- Function-catalog: loaded via the same path `audit query` uses — `auditdir.Open(absRoot, Version).CatalogPath("function-catalog")` with `--catalog <path>` override. The CLI surfaces missing-catalog errors with the same message convention as `audit query`: `audit: catalog "function-catalog" not cached under .audit/ — run `audit extract` or pass --catalog <path>`. (We do **not** reuse `wireCatalogs` directly because that function is shaped around front-matter-driven jq queries; instead the find-next-instance CLI calls `auditdir.Cache.CatalogPath` directly. The error string and exit code are kept identical so the operator gets a consistent failure mode.)

For each function-catalog entry with `body_hash != null`:

- `removed_set` ⊆ `body_lines` test (multiset semantics not needed because `body_lines` is already deduped and sorted): all removed lines appear in body_lines.
- If true: emit a candidate with `match_kind=function-body`, `match_score = removed_set ∩ body_lines / removed_set ∪ body_lines` (Jaccard), filtered by `--min-jaccard`.

Edge cases:
- The function the PR *modified* will appear as a self-match. Filter it out by `(file, line)` matching the diff's source location.
- Multiple matches in the same function-catalog entry collapse to one row (the body is the unit).

#### type-shape

Inputs:
- Removed-field name set (from Phase 3 parsing).
- Type-catalog: cached read.

For each type-catalog entry with `fields_structured != null`:

- Compute `entry_field_names = {f.name for f in fields_structured}`.
- If `removed_field_names ⊆ entry_field_names`, emit a candidate with `match_kind=type-shape`, `match_score = removed_field_names ∩ entry_field_names / removed_field_names ∪ entry_field_names`.

Same self-match filter on (file, line).

#### convention-swap

v1 stub: emit one deferral row per unclassified-but-shaped-like-swap chunk. Document the design space in the row's `notes` field (e.g., `"would replace '.cornerRadius(8)' with '.clipShape(.rect(cornerRadius: 8))' across N files; deferred per #225 scope"`).

### Phase 5 — Rank and emit

- Rank candidates by `(match_kind priority, -match_score, package, file, line)`. Priority: `function-body` > `type-shape` > `convention-swap` > `unclassified`.
- Apply `--min-jaccard` for the score-bearing kinds.
- Emit in the chosen format.

## Output schema

### Text mode (default)

Human-readable, mirrors the `function-duplicates.jq` text rendering for consistency:

```
=== find-next-instance: PR #208 — Move setUpAnalytics call to init ===

[function-body] 92% — Shared/Analytics/Sources/Analytics/Bootstrap.swift:14:setUpAnalytics
    matched lines: 4 of 5 removed, body has 6 normalized lines
    cid=find-next-instance:wxyc-ios-64#208__Analytics:Shared/.../Bootstrap.swift:14:setUpAnalytics

[type-shape]   75% — AppServices:Shared/AppServices/Sources/AppServices/PlaybackSession.swift:31:PlaybackSession
    removed fields {playlist, currentIndex} both present
    cid=find-next-instance:wxyc-ios-64#208__AppServices:Shared/.../PlaybackSession.swift:31:PlaybackSession

[deferred: convention-swap] WXYC/iOS/Views/PlayerView.swift hunk@142..145
    would replace '.cornerRadius(8)' → '.clipShape(.rect(cornerRadius: 8))'
```

### JSONL mode

One row per candidate. Each row conforms to the `pair` envelope per `docs/pipeline-contract.md`. The renderer (`internal/render/pair.go`) calls `renderMember(left)` and `renderMember(right)`, which expects each side to carry `{name, kind, package, file, line}` — so `left` and `right` are **catalog-member-shaped**, not PR-metadata-shaped. PR coordinates ride as top-level companion fields, mirroring how `subset-pairs` and `function-duplicates` already structure pair rows.

```jsonc
{
  "cluster_id": "find-next-instance:Analytics:Shared/Analytics/Sources/Analytics/Bootstrap.swift:14:setUpAnalytics__AppServices:Shared/AppServices/Sources/AppServices/Bootstrap.swift:8:bootstrap",
  "query": "find-next-instance",
  "shape": "pair",
  "match_kind": "function-body",
  "match_score": 0.92,
  "left": {
    // PR-source catalog member (resolved by looking up the diff's source
    // (file, line) against the function-/type-catalog). Always catalog-shaped.
    "name": "setUpAnalytics",
    "kind": "function",
    "package": "Analytics",
    "file": "Shared/Analytics/Sources/Analytics/Bootstrap.swift",
    "line": 14
  },
  "right": {
    // Candidate catalog member.
    "name": "bootstrap",
    "kind": "function",
    "package": "AppServices",
    "file": "Shared/AppServices/Sources/AppServices/Bootstrap.swift",
    "line": 8
  },
  "pr_number": 208,
  "pr_repo": "wxyc/wxyc-ios-64",
  "pr_hunk_old_start": 47,
  "pr_hunk_old_lines": 5,
  "intersection": 4,
  "union": 5,
  "removed_line_count": 5
}
```

If the diff's source location can't be resolved to a catalog member (e.g., file deleted in the PR, or extractor doesn't cover that file kind), the row degrades to `shape: "metric"` with `pr_*` fields and a `notes` carrying the reason — preserving the signal that the chunk had matches without forcing a malformed `pair` row through `renderMember`.

Deferral / unclassified rows also use `shape: "metric"` with `notes` carrying the deferral reason.

`cluster_id` directed: `<PR-source-loc>__<candidate-loc>` (mirrors `subset-pairs`' directed convention). Both sides use the standard `package:file:line:name` location key per `_canonical.jq`'s `loc_key`. Sorting would lose the PR-is-the-template meaning.

## Implementation

### Layout

```
internal/
├── diffparse/          # NEW. Unified-diff parser. Stdlib only.
│   ├── parser.go
│   └── parser_test.go
├── diffmatch/          # NEW. Body normalization + candidate matching.
│   ├── normalize.go    # mirrors function-catalog body_lines normalization
│   ├── normalize_test.go
│   ├── match.go        # subset / Jaccard / shape-field set ops
│   └── match_test.go
├── ghclient/           # NEW. Thin shell-out to `gh pr diff`. Mockable.
│   ├── client.go
│   └── client_test.go
└── cli/
    ├── findnextinstance.go         # NEW. Wires diff fetch → parse → classify → match → render.
    └── findnextinstance_test.go    # NEW. Integration tests with a recorded diff fixture.
cmd/audit/
└── main.go             # dispatch case "find-next-instance"
```

### Dispatch wiring (`cmd/audit/main.go`)

```go
case "find-next-instance":
    os.Exit(cli.FindNextInstance(ctx, args, stdout))
```

Add the line to the help text in `usage()`.

### Tests

Three test layers:

1. **diffparse unit tests** — fixture diffs (one-hunk, multi-hunk, multi-file, binary, rename), assert parsed structure. Include the malformed diffs (`@@` header without context suffix, missing `+++ b/` header, mixed CRLF).
2. **diffmatch unit tests** — fixture catalog rows + fixture diff chunks; assert match scores, subset filter, self-match exclusion.
3. **cli integration test** — `--diff <path>` mode, fixture diff + fixture function-catalog + fixture type-catalog, assert both JSONL and text output. (Same pattern as `TestQueryWithExplicitCatalog`.)

A small recorded `gh pr diff <N>` capture (200–400 lines) lives in `internal/cli/testdata/`. No live `gh` calls in CI.

### Acceptance criteria

1. `audit find-next-instance --diff testdata/pr208.diff --catalog ...` produces the expected JSONL on the test fixture.
2. Function-body matches respect the same `--min-body-lines` semantics the function-catalog already uses.
3. Type-shape matches handle the Swift `var foo: Bar` / `let foo: Bar` removed-line pattern AND the TS `foo: Bar` / `foo?: Bar` pattern.
4. Self-matches (the PR's own edited site) are excluded.
5. `--format jsonl` rows pass the existing envelope contract: `cluster_id` unique, `shape ∈ {pair, metric}`, `query == "find-next-instance"`. `pair` rows carry catalog-shaped `left{name,kind,package,file,line}` and `right{...}`; PR coords ride as top-level `pr_*` companion fields. Verified by piping output through `internal/render/pair.Pair` in a smoke test.
6. Missing catalog (`audit find-next-instance` run before `audit extract`) → same error message and exit code as the equivalent `audit query` failure.
7. Catalog `schema_version != "1.1"` → loud error with the version it saw and expected.
8. `gh` not on PATH → clear error referencing install instructions.
9. PR # that doesn't exist or repo with no auth → clear error surfacing `gh`'s stderr verbatim.
10. The `parity` build-tagged test (`go test -tags=parity ./internal/diffmatch/...`) passes against the bundled TS extractor on a 3-file fixture.

## Risks / open questions

- **Normalization drift**: replicating the body_lines normalization in Go risks divergence from the JS/Swift extractors. Mitigation: a parity test that runs the Swift extractor against a 3-file fixture, captures the resulting `body_lines`, runs the same fixture's text through the Go normalizer, and asserts byte-equality. If the test ever fails, the spec moved — bring the Go side in line.
- **Identifier normalization deferred**: without it, two functions that differ only by local-variable names won't cluster. This is the known limitation. Document on the subcommand's help text and on the JSONL row's `notes` (e.g., `"v1: line-level normalization only; T-rename clustering forthcoming"`).
- **Convention-swap stub**: the case the issue called "linter-adjacent." Risk is the stub stays a stub forever. Mitigation: file a follow-up issue when this PR merges, gated on observing real demand (we expect mining the PR history to surface whether convention-swap matches are the common case or the long tail).
- **Self-match filter**: matching the diff's source location against the catalog's `(file, line)` is exact; a PR that touches a function and renames it would dodge the filter. Acceptable v1 fragility — the next-instance is then a real next-instance, just one in the "fixed by this same PR" sense.

## Implementation safety pins (from second review pass)

Two clarifications captured here so the implementation doesn't drift from the existing patterns:

1. **Catalog-missing error string is borrowed verbatim from `internal/cli/common.go:158–180`** (the `wireCatalogs` cache path). The find-next-instance CLI extracts a small helper `loadCatalog(cache, kind)` so the message and exit code stay identical across `audit query` and `audit find-next-instance`. We don't reuse `wireCatalogs` itself because it's shaped around front-matter-driven jq queries, but we reuse the failure path.
2. **JSONL emission guards `shape: "pair"` integrity at the source.** The serializer in `findnextinstance.go` only emits `shape: "pair"` when both `left` and `right` resolve to catalog members (i.e., both have `name`, `kind`, `package`, `file`, `line` populated). Any other configuration emits `shape: "metric"` with `pr_*` companion fields and a `notes` reason — so a malformed row can never reach `internal/render/pair.Pair`, which would panic on a nil `left`. Unit-tested by feeding the serializer a row with an unresolvable PR-source and asserting it produces `metric` (never `pair`).

## Branching

Worktree already established at `.claude/worktrees/feat-find-next-instance` on branch `worktree-feat-find-next-instance`. PR will rename to `feat/find-next-instance` (or push the worktree branch verbatim — either works given the repo's branch-naming flexibility).

## Provenance

Issue #225, opened 2026-05-30 as the first sub-issue of #226 ("Discovery agenda"). Plan revised 2026-05-30 in response to a HIGH finding on JSONL `pair` envelope shape (pair rendering requires catalog-shaped `left`/`right`, not PR-metadata-shaped) and MEDIUM findings on catalog discovery + schema-version gating.
