# code-audit-pipeline

A pipeline for cross-cutting structural analysis of codebases. AST extractors emit a canonical JSON catalog; `jq` queries cluster duplicates and surface drift; an optional agent step turns cluster output into refactor recommendations. Deterministic extraction, agentic synthesis.

## Language

### Substrate

**Catalog**:
The JSON document produced by an extractor — one record per declared structural unit (type, function, file). The unit of input to every query.
_Avoid_: index, dataset, output

**Catalog kind**:
The categorical type of a catalog: `type`, `function`, `file-hashes`. Determines which queries can consume it. One extractor directory can produce multiple kinds (the TS extractor produces both `type` and `function`).
_Avoid_: catalog type (ambiguous with the `type` kind), category

**Extractor**:
A language-specific program that walks a source tree and emits a catalog. Uses the host language's native AST library — `typescript` for TS, `SwiftSyntax` for Swift, `ast` for planned Python. Mandatory per the project's principle: never regex grep, always the compiler API.
_Avoid_: parser, indexer, analyzer

**Query**:
A `.jq` file that consumes a catalog and emits clusters, pairs, or a metric. The unit of analysis. Hand-runnable with naked `jq`; structured under the audit binary via front-matter.
_Avoid_: rule, check, lint

**Cluster**:
A query result row. May group N records (`shape: cluster`), pair two records (`shape: pair`), or report a scalar (`shape: metric`). Used as a generic noun for "query output row" even when the shape isn't strictly a group.
_Avoid_: group, finding (the latter overlaps with audit report output)

**Shape**:
The categorical kind of a query's output structure: `cluster` (N members), `pair` (left/right), `metric` (scalar + breakdown). Declared in front-matter as `#! shape:`. Determines which renderer the binary uses for the markdown report.
_Avoid_: type (ambiguous), result-kind

**Substrate**:
The deterministic layer of the pipeline: extractors + catalogs + queries + cluster envelopes. Everything below the optional agent synthesis step. Substrate changes are byte-reproducible; agent steps are not.
_Avoid_: foundation, core

**Cluster envelope**:
The canonical JSONL row shape every query emits, parameterized by `shape`. A `cluster`-shape row has `members: [...]`; a `pair`-shape row has `left` and `right`; a `metric`-shape row has the scalar and breakdown fields. The contract that the markdown renderer and the V7 agent layer both consume.

**Front-matter**:
The structured `#! key: value` header at the top of a `.jq` file. Declares `query`, `catalog`, `shape`, `arg`, `env`, `formats`, `desc`, and optionally `version` and `engine`. Parsed by the binary; ignored by naked `jq` (lines begin with `#`, jq's comment marker).

**Touched-in-window**:
A boolean flag on each catalog record indicating the source file was in the audit's `--touched` list. Drives the asterisk markers in cluster output and any "introduced this audit window" filtering.
_Avoid_: touched (ambiguous), recent

**Audit window**:
A PR-derived span — typically "merged in the last N weeks" — used to mark records as `touched_in_window`. Defined at extraction time; persists as flags on catalog records.

### Binary

**`.audit/`**:
The local cached state directory the binary writes into the user's repo. Contains `meta.json`, `catalogs/<kind>.json`, `reports/findings-<date>.md`. Auto-created on first `audit extract`; auto-added to the user's `.gitignore`.

**Provenance**:
The metadata recorded in `.audit/meta.json` about how each catalog was produced — the absolute root path, the extraction timestamp, the extractor version. Used by `audit status` to warn when the cwd no longer matches the catalog's origin (the "wrong repo" silent-wrong guard).

**`AUDIT_HOME`**:
Environment variable pointing at a queries-and-extractors source tree for installed (non-in-repo) use. Set by `audit init`. Second in the lookup-order chain.

**Lookup-order discovery**:
The precedence chain the binary uses to find queries and extractors: explicit flag → cwd-relative → `$AUDIT_HOME` → bundled (queries) or `~/.config/audit/` (extractors). First match wins. Surfaced by `audit status` so it's never invisible.

**Engine**:
The jq implementation used to evaluate a query. Default is `gojq`, embedded in the audit binary. A query may opt out via `#! engine: jq`, causing the binary to shell out to system `jq` for that query only.

## Flagged ambiguities

- **"Type"** is overloaded across three meanings: a TypeScript/Swift type declaration (a kind of catalog record), the `type` catalog kind (the categorical), and a flag's declared type in `manifest.toml` (`path`/`string`/`bool`). Disambiguate by context. When clarity matters, prefer "type record" / "catalog kind" / "flag type" respectively.

- **"Run"** was avoided as a verb on the binary. The verb is `audit report` (extract + every relevant query → findings.md), not `audit run`. The latter is too generic and would collide with future verbs (`audit ci`, `audit diff`).

## Example dialogue

> **Dev:** I'm getting weird output from `audit query near-duplicates`.
> **Maintainer:** What catalog kind do you have cached?
> **Dev:** I ran `audit extract ts-function`, so I have a function catalog.
> **Maintainer:** Right — `near-duplicates` is a type-catalog query. `function-duplicates` is the function-catalog one. Different catalog kinds, different shapes.
> **Dev:** How would I have known?
> **Maintainer:** `audit query --help` lists each query with its catalog kind. Or `audit status` — it shows which catalog kinds you have cached and which queries depend on each.
> **Dev:** What if I want both?
> **Maintainer:** Run `audit extract ts` and `audit extract ts-function` separately. They walk the source tree for different things.
> **Dev:** And `report`?
> **Maintainer:** `audit report` runs every query whose catalog kind is cached and whose required args are satisfied. Anything it skips shows up in the summary table with the reason. That's the audit window's main artifact.
> **Dev:** Why was the function-catalog query skipped in my report yesterday?
> **Maintainer:** Probably touched-in-window was empty — no PRs in the audit window touched any files. Or the function catalog wasn't extracted yet. `audit status` will tell you which.
