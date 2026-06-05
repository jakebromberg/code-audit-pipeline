# Plan — Schema v2: two-tier catalog ratification (closes #137)

## Status of the world

This PR stacks on top of the #141 PR (`plan-141-schema-1.2-symbol-id-fingerprint.md`). #141 lands the additive 1.2 bump (`symbol_id`, `fingerprint_v`, `generated_at`, `extractor.source_sha`). This PR lands the next bump — schema **v2** — which adds the convergent extensions both design notes recommend:

- `language` field on every entry (carried implicitly by every illustrative record in both design notes).
- `language_data.<lang>.*` extension namespace.
- `relations[]` typed-edge slot.
- `core_projection_complete: false` and `omitted_features[]` honesty markers.
- Cross-language `kind` values: `migration`, `sql-query`, `sql-external-reference`, `external-import`, plus the Swift-specific `type`, `interface`, `conformance`, `macro_definition`, `macro_application`, plus the Python-specific `pydantic-model`, `fastapi-route`, `fastapi-dependency`, `dataclass`, `enum`.

Per the version-bump rules introduced in #141 (PR 1), these are all *additive at the consumer level*: existing queries do not see new required fields, and `language_data.*` is opt-in. So in principle this would be a minor bump (1.3). However, issue #137 is explicit that the design notes converged on calling this **v2**, and the future polyglot world is materially different from the TS-shaped one. The contract section is reorganized around a "core projection" — a small cross-language required set — with language-specific extensions in `language_data.<lang>.*`. That reorganization, even if technically additive, is the kind of conceptual repositioning that justifies the major version label.

Coordination with Lane A (#217 + #222): Lane A's `conforms_to: string[]` is one specific case of v2's `relations[]` (a relation with `kind: "conforms_to"`). If Lane A lands first, this PR documents `relations[]` as the canonical, generic form and references Lane A's `conforms_to` as a per-entry shorthand that v2's `relations[] | select(.kind == "conforms_to")` subsumes. If this PR lands first, Lane A's PR rebases on v2 and decides whether to keep `conforms_to: string[]` as shorthand or only emit it via `relations[]`. Either order is workable; the plan does not block on Lane A.

Total fixture count: **17 illustrative records** across Python Files 1–7 and Swift Files 1–3 (some files yield more than one record — see Step 2's table).

## Scope

In:

- **Doc-heavy**: ratify the v2 contract in `docs/pipeline-contract.md`. New sections: core projection, `language_data.<lang>.*` namespace, `relations[]` slot, honesty markers, cross-language kinds.
- **Walk all 10 illustrative records** (Python Files 1–7 = 9 records; Swift Files 1–3 = 4 records; that's 13 records total counting the multi-record files). For each, confirm the draft schema accepts it without an undocumented field. Adjust the draft and re-walk if any record needs a new field.
- **Audit all 28 jq queries**: document per-query whether v2 runs unchanged or needs a documented refit. Implementation of refits is out of scope (the queries themselves keep working because the new fields are optional).
- **Add a fixture file** `docs/pipeline-contract-v2-fixtures.jsonl` (one JSON record per line) containing all 13 illustrative records. Land a small `pipeline/validate-v2-fixtures.mjs` (or extend `pipeline/validate-catalog.mjs` from PR 1) that parses every fixture line and confirms it satisfies the v2 core projection.
- **TS extractor additive update**: emit `language: "typescript"` on every record. Bump `SCHEMA_VERSION` to `"2"` (or `"2.0"`; pick one consistently — see decision below).
- **Embed regen**: `go generate ./...` and commit.

Out:

- Implementation of v2 refits for the cluster queries (the per-query "needs refit" items the audit will surface). Those are #116 follow-ups.
- Python or Swift extractor changes. The Swift extractor still emits a bare array (per #137's design-notes recommendation, the extractor changes land alongside the Swift/Python extractor PRs themselves). v2 is the contract; implementing it is per-extractor.
- A JSON Schema document (`docs/pipeline-contract.schema.json`). #137 explicitly defers this.

## Decision: `schema_version: "2"` vs `"2.0"`

The current envelope examples use string-major-minor (`"1.1"`, `"1.2"`). Picking `"2"` (no minor) for the v2 envelope would surprise consumers that string-parse the version. Picking `"2.0"` keeps the same string-shape across major bumps and parses uniformly under `/^\d+\.\d+$/`. **Pick `"2.0"`.** Document the convention in pipeline-contract.md alongside the version-bump rules from PR 1: "every schema_version is `MAJOR.MINOR` as a string." Update the `pipeline/validate-catalog.mjs` regex from `/^1\.\d+$/` to `/^[12]\.\d+$/` (or, more generally, `/^\d+\.\d+$/` with an explicit warn-on-unknown-major and refuse on missing — same pattern as the manifest parser, which accepts 1 and 2 explicitly).

## Implementation order

### Step 1 — Draft v2 contract in `docs/pipeline-contract.md`

Major restructure of the type-catalog section to lead with the core projection, then break out language-specific extension via `language_data.<lang>.*`, then the relation slot and honesty markers, then the cross-language kinds.

#### 1a. Core projection section

Add a new top-level section "Core projection (v2)" after the existing "Required fields" / "Required-when-applicable" sections. Content:

> Required on every record, regardless of language:
> - `name` (string)
> - `kind` (string; from the cross-language kind vocabulary below, or a language-specific extension following the prefix convention)
> - `package` (string)
> - `file` (string, relative to package root)
> - `line` (number, 1-indexed)
> - `language` (string; e.g., `"typescript"`, `"swift"`, `"python"`, `"rust"`, `"go"`, `"sql"`)
>
> Required-when-applicable (carried forward from v1; semantics unchanged):
> - `shape_sig` and `fields[]` for shape-of-named-members constructs.
> - `type_text` and `type_sig` for non-object type aliases.
>
> Optional carry-overs from v1: `exported`, `generated`, `touched_in_window`, `generics`, `infer_ref`, `db_table_name`, `fields_structured`, `extends`, `references`, `references_count`, `symbol_id`.
>
> Optional v2 additions:
> - `language_data` (object; keys are language names, values are language-specific extension namespaces).
> - `relations` (array of typed-edge objects; see "Relations slot" below).
> - `core_projection_complete` (boolean; default `true`).
> - `omitted_features` (array of strings; default `[]`).

#### 1b. `language_data.<lang>.*` namespace

New section. Content:

> The `language_data` object is keyed by language name. Each value is the language-specific extension namespace — fields whose meaning is only legible inside that language's idiom. A record can carry multiple language sub-namespaces (e.g., a Python `sql-query` record carries both `language_data.python.*` for composition info and `language_data.sql.*` for dialect info).
>
> Fields under `language_data.<lang>.*` are NOT part of the cross-language core projection. Queries that operate cross-language work against the core projection; queries that operate on language-specific structure pin to a language and read its sub-namespace.
>
> Examples are illustrative only — extractors are not required to populate every field. The list below names fields used in the v2 fixture set; new fields may be added by extractor authors following the contract's documented convention (see "Adding a new extractor").
>
> | Language | Field | Where seen (fixture file:line) |
> |---|---|---|
> | `swift` | `decl_kind`, `access`, `conformances[]`, `macro_applications[]`, `associated_types[]`, `inherited_protocols[]`, `member_isolation`, `is_retroactive`, `is_unchecked`, `context`, `roles[]`, `synthesized_member_names[]`, `synthesized_conformances[]`, `implementation_module`, `implementation_type` | Swift Files 1–3 |
> | `python` | `bases[]`, `base_alias`, `future_annotations`, `field_metadata`, `method`, `path`, `router_name`, `router_decl_file`, `router_decl_line`, `mount_file`, `mount_line`, `mount_prefix`, `router_prefix`, `decorator_path`, `request_model`, `response_model`, `dependencies[]`, `mount_dependencies[]`, `query_params[]`, `tags[]`, `composition`, `static_prefix`, `fragment_alternatives[]`, `execute_sites[]`, `loaded_from[]`, `transformations[]`, `execute_via`, `returns`, `depends_on[]`, `is_async`, `singleton`, `singleton_state_name`, `lifecycle_close`, `errors_raised[]`, `base`, `members[]`, `decorator`, `field_defaults`, `qualified_name`, `implementation_language`, `implementation_package`, `resolution`, `imported_as`, `migration_framework`, `revision`, `down_revision`, `upgrade_ops[]`, `guards[]` | Python Files 1–7 |
> | `sql` | `dialect`, `tables_read[]`, `tables_written[]`, `columns_selected[]`, `where_predicates[]`, `order_by[]`, `placeholder_count`, `placeholder_style` | Python File 3 Form A & B |
> | `rust` | `fn_signature`, `pyo3_attribute`, `registered_in` | Python File 6 Path 2 |
>
> Every field name above traces to a specific illustrative record in `docs/pipeline-contract-v2-fixtures.jsonl`. New fields require a corresponding illustrative record before they enter the table — the "speculation gate" enforces evidence-driven schema growth.
>
> Worked example (Python File 3 Form A — `_FLOWSHEET_SQL`):
>
> ```json
> {
>   "kind": "sql-query", "name": "_FLOWSHEET_SQL", "language": "python",
>   "package": "semantic-index", "file": "semantic_index/pg_source.py", "line": 57,
>   "language_data": {
>     "python": { "composition": "static-literal", "execute_sites": [{"function": "load_flowsheet_entries"}] },
>     "sql":    { "dialect": "postgresql", "tables_read": ["wxyc_schema.flowsheet"], "where_predicates": [{"left":"entry_type","op":"=","right":"'track'"}] }
>   }
> }
> ```
>
> Note that `language: "python"` is the *host* language (the SQL is composed by Python) and `language_data.sql.*` carries the dialect-specific shape — the two-tier schema doing its work.

#### 1c. Relations slot

New section. Content:

> `relations` is a flat array of typed-edge objects. Each edge has at minimum:
> - `kind` (string; relation type)
> - `target` (string; the related symbol's name, fully qualified when possible)
>
> Edges may carry additional kind-specific fields (e.g., `retroactive: true`, `unchecked: true` for conformances; `via_macro: "AnalyticsEvent"` for synthetic conformances derived from macro joins).
>
> Examples of `kind` values used in the v2 fixtures (open vocabulary — extractors may add new ones):
>
> | `kind` | Where seen |
> |---|---|
> | `extends` | Python File 2 (`LookupRequest extends _GeneratedLookupRequest`) |
> | `conforms_to` | Swift File 3 (`Notification conforms_to Sendable` retroactive); v2 generalization of Lane A's per-record `conforms_to: string[]` |
> | `applies_macro` | Swift File 1 (`FetchPlaylistEvent applies_macro AnalyticsEvent`) |
> | `mounts_router` | Python File 1 (`main.py mounts_router lookup_router with_prefix /api/v1`) |
> | `loads_sql_from` | Python File 3 Form C (Alembic migration loads external `.sql` files) |
> | `references_notification_name` | hypothetical wxyc-ios-64 #324 case (Lane B / #222 anchor) |
>
> Existing `extends: string[]` on type records remains as a v1 shorthand. v2 introduces `relations[]` as the canonical form. Queries can adopt either: `extends[]?` continues to work for the shorthand; `relations[] | select(.kind == "extends") | .target` for the canonical form. The cluster-query refits (#116) decide which form each query consumes.

#### 1d. Honesty markers

New section. Content:

> `core_projection_complete: false` and `omitted_features[]` mark records where the extractor knows it has lost fidelity vs. the source.
>
> Default `core_projection_complete: true` and `omitted_features: []` (both may be absent — absence implies completeness).
>
> Examples drawn from the v2 fixtures:
>
> - `["macro_expansion"]` — Swift File 1: a macro-applied struct whose synthesized members and conformances are not in the source AST.
> - `["inherited_fields"]` — Python File 2: a Pydantic subclass that declares only the additions; base-class fields live in another record reachable via `relations[] | select(.kind == "extends")`.
> - `["runtime_branch_choice", "dynamic_column_list"]` — Python File 3 Form B: an f-string SQL with conditional branches the AST cannot statically resolve.
> - `["sending_parameter_annotation", "self_type_resolution"]` — Swift File 3: a protocol whose member signatures carry Swift 6 isolation annotations the v2 schema does not yet model.
>
> Vocabulary is freeform strings. v2 does not impose a closed enum. If a future audit query demands controlled vocabulary, that's a v2.1 conversation.
>
> Existing cluster queries do not consult these fields; they are for downstream filters ("show me only rows where the catalog is honest about its losses") and for documentation/communication.

#### 1e. Cross-language kinds

New section. Document each `kind` that crosses languages: `migration`, `sql-query`, `sql-external-reference`, `external-import`. Each gets a one-line definition, a list of `language_data.<lang>.*` fields it typically carries, and a pointer to the illustrative fixture line.

Also document the language-specific `kind` extensions that don't cross languages:
- Swift: `type`, `interface`, `conformance`, `macro_definition`, `macro_application`.
- Python: `pydantic-model`, `fastapi-route`, `fastapi-dependency`, `dataclass`, `enum`.

Note that v1's TS-shaped kinds (`type-alias-*`, `zod-object`, `drizzle-table`, `import`) continue to work — they are TS-specific kinds following the same convention.

#### 1f. Bump every envelope example

Bump `schema_version: "1.2"` → `"2.0"` in every example block in the contract document. There are roughly four locations after PR 1's bumps land.

### Step 2 — Walk every illustrative record

For each record in `docs/python-extractor-design-notes.md` "Seven files, seven records" and `docs/swift-extractor-design-notes.md` "Three files, three records", check:

1. Does it have the v2 core projection (`kind`, `name`, `package`, `file`, `line`, `language`)?
2. Are its language-specific bits under `language_data.<lang>.*`?
3. If it carries cross-language bits (SQL extracted from Python), are those under `language_data.sql.*`?
4. Does it use `relations[]` correctly (or carry `extends[]` as the v1 shorthand)?
5. Does it use `core_projection_complete: false` / `omitted_features[]` where applicable?

Records to walk (extracted from the design notes):

| # | Source | Kind | Fixture line in JSONL |
|---|---|---|---|
| 1 | Python File 1 | `fastapi-route` | `handle_lookup` |
| 2 | Python File 2 (override) | `pydantic-model` | `LookupRequest` (lookup/models.py) |
| 3 | Python File 2 (codegen base) | `pydantic-model` | `LookupRequest` (generated/api_models.py) |
| 4 | Python File 3 Form A | `sql-query` | `_FLOWSHEET_SQL` |
| 5 | Python File 3 Form B | `sql-query` | `library.db._search_uncached:filtered-branch` |
| 6 | Python File 3 Form C | `sql-external-reference` | (anonymous, line 110) |
| 7 | Python File 4 | `fastapi-dependency` | `get_library_db` |
| 8 | Python File 5 (a) | `enum` | `SearchStrategyType` |
| 9 | Python File 5 (b) | `dataclass` | `SearchStrategy` |
| 10 | Python File 6 Path 1 | `external-import` | `to_match_form` (Python view) |
| 11 | Python File 6 Path 2 | `pyo3-function` | `to_match_form` (Rust view) |
| 12 | Python File 7 | `migration` | `0001_initial` |
| 13 | Swift File 1 (a) | `type` | `FetchPlaylistEvent` |
| 14 | Swift File 1 (b) | `macro_application` | `AnalyticsEvent → FetchPlaylistEvent` |
| 15 | Swift File 2 | `macro_definition` | `AnalyticsEvent` |
| 16 | Swift File 3 (a) | `interface` | `MainActorNotificationMessage` |
| 17 | Swift File 3 (b) | `conformance` | `Notification → Sendable` |

That's 17 distinct illustrative records (not 13 — I undercounted earlier). The fixture file will be 17 JSONL lines.

**KPI:** every one parses, every one populates the v2 core projection, every one places language-specific bits under `language_data.<lang>.*`. If any record needs an unspecified field, the draft is amended and the walk re-runs.

### Step 3 — Author `docs/pipeline-contract-v2-fixtures.jsonl`

One JSON record per line. The records are **hand-crafted illustrative examples derived from the design notes** — not real extractor output. They serve two purposes: (1) documentation for the next extractor author who reads them to learn the v2 shape; (2) regression input for the validator (`pipeline/validate-catalog.mjs`) to assert v2 acceptance.

A separate post-merge step (#138 Rust, #139 Go, #135 Python, #136 Swift follow-ups) validates real extractor output against the same validator. The fixture file does not replace per-extractor integration tests; it ratifies the cross-language contract that those tests will conform to.

Transform the JSONC records from the design notes by:

1. Stripping comments and trailing commas (JSONC → JSON).
2. Adding any missing core-projection fields (e.g., the Python File 6 Path 1 record needs `name`, `package`, `kind: "external-import"` per the cross-language vocabulary).
3. Adding `language` where missing (some illustrative records implicitly mean Python or Swift without saying so).
4. Validating with the extended `pipeline/validate-catalog.mjs` from Step 4.

Every fixture line is preceded by a `# source: <design-notes-file> §<section> File <n>` comment in the audit file (`docs/pipeline-contract-v2-query-audit.md` index column) so readers can trace it back. JSONL itself can't carry comments per line, but the file header can list the line→source mapping table.

The fixture file is the load-bearing evidence the v2 contract works. It is permanent — the next extractor author reads it to learn the shape.

### Step 4 — Validator extension

Extend `pipeline/validate-catalog.mjs` from PR 1 to:

- Accept `schema_version: "2.0"` in addition to the v1.x forms already accepted in PR 1 (`"1.0"`-bare-array, `"1.1"`, `"1.2"`).
- **Backward compatibility is explicit**: the validator continues to accept v1.0, v1.1, and v1.2 catalogs unchanged. v2.0-specific rules apply only when `schema_version == "2.0"`. A v1.2 catalog without `language` on its entries is still valid (the field is a v2 addition).
- When envelope is `2.0`, require `language` on every entry.
- When `language_data` is present (on any version), require it to be an object whose keys are language names (lowercase, no whitespace).
- When `relations` is present (on any version), require it to be an array; each entry has `kind` and `target` strings.
- `core_projection_complete` (when present) is a boolean.
- `omitted_features` (when present) is an array of strings.

Tests:

- `pipeline/queries/_tests/test_validate_catalog.sh` (extended from PR 1):
  - Each line of `docs/pipeline-contract-v2-fixtures.jsonl` validates clean.
  - A v2 catalog missing `language` on an entry → exit 1.
  - A v2 catalog with `relations[]` whose entry lacks `kind` → exit 1.
  - A v1.2 catalog without `language` continues to validate clean (backward-compat regression).
  - A v1.2 catalog that opportunistically uses `relations[]` validates clean (the `relations[]` shape is checked regardless of version, since extractors may emit it on v1.x as a forward-compat shim).

### Step 5 — TS extractor: emit `language: "typescript"` and bump to `2.0`

Edit `extractors/typescript/type-catalog.mjs`:

1. `const SCHEMA_VERSION = '2.0';`
2. Add `language: 'typescript'` to every entry record at construction time.

Mirror in `function-catalog.mjs` and `file-hashes.mjs`.

The v1.x `extends: string[]` field continues to be emitted on type records (Lane A may add `conforms_to: string[]` as a peer). The TS extractor does not need to emit `relations[]` in this PR — that's an additive extractor-side change for a follow-up. The v2 contract documents `relations[]` as the canonical form; existing extractors carrying `extends[]` (and Lane A's `conforms_to[]`) continue to be conformant.

### Step 6 — Audit the 28 cluster queries

Walk each `.jq` file in `pipeline/queries/` (28 files; the 29th is `_canonical.jq` library). For each, document one of:

- **Runs unchanged.** The query already filters on fields that v2 preserves (`shape_sig`, `fields`, `name`, `kind`, `package`, `file`, `line`).
- **Runs unchanged but with a documented gap.** The query operates on TS-shaped fields and will undercount polyglot catalogs until a refit (e.g., a query's kind whitelist is `interface`/`type-alias-*`/`zod-object` and would skip Python's `pydantic-model`).
- **Needs refit.** A field the query depends on changed semantics (none expected in v2 — additive only).

**Audit procedure** (repeatable; documented per query):

For each `.jq` file, run two passes:

1. Field-reference grep: `grep -E '\.(kind|extends|references|fields|shape_sig|type_text|type_sig|package|file|line|name|generated|exported|touched_in_window|is_test)' <query.jq>` — every match is a field the query depends on.
2. Kind-whitelist grep: `grep -E '(kind == "|select\(\.kind' <query.jq>` — every match flags a TS-shaped kind list that may undercount polyglot catalogs.

Conclude per query:
- If pass 1 only returns fields v2 carries forward unchanged AND pass 2 returns nothing language-specific → **runs unchanged**.
- If pass 1 is clean but pass 2 has a TS-shaped whitelist → **runs unchanged but with a documented gap** — refer to #116 for polyglot kind-list expansion.
- If pass 1 returns a field whose semantics v2 redefines → **needs refit** (none expected; flag for follow-up if observed).

Audit lives in a new file: `docs/pipeline-contract-v2-query-audit.md`. One row per query, four columns: query name, status, grep evidence (the matching lines or "no kind whitelist"), follow-up ticket (or `#116` placeholder when refit is needed). This is the deliverable goal #2 of #137.

### Step 7 — Embed regen

After all canonical-source edits land, `go generate ./...` to refresh `cmd/code-audit/queries/` and `cmd/code-audit/extractors/`. Commit the diff.

This PR touches:
- TS extractor source files (forces extractors embed regen).
- No new `.jq` queries (no queries embed regen — but a `git status` check is still required to confirm).

### Step 8 — Update CLAUDE.md if needed

Skim CLAUDE.md for any v1-shaped schema mention. Likely the principle-level callouts continue to apply unchanged. The Layout table and the "Adding a new extractor" steps reference `docs/pipeline-contract.md` by anchor; those references continue to work.

## KPIs

1. **Every illustrative record from both design notes validates against v2 without further amendment.** 17 records in `docs/pipeline-contract-v2-fixtures.jsonl`; all 17 parse and satisfy the v2 core projection. If any needs a new top-level field, the draft is incomplete.
2. **Every existing jq cluster query runs unchanged on a v2 TS catalog OR has a documented refit.** The audit table in `docs/pipeline-contract-v2-query-audit.md` lines up every query. Refit implementations are #116; this PR only documents.
3. **TS extractor output parses cleanly under v2.** The integration test catalog (regenerated against `extractors/typescript/fixtures/`) validates under `pipeline/validate-catalog.mjs` in v2 mode.
4. **Core projection is small.** Six required fields (`kind`, `name`, `file`, `line`, `language`, `package`), four required-when-applicable (`shape_sig`, `fields`, `type_text`, `type_sig`). If Rust's extractor (#138) is forced to add a seventh required field, v2 was wrong.
5. **Every `language_data.<lang>.*` field traces to a fixture record.** No speculative fields. The table in §1b cites the fixture for every field name.

## Files touched (estimate)

| File | Change | Lines |
|---|---|---|
| `docs/pipeline-contract.md` | Add v2 sections, bump examples to `"2.0"` | +200 / −20 |
| `docs/pipeline-contract-v2-fixtures.jsonl` | New file, 17 JSONL records | +400 (very rough) |
| `docs/pipeline-contract-v2-query-audit.md` | New file, 28-row audit table | +120 |
| `pipeline/validate-catalog.mjs` | Extend to handle `"2.0"` | +40 |
| `pipeline/queries/_tests/test_validate_catalog.sh` | Extend with v2 fixture asserts | +30 |
| `extractors/typescript/type-catalog.mjs` | `SCHEMA_VERSION = "2.0"`; emit `language` on every entry | +5 |
| `extractors/typescript/function-catalog.mjs` | Same | +5 |
| `extractors/file-hashes/file-hashes.mjs` | Same | +5 |
| `cmd/code-audit/extractors/typescript/type-catalog.mjs` | Regenerated embed | +5 |
| `cmd/code-audit/extractors/typescript/function-catalog.mjs` | Regenerated embed | +5 |
| `cmd/code-audit/extractors/file-hashes/file-hashes.mjs` | Regenerated embed | +5 |
| `docs/case-study.md` | Bump example to `"2.0"` (if envelope shown) | +2 / −2 |

Estimated diff: ~840 lines including the fixture file. Under the 1000-line CLAUDE.md cap. The fixture file is the bulk of the diff and is justified — it's the load-bearing evidence v2 works.

## Risks and open questions

- **Stacked-PR rebase risk.** This PR's branch is based on PR 1's branch. If PR 1 lands with cosmetic changes during review, this PR needs to rebase against the updated PR 1 branch (or against main if PR 1 squash-merged). Standard procedure.
- **Lane A collision on `docs/pipeline-contract.md`.** Both this PR and Lane A's #217 PR add per-entry fields documented in the type-catalog section. If Lane A lands first, this PR's v2 documentation has to mention `conforms_to: string[]` as a v1 shorthand for `relations[] | select(.kind == "conforms_to")`. If this PR lands first, Lane A's PR adopts v2's `relations[]` directly. Coordinate in the PR body; nothing else to do here.
- **Schema-version regex on the validator.** Updating `/^1\.\d+$/` to `/^[12]\.\d+$/` is brittle. The longer-term form is `/^(\d+)\.(\d+)$/` plus a per-major dispatch (the validator already does this implicitly — different fields are required on different versions). Document the longer form as the v2 stance.
- **`schema_version: "2.0"` vs `"2"` decision.** Locked in §"Decision" above. The pattern `MAJOR.MINOR` continues across all versions.
- **Vocabulary creep on `kind` and `language_data.*` field names.** v2 explicitly leaves both open. Mitigation: every field traces to a fixture record (§1b table). If two extractors use different names for the same concept, the contract gets normalized in a follow-up — this is the same growth path the v1 contract has used.
- **Swift extractor lag.** This PR does not touch the Swift extractor. The validator's `language` requirement on v2 catalogs will fail Swift catalogs once the Swift extractor bumps to `"2.0"`; until then, Swift catalogs validate as v1 / pre-envelope (bare array). The walker that produces wxyc-ios-64 cross-language reports needs both languages bumped to v2 before it produces v2-shaped output. That sequencing is documented in the PR body.
- **Audit-pass false-completeness.** The query audit (§Step 6) assumes the queries' field dependencies are exhaustively visible in the `.jq` source. They are — jq is dynamically typed but the field references are textual. A grep + manual walk for each query is enough; no AST analysis required.

## CI gates to pass locally before pushing

Same as PR 1, plus:

- `pipeline/queries/_tests/test_validate_catalog.sh` includes the new v2 fixture cases.
- The new fixture file parses as JSONL (one valid JSON per line).
- `pipeline/validate-catalog.mjs` runs clean on the fixture file.

## Issue / PR plumbing

- Issue #137 stays open until this PR merges; PR body says `Closes #137`.
- Cross-reference the triage tracker `#256`.
- Cross-reference PR 1 (#141) so reviewers know the stacking order. The PR title can name the stack: e.g., "Schema v2 — two-tier catalog ratification (stacked on #141)".
- Anonymity: no Claude attribution anywhere.
