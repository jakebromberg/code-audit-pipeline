# PR 2 — Full front-matter on queries + `manifest.toml` on extractors

## Parent

Tracker: #177 (Audit binary implementation). Previous PR: #180 (cluster envelope, merged). Source ADRs: 0002 (hybrid registration), 0005 (Go binary + gojq), 0006 (bundling + discovery).

## Scope

Substrate-prep pass over the registration surface the future Go binary will consume:

1. **Every `.jq` file under `pipeline/queries/`** — **26 runnable queries** + `_canonical.jq` library (excluded; not a runnable query) — gets a complete `#! key: value` front-matter block at the top.
2. **Each extractor directory** (`extractors/typescript/`, `extractors/swift/`, `extractors/file-hashes/`) gets a `manifest.toml` declaring extractor identity, CLI shape, and which catalog kind(s) it produces.

No runtime behavior changes for the 24 queries that already have `#! shape:` from PR 1. Two queries (`dead-code.jq`, `public-api-leaks.jq`) landed *after* PR 1 (#132, #133) and ship without the `#! shape:` line or the `members: [...]` envelope wrap. PR 2 backports both for those two files, applying the same "wrap single-decl rows into `members: [{...}]` of length 1" convention PR 1 used for `orphan-infer-model.jq` / `generic-convention-bound.jq`. This is a tightly-scoped envelope correction, not a new ADR.

Naked `jq` invocations remain unaffected for all 26 queries after PR 2 — `#!` lines are comments to jq. `manifest.toml` is read by the future binary; the extractors themselves are unchanged.

The gojq compatibility verification (tracker step 3) and `#! engine: jq` opt-out wiring are **deferred** — neither lands in this PR.

## Front-matter grammar (per ADR-0002)

Single-line `#! key: value` headers at the top of each `.jq`. The line is a comment to jq (starts with `#`) and a registration directive to the audit binary (recognized by the `#!` prefix). Keys land in this PR:

| Key | Cardinality | Purpose | Example |
|---|---|---|---|
| `query` | 1 | Stable identifier — matches `query:` field on emitted JSONL rows; used as the `audit query <name>` arg. | `query: exact-duplicates` |
| `shape` | 1 or 2 (comma-sep) | Cluster envelope shape (`cluster`/`pair`/`metric`). Already landed in PR 1; left in place — no edits this PR. | `shape: cluster` |
| `catalog` | 1 or N (comma-sep) | Catalog kind(s) this query consumes. The **first** entry is the positional `catalog.json` arg jq sees on stdin/argv; **subsequent** entries are `--slurpfile <name> <path>` mounts (variable name derived from the catalog kind). Drives `audit query` extractor-discovery: the binary verifies every named catalog kind exists under `.audit/` before invoking, and wires slurpfiles in declaration order. | `catalog: type-catalog` or `catalog: function-catalog, type-catalog` |
| `arg` | 0..N | `--argjson` / `--arg` flags the query requires. Each line has the form `arg: <name> <type> <default-or-required>`. `<type>` is `number` / `string` / `json`. `<default-or-required>` is either a literal default value or the keyword `required`. | `arg: threshold number 0.7` |
| `env` | 0..N | Environment-variable knobs. Form: `env: <NAME> <type> <default-or-empty>`. | `env: PACKAGE string ""` |
| `formats` | 1 | Comma-separated list of supported `OUTPUT_FORMAT` values. Always at minimum `text,jsonl` for the queries that have JSONL mode; `text` only for ones that don't. | `formats: text, jsonl` |
| `desc` | 1 | One-line description (≤ 100 chars). Surfaces in `audit query --help` listing. | `desc: Cluster types with identical shape_sig` |
| `version` | 0..1 | Front-matter grammar version. Default `1` when absent; explicit `1` permitted but not required. | `version: 1` |

Header position: all `#!` lines together, immediately under the existing prose-comment header. Order is fixed (`query`, `shape`, `catalog`, `arg*`, `env*`, `formats`, `desc`, optional `version`). Multi-line values are not supported — repeat the key. Empty / missing values for optional keys: omit the line entirely.

`#! version` is intentionally omitted from every query in this PR (default 1). Including it on every file adds 25 lines of churn for zero benefit — the grammar version exists so a future v2 grammar can detect old files; the absent-means-1 default is already part of the spec.

Two grammar choices worth flagging during plan review:

- **`arg:` triplet form** vs. a JSON-ish embedded form. Triplet is `arg: <name> <type> <default-or-required>`. Easier to hand-edit and grep; the binary parser is a 4-token whitespace split. Embedding JSON in `#!` lines fights both jq's `#` comment grammar and the contributor-readability goal.
- **`catalog:` plurality.** Most queries consume one catalog kind. Three queries consume two: `dead-code` reads type-catalog + references-graph (slurpfile `$refs`); `cross-catalog-name-collisions` reads two type-catalogs (slurpfiles `$left`/`$right`, called via `jq -n` — no positional input); `public-api-leaks` reads function-catalog + type-catalog (slurpfile `$types`). Comma-separated list preserves order — the first entry is the positional catalog the query reads via `.entries[]`, trailing entries are `--slurpfile` mounts. The exception is `cross-catalog-name-collisions`: both entries are slurpfiles (the `null`-input form), and the binary recognizes the pattern by the `jq -n` invocation form documented in the file header. PR 2 records the catalogs in declaration order matching each query's `Run:` line; the binary parser in PR 3 owns the wiring logic.

## Per-query mapping (24 queries)

Authority for each row: the prose-comment header already on the file. The mapping below is dense by design so a reviewer can scan it without opening each `.jq`.

### Cluster-shape (11)

| File | `query` | `catalog` | `arg` | `env` | `formats` | `desc` |
|---|---|---|---|---|---|---|
| `exact-duplicates.jq` | `exact-duplicates` | `type-catalog` | — | — | `text, jsonl` | Cluster types whose `shape_sig` is identical (byte-equal field+type set). |
| `name-collisions.jq` | `name-collisions` | `type-catalog` | — | — | `text, jsonl` | Same name declared in multiple packages — first-pass shadow signal. |
| `cross-package-shadows.jq` | `cross-package-shadows` | `type-catalog` | — | — | `text, jsonl` | Main-package names that also exist in shared — likely should be imports. |
| `cross-package-shadows-any.jq` | `cross-package-shadows-any` | `type-catalog` | — | — | `text, jsonl` | Symmetric N-package shadow detector for codebases without a canonical shared. |
| `generic-arity-drift.jq` | `generic-arity-drift` | `type-catalog` | — | — | `text, jsonl` | Same name with differing generic-parameter arity (`Repository<T>` vs `Repository<T,K>`). |
| `cross-catalog-name-collisions.jq` | `cross-catalog-name-collisions` | `type-catalog, type-catalog` | — | `env: LEFT_LABEL string "left"`, `env: RIGHT_LABEL string "right"` | `text, jsonl` | Type names that appear in BOTH a left- and a right-catalog. |
| `default-impl-candidates.jq` | `default-impl-candidates` | `function-catalog` | `arg: min_conformers number required` | — | `text, jsonl` | Function-body clusters across ≥ N types — protocol-extension default candidates. |
| `orphan-infer-model.jq` | `orphan-infer-model` | `type-catalog` | — | `env: INCLUDE_GENERATED string ""` | `text, jsonl` | Drizzle tables with no `InferSelect/InferInsert` consumer in the catalog. |
| `generic-convention-bound.jq` | `generic-convention-bound` | `type-catalog` | — | `env: EXTRA_BUILTINS string ""` | `text, jsonl` | Decls whose field types reference unbound `T`-style identifiers. |
| `dead-code.jq` ⚠ | `dead-code` | `type-catalog, references-graph` | — | — | `text, jsonl` | Exported, non-generated decls with zero resolved incoming references. |
| `public-api-leaks.jq` ⚠ | `public-api-leaks` | `function-catalog, type-catalog` | — | — | `text, jsonl` | Exported functions whose param/return types reference a non-exported same-package type. |

⚠ = also needs the PR-1 envelope migration:
1. Add `#! shape: cluster` to the header alongside the new front-matter keys.
2. Add `shape: "cluster"` to each emitted row.
3. Wrap each row's per-decl payload into `members: [{...}]` of length 1.
4. Add a short `Envelope:` prose comment to the file-level documentation header, matching the convention `orphan-infer-model.jq` and `generic-convention-bound.jq` adopted in PR 1 (e.g., `# Envelope: shape "cluster", members[] length 1 (one decl per orphan).`).
5. For any integration-test assertion that reads `.name` or other top-level fields on these queries' JSONL output, update it to read `.members[0].name`. Both files are exercised in `test_queries_integration.sh`.

### Pair-shape (10)

| File | `query` | `catalog` | `arg` | `env` | `formats` | `desc` |
|---|---|---|---|---|---|---|
| `near-duplicates.jq` | `near-duplicates` | `type-catalog` | `arg: threshold number required` | — | `text, jsonl` | Type pairs whose field-name sets have Jaccard ≥ threshold but ≠ 1. |
| `near-duplicates-any.jq` | `near-duplicates-any` | `type-catalog` | `arg: threshold number required` | — | `text, jsonl` | Symmetric N-package near-duplicate detector. |
| `subset-pairs.jq` | `subset-pairs` | `type-catalog` | — | — | `text, jsonl` | Asymmetric pairs (A ⊂ B) — candidate composition / extraction lift. |
| `cross-package-shape-near-duplicates.jq` | `cross-package-shape-near-duplicates` | `type-catalog` | `arg: threshold number required` | — | `text, jsonl` | Re-typed contract: main vs shared shape-similar but name-different pairs. |
| `cross-package-shape-near-duplicates-any.jq` | `cross-package-shape-near-duplicates-any` | `type-catalog` | `arg: threshold number required` | — | `text, jsonl` | Symmetric N-package re-typed contract detector. |
| `test-prod-drift.jq` | `test-prod-drift` | `type-catalog` | `arg: threshold number required` | — | `text, jsonl` | Near-duplicate pairs with XOR on `is_test` — fixture drift signal. |
| `generic-function-candidates.jq` | `generic-function-candidates` | `function-catalog` | `arg: threshold number required`, `arg: max_subs number required` | — | `text, jsonl` | Function pairs whose bodies differ only by a small identifier-substitution set. |
| `generic-struct-candidates.jq` | `generic-struct-candidates` | `type-catalog` | `arg: max_slot_diffs number required` | — | `text, jsonl` | Type pairs whose member-name sets match exactly but type strings differ at ≤ N slots. |
| `pat-candidates.jq` | `pat-candidates` | `type-catalog` | `arg: max_slot_diffs number required` | — | `text, jsonl` | Protocol-with-associated-type lift candidates. |
| `protocol-inheritance-candidates.jq` | `protocol-inheritance-candidates` | `type-catalog` | `arg: min_overlap number required` | — | `text, jsonl` | Sibling-with-missing-parent: protocols in the same package sharing ≥ N member names. |

### Metric-shape (3)

| File | `query` | `catalog` | `arg` | `env` | `formats` | `desc` |
|---|---|---|---|---|---|---|
| `migration-progress.jq` | `migration-progress` | `type-catalog` | `arg: old_sig string required`, `arg: new_sig string required`, `arg: label string required` | `env: PACKAGE string ""`, `env: KIND_PREFIX string ""`, `env: INCLUDE_GENERATED string ""` | `text, jsonl` | % migrated from one shape to another; list stragglers touched in window. |
| `shape-sig-frequency.jq` | `shape-sig-frequency` | `type-catalog` | — | `env: PACKAGE string ""`, `env: KIND_PREFIX string ""`, `env: INCLUDE_GENERATED string ""`, `env: MIN_COUNT string "2"`, `env: SAMPLE_SIZE string "3"` | `text, jsonl` | shape_sig values by frequency — discovery helper for migration-progress. |
| `touched-window-debt-summary.jq` | `touched-window-debt-summary` | `type-catalog` | — | `env: THRESHOLD string "0.7"`, `env: ONLY_TOUCHED string ""` | `text, jsonl` | PR-time meta-summary: clusters intersecting the touched-in-window set. |

### Dual-shape (2) — already declare `shape: cluster, pair` from PR 1

| File | `query` | `catalog` | `arg` | `env` | `formats` | `desc` |
|---|---|---|---|---|---|---|
| `function-duplicates.jq` | `function-duplicates` | `function-catalog` | `arg: threshold number required` | — | `text, jsonl` | Function-body duplicates — exact (cluster) and near (pair) sections. |
| `file-duplicates.jq` | `file-duplicates` | `file-hashes` | — | — | `text, jsonl` | Files with identical content — raw and whitespace-normalized sections. |

Total: 26 queries get front-matter (11 cluster + 10 pair + 3 metric + 2 dual). `_canonical.jq` (library, never invoked standalone) gets no `#!` lines. The two ⚠-flagged queries (`dead-code.jq`, `public-api-leaks.jq`) additionally undergo the small per-decl-to-members envelope migration described above.

## `manifest.toml` schema (per ADR-0002)

Each extractor directory gets one `manifest.toml` at its root. Schema:

```toml
schema_version = 1

[extractor]
name = "typescript"
language = "typescript"
version = "0.5.0"
description = "TypeScript AST extractor (typescript npm package); emits type and function catalogs."

# How to invoke. The binary substitutes {root}, {shared}, {touched}, {output},
# and other placeholders from its run context. Each [[command]] entry produces
# one catalog kind. Multi-catalog extractors (TypeScript, Swift) declare
# multiple [[command]] entries.

[[command]]
catalog = "type-catalog"
output_file = "type-catalog.json"
# Required: the always-present invocation. Tokens are joined with single spaces
# at exec time; placeholders are substituted.
invocation = ["node", "type-catalog.mjs", "--root", "{root}", "--output", "{output}"]
# Optional flags appended only when their activation condition is true.
# `when` values the binary knows about: shared_set, touched_set,
# references_enabled, min_body_lines_set. Adding a new condition is a one-line
# entry in the binary's condition registry (PR 3).
optional_args = [
  { flag = "--shared", placeholder = "{shared}", when = "shared_set" },
  { flag = "--touched", placeholder = "{touched}", when = "touched_set" },
  { flag = "--emit-references-graph", placeholder = "{references_output}", when = "references_enabled" },
]
# Sibling artifacts the command emits in addition to its primary `output_file`.
# Each entry registers the artifact under the named catalog kind so downstream
# queries declaring `catalog: type-catalog, references-graph` can locate it.
sibling_outputs = [
  { catalog = "references-graph", file = "references.json", when = "references_enabled" },
]

[[command]]
catalog = "function-catalog"
output_file = "function-catalog.json"
invocation = ["node", "function-catalog.mjs", "--root", "{root}", "--output", "{output}"]
optional_args = [
  { flag = "--shared", placeholder = "{shared}", when = "shared_set" },
  { flag = "--touched", placeholder = "{touched}", when = "touched_set" },
  { flag = "--min-body-lines", placeholder = "{min_body_lines}", when = "min_body_lines_set" },
]

[runtime]
# Hard prereqs the binary checks before invoking. Names match the binary's
# detector registry (PR 3). Failure mode: clear error pointing the user at the
# extractor's README install steps.
requires = ["node >= 18"]
setup_hint = "Run `npm install` in extractors/typescript/ (once per clone)."
```

Three manifests to author:

1. `extractors/typescript/manifest.toml` — `[extractor].name = "typescript"`, two `[[command]]` entries (`type-catalog`, `function-catalog`), `requires = ["node >= 18"]`.
2. `extractors/swift/manifest.toml` — `[extractor].name = "swift"`, three `[[command]]` entries (`type-catalog`, `function-catalog`, `package-graph`), `requires = ["swift >= 6.0", "macOS >= 13"]`. Note the **dev-mode** `swift run swift-catalog <subcommand>` invocation form: `invocation = ["swift", "run", "swift-catalog", "type", "--root", "{root}", "--output", "{output}"]`. A short inline TOML comment immediately above each `invocation` line will note "Dev-mode invocation; release-path migration to a built artifact is deferred — see PR 3." Production binary will exec the built artifact under `.build/release/swift-catalog`; the binary skeleton in PR 3 owns the `swift build`-vs-`swift run` selection.
3. `extractors/file-hashes/manifest.toml` — `[extractor].name = "file-hashes"`, one `[[command]]` entry (`file-hashes`), no `requires` (uses Node stdlib only).

Three manifest schema choices worth flagging:

- **`optional_args` as TOML inline tables** vs. a flat list. Inline tables let each optional flag declare its activation condition (`when = "shared_set"`). Flat list (`optional_args = ["--shared {shared}"]`) is shorter but pushes activation logic into the binary, where it'd need a parallel registry. The TOML inline form keeps each extractor's contract self-describing.
- **`output_file` per command** — names the file the extractor writes under `.audit/catalogs/`. Required because the binary needs a stable filename for `meta.json` `catalogs[<kind>].path`. The extractor's actual `--output` arg gets substituted with this path (relative to `.audit/`).
- **`sibling_outputs` for co-emitted artifacts** — declares files the command writes in addition to its primary `output_file`, registering each under its own catalog kind. Required so the binary can serve queries declaring `catalog: type-catalog, references-graph` (e.g., `dead-code.jq`) without inventing a parallel "sometimes-companion-catalog" registry. The condition mirrors the `optional_args` flag that activates the emission (e.g., `when = "references_enabled"` for `--emit-references-graph`). Treating `references-graph` as a separate `[[command]]` was the rejected alternative — it'd force the binary to model "type-catalog and references-graph co-extracted via one process invocation" via implicit coupling.

`cross-catalog-name-collisions.jq` poses a different multi-catalog pattern: the binary must invoke jq twice (or re-use a catalog from one repo and a snapshot of another). PR 2's manifest does not need to express that — cross-catalog invocation is the binary's responsibility, not the extractor's, and the query's `catalog: type-catalog, type-catalog` declaration is read by the `audit query` subcommand to know that two catalog inputs are required from the user (via `--left-catalog` / `--right-catalog` flags) rather than wired from the local `.audit/`.

## Implementation steps

1. Add `#! query: <name>` and the other front-matter keys to each of the 26 queries in alphabetical order. One commit per logical group (cluster / pair / metric / dual-shape) keeps the diff scannable; 4 commits total for the query pass. The pair-shape commit will be the largest (~10 files × 5-7 lines + a few that need new arg lines) but remains scannable since each file's diff is a contiguous header block. No internal sub-grouping is needed; keeping all 10 pairs in one commit preserves the shape-based mental model.
2. Embed the envelope backport for `dead-code.jq` and `public-api-leaks.jq` in the same cluster-shape commit so reviewers see the full picture for each file at once (front-matter + envelope migration colocated).
3. Author the three `manifest.toml` files. One commit.
4. Update `docs/pipeline-contract.md` — add a "Front-matter grammar" subsection under the catalog-schema docs cross-linking to ADR-0002, listing the key set, and pointing at one canonical query (`exact-duplicates.jq`) as the worked example.
5. No `manifest.toml` parser, no `#!` parser ships in this PR — both live in PR 3 (binary skeleton). PR 2 lands the *content* the parsers will read.

## Testing

The PR is mechanical metadata. Validation in this PR is limited to:

- **Naked-jq invariant.** Every query still runs under system `jq` exactly as before. The integration test suite at `pipeline/queries/_tests/test_queries_integration.sh` (106 tests, all green after PR 1) covers this. Re-run and confirm green. For the two ⚠ queries (`dead-code.jq`, `public-api-leaks.jq`) the envelope migration adds new test obligations — extend the suite by one assertion per file (the JSONL row has `shape: "cluster"`, `members[0].name == "<expected>"`) using the same fixture they already exercise. ~10 new assertion lines.
- **TOML well-formedness.** Each `manifest.toml` parses cleanly. Validate with `python3 -c 'import tomllib; print(tomllib.loads(open(p, "rb").read()))'` (`tomllib` ships in stdlib on Python ≥ 3.11) for each of the three files. The check goes into a one-off CI script; not a permanent test target yet.
- **Front-matter well-formedness.** A short shell check, executed as a one-off in this PR's CI step, asserts four invariants over every `.jq` under `pipeline/queries/` except `_canonical.jq`:
  1. A `#! query:` line exists.
  2. The `query:` value is unique across files.
  3. A `#! shape:` line exists, and its value is one of `cluster` / `pair` / `metric` (or comma-separated combinations for the two dual-shape files).
  4. Every `arg: <name> ...` declared in the header has a matching `--argjson <name>` or `--arg <name>` token in either the `Run:` documentation block or the query body. (Catches typos like `arg: thresshold` paired with `--argjson threshold` in the run line.) Symmetric check the other direction (every documented `--argjson` has an `arg:` line) catches dropped declarations.
  5. Every `env: <NAME> ...` declared in the header is referenced somewhere in the file as `$ENV.<NAME>` or `env.<NAME>` (or the file's prose-header explicitly documents it as a knob). Strict grep — false-positive rate is zero because envvars all use uppercase identifiers.

  ~50-line awk/grep pass. Runs alongside the integration suite. Promoted to a permanent test target in PR 3 when the binary's parser arrives (the binary will run the same checks at registration time).

Out of scope for this PR's tests:
- The binary's parser (lands in PR 3).
- gojq compatibility verification (tracker step 3, separate task).
- End-to-end manifest-driven extraction (PR 3, when the binary subprocess-invokes extractors).
- Semantic validation of `arg: <name> <type> <default>` defaults against the query's runtime behavior (e.g., does declaring `threshold number 0.7` match the query's actual default fallback? Not all queries even have one — most are `required`). PR 3's parser can lift this check once it can dry-run a query.

## Risks & open questions

- **`arg:` triplet form locks in defaulting syntax.** If a future arg needs a complex default (e.g., a JSON object), the third token can't express it. Mitigation: future-grammar version (`#! version: 2`) introduces an extended form; the v1 form covers every existing query.
- **`catalog:` order is load-bearing.** First entry is positional, trailing are slurp-mounts. The convention is documented but not enforced syntactically — a contributor could swap them and the binary would mis-route. PR 3's parser should error on mismatch (e.g., a `--slurpfile` declared first). Recorded as a follow-up for the binary skeleton.
- **`manifest.toml` invocation strings duplicate per-extractor README install hints.** Drift risk between manifest `[runtime].setup_hint` and README. Resolved by making the manifest authoritative — PR 4's README rewrite removes install hints from per-extractor READMEs and points at `audit init` instead.
- **Swift extractor invocation in dev vs. release.** Dev mode is `swift run swift-catalog`; release will be a built binary path. PR 2 commits the dev-mode invocation; PR 3 (or a follow-up) lifts the production path into `manifest.toml`'s `invocation` or a parallel `release_invocation` key. Not a blocker — the dev path works for both `audit extract --queries-dir .` from a contributor checkout and the `audit init`-bootstrapped state.

## Hard prerequisites

- PR 1 (#180, merged): cluster envelope + `#! shape:` already on every query. PR 2 builds on the same header position.

## Estimated complexity

~450 mechanical lines:
- 26 queries × ~5-7 `#!` lines each ≈ 150 lines
- Envelope backport for `dead-code.jq` + `public-api-leaks.jq` (2 files × ~6 source lines, ~5 test lines) ≈ 25 lines
- 3 `manifest.toml` files × ~30-45 lines each ≈ 120 lines
- `docs/pipeline-contract.md` front-matter section ≈ 80 lines
- Integration-test re-run + well-formedness checks ≈ 75 lines

Single PR, well under the 1000-line target. Independently reviewable: every change is metadata or a tightly-scoped envelope correction; rolling back is a `git revert` with zero downstream impact.
