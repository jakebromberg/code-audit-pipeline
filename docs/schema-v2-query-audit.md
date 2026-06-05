# Schema v2 query audit

A per-query walk of the 28 cluster queries in `pipeline/queries/` against the v2 contract. Status options:

- **Runs unchanged** — query depends only on fields v2 carries forward (`shape_sig`, `fields`, `name`, `kind`, `package`, `file`, `line`, `is_test`, `generated`, `touched_in_window`) and either has no `kind` whitelist or has a whitelist that only ever encounters TS-shaped records.
- **Runs unchanged but with a documented gap** — query operates correctly on v2 catalogs but its TS-shaped `kind` whitelist will under-count polyglot catalogs (e.g., misses `pydantic-model`, `type` (Swift), `dataclass`, etc.). Refits live in `#116` follow-ups.
- **Needs refit** — query depends on a field v2 redefines or removes. None expected; v2 is additive.

Audit procedure for each query: (1) field-reference grep to enumerate what fields the query reads; (2) kind-whitelist grep to flag TS-shaped filters. Both fields appear in the table below.

| Query | Status | Kind whitelist (if any) | Notes / follow-up |
|---|---|---|---|
| `cross-catalog-name-collisions` | runs unchanged but with a documented gap | `interface`, `type-alias-object`, `type-alias-union` | TS-shaped; polyglot expansion in #116. Cross-catalog joins already work on `name`/`package`/`shape_sig` which v2 preserves. |
| `cross-package-backward-imports` | runs unchanged | none — files-catalog query, operates on `.imports[]` edges | files.json schema not affected by v2's entry-level changes; runs against TS files.json untouched. |
| `cross-package-shadows` | runs unchanged but with a documented gap | `interface`, `type-alias-object`, `type-alias-*`, `zod-object` | Shadows query is two-package join; v2 adds `language` but query joins on `name`/`shape_sig`. Polyglot widening in #116. |
| `cross-package-shadows-any` | runs unchanged but with a documented gap | `type-alias-*`, `interface`, `zod-object` | same as above; `-any` variant relaxes shape match. |
| `cross-package-shape-near-duplicates` | runs unchanged but with a documented gap | `type-alias-*`, `interface`, `zod-object` | Jaccard query on `fields[]`. v2 preserves `fields[]` shape. |
| `cross-package-shape-near-duplicates-any` | runs unchanged but with a documented gap | `type-alias-*`, `interface`, `zod-object` | same. |
| `dead-code` | runs unchanged | none | Reads `name`/`exported`/`is_test`/`generated` plus the references graph. v2 untouched on all of these. |
| `default-impl-candidates` | runs unchanged | none (function-catalog query) | Body-cluster query; reads `name`/`shape_sig`-style body groupings. |
| `exact-duplicates` | runs unchanged | none | Pure `shape_sig` group-by. v2 preserves `shape_sig`. |
| `file-duplicates` | runs unchanged | none (file-hashes query) | Operates on `sha256` / `sha256_normalized`. v2 envelope change does not touch file-hashes. |
| `function-duplicates` | runs unchanged | none (function-catalog query) | Body-clustering on `body_hash`/`body_lines`. v2 unaffected. |
| `generic-arity-drift` | runs unchanged but with a documented gap | `interface`, `type-alias-*` | TS-shaped. `generics` field preserved by v2; polyglot extension is per-language (#116). |
| `generic-convention-bound` | runs unchanged | none | Pattern test on type-parameter names; no kind dependency that changes shape. |
| `generic-function-candidates` | runs unchanged | none (function-catalog query) | Reads function signatures; v2 unaffected. |
| `generic-struct-candidates` | runs unchanged but with a documented gap | `type-alias-object` | TS-shaped struct candidates. Polyglot widening in #116. |
| `migration-progress` | runs unchanged | `$kind_filter` argument (caller-provided) | Caller picks the kind; v2 makes `migration` a cross-language `kind` so a caller can now legitimately pass `migration` to mean Alembic+Drizzle migrations together. |
| `name-collisions` | runs unchanged but with a documented gap | `type-alias-*`, `interface`, `zod-object`, `drizzle-table` | Joins same-name records across packages; whitelist is TS-shaped. Polyglot extension in #116. |
| `near-duplicates` | runs unchanged | none | Jaccard on `fields[]`. v2 preserves `fields[]`. |
| `near-duplicates-any` | runs unchanged | none | same. |
| `orphan-infer-model` | runs unchanged | `type-alias-infer-model`, `drizzle-table` (TS / Drizzle specific) | Drizzle-specific by design; not a polyglot query. Stays language-specific. |
| `pat-candidates` | runs unchanged but with a documented gap | `interface`, `type-alias-object` | TS-shaped. Polyglot in #116. |
| `protocol-inheritance-candidates` | runs unchanged but with a documented gap | `interface` | TS-shaped. v2 introduces Swift `interface` (protocol) and Python `pydantic-model`; query name suggests it would benefit from Swift extension specifically. |
| `public-api-leaks` | runs unchanged | excludes `method`; otherwise no kind whitelist | Function-catalog × type-catalog join on `references[]`. v2 preserves both. |
| `shape-sig-frequency` | runs unchanged | `$kind_filter` argument (caller-provided) | Caller picks kind; v2 widens what's meaningful (e.g., `pydantic-model` aggregation). |
| `subset-pairs` | runs unchanged | none | Set-relation on `fields[]`. v2 preserves. |
| `symbol-id-collisions` | runs unchanged | none | Groups by `(package, file, name, kind)`. v2 preserves all four. |
| `test-prod-drift` | runs unchanged | none | XOR on `.is_test`. v2 preserves `is_test`. |
| `touched-window-debt-summary` | runs unchanged but with a documented gap | `type-alias-*`, `interface`, `zod-object`, `drizzle-table` | TS-shaped summary; polyglot reformulation in #116. |
| `versioned-type-pairs` | runs unchanged but with a documented gap | `type-alias-*`, `interface`, `zod-object`, `drizzle-table` (when `--kind_filter` empty) | Pattern-match on name suffix; polyglot extension follows the same path as the other shape queries. |

## Summary

- **28 queries audited.**
- **0 need refit.** No query depends on a v2-redefined or v2-removed field.
- **17 run unchanged.** Pure shape / body / files / hashes queries.
- **11 run unchanged but with a documented gap.** Each carries a TS-shaped `kind` whitelist that will under-count polyglot catalogs. These are listed against `#116` for the polyglot kind-list expansion.

## Refit plan

The 11 gap queries follow the same pattern: replace the TS-shaped whitelist (`interface | type-alias-* | zod-object | drizzle-table`) with a cross-language kind set (`interface | type-alias-* | zod-object | drizzle-table | pydantic-model | dataclass | type | enum`). The mechanical refit is small per query. The decision of whether to widen each query — vs. ship language-specific siblings — is the conversation in `#116`, not this PR.

`relations[]` is forward-compat for shape-based queries: queries that today read `extends[]` can switch to `relations[] | select(.kind == "extends") | .target`. The TS extractor continues to emit `extends[]` (v1 shorthand) until `#116` decides per-query which form to consume.
