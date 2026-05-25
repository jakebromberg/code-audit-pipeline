# A — Schema v2: top-level catalog wrapper with cross-repo metadata

**Parent:** [#118 — Cross-repo queries — merging N catalogs across the org](https://github.com/jakebromberg/code-audit-pipeline/issues/118).
**Coordinates with:** [#115 — Cross-language extractors](https://github.com/jakebromberg/code-audit-pipeline/issues/115).
**Blocks:** B, E, F1, F2, F3.

## 1. Context summary

**Current schema** ([`docs/pipeline-contract.md:9-37`](../pipeline-contract.md)): catalog is a bare JSON array; each entry is a flat object describing one declared type. Required fields: `name`, `kind`, `package`, `file`, `line`. `package` is the *intra-repo workspace marker* — its only documented values today are `"main"` (from `--root`) and `"shared"` (from `--shared`). There is no repo identity, no commit SHA, no extractor identity, and no notion of an *origin* package (the published npm/PyPI/Cargo name).

**Reference extractor** ([`extractors/typescript/type-catalog.mjs`](../../extractors/typescript/type-catalog.mjs)): walks files, calls `pushBase()` (line 169) which spreads `{ package: pkgName, file: relPath, line, touched_in_window, generated }` plus the kind-specific partial. The whole array is `JSON.stringify`'d at line 311 and written to stdout/`--output`. Stats are printed to stderr (lines 295-309). The script has the exact information the wrapper needs (file counts, kind histogram, package histogram) but throws it away as stderr text instead of attaching it to the catalog.

**Existing queries' bare-array assumption** — every `.jq` file in [`pipeline/queries/`](../../pipeline/queries/) begins with operations directly on `.` (the root array):

- `exact-duplicates.jq:8`: `[ .[] | select(.shape_sig != null …) ]` — slices the root array.
- `name-collisions.jq:9`: `group_by(.name)` — operates on root array.
- `cross-package-shadows.jq:11-14`: `. as $all | ([ $all[] | select(.package == "shared" …) ] …)` — root array.
- `near-duplicates.jq:12`: `[ .[] | select(.package == "main" …) ]` — root array.

Every query breaks the moment the catalog becomes an object. Each needs a one-line refactor (`.` → `.entries`) but no semantic change. `classify.jq` operates on PR JSON, not on catalogs, and is unaffected.

**Why the change is needed for #118.** Without `repo` on every row, a concatenated stream from N catalogs loses provenance — there is no way to express Q1 ("consumers of `@wxyc/shared`") or Q2 ("two repos define the same type"). Without `commit_sha` per row, snapshot pinning is lost the moment two catalogs at different SHAs are merged. Without `extractor.version` at top level, version skew between catalogs is silent. Without `origin_package`, the join key for "consumed by repo A, published by repo B" doesn't exist — `package` cannot serve double duty because cross-package-shadows still needs the intra-repo workspace marker. `field_names_sig` is the coarse cross-language join key that #115's design notes converge on; it must ship before the second extractor lands so the schema isn't retrofitted in the third extractor.

## 2. Functional requirements

### 2.1 Catalog shape (full)

```jsonc
{
  "schema_version": 2,
  "repo": "wxyc/dj-site",
  "commit_sha": "abc123def456abc123def456abc123def456abcd",
  "generated_at": "2026-05-25T14:32:01Z",
  "extractor": {
    "name": "type-catalog",
    "version": "2.0.0",
    "language": "typescript"
  },
  "scope": {
    "files_indexed": 194,
    "files_total":   201,
    "roots": [
      { "package": "main",   "files": 145 },
      { "package": "shared", "files":  49 }
    ],
    "errors": 0,
    "kind_histogram": { "interface": 195, "type-alias-object": 117, "drizzle-table": 34 }
  },
  "entries": [
    {
      "name": "FlowsheetEntry",
      "kind": "interface",
      "repo": "wxyc/dj-site",                                    // (a)
      "commit_sha": "abc123def456abc123def456abc123def456abcd",  // (b)
      "package": "main",                                          // (c) intra-repo workspace marker, unchanged
      "origin_package": "@wxyc/dj-site",                          // (d) published name, nullable
      "file": "src/models/flowsheet.ts",
      "line": 42,
      "exported": true,
      "generated": false,
      "touched_in_window": false,
      "fields": ["album_title:string | null", "artist_name:string | null", "id:number"],
      "shape_sig": "album_title:string | null|artist_name:string | null|id:number",
      "field_names_sig": "album_title|artist_name|id",            // (e)
      "type_text": null, "type_sig": null, "generics": null, "infer_ref": null, "db_table_name": null
    }
  ]
}
```

### 2.2 Per-row vs top-level decisions

| Field | Placement | Rationale |
|---|---|---|
| `schema_version` | top-level only | Single value per catalog; fails fast for preflight checks. |
| `repo` | **both** — top-level + per-row | Per #118 explicitly: per-row so concatenated catalogs across snapshots don't lose pinning. After `jq -s 'map(.entries) | add'` flattens N catalogs, the top-level wrapper is gone; only per-row repo survives the merge. Duplication is cheap (string, 10-30 bytes per row) and the constraint is mechanical (extractor copies top-level into every row at emit time). |
| `commit_sha` | **both** — top-level + per-row | Same reasoning as `repo`. At 30-repo scale catalogs at the same instant carry 30 different SHAs, and the post-merge query surface needs to filter on SHA per row ("show me findings where the consumer is on a SHA ≥ X"). Verified the issue's reasoning — per-row is correct. |
| `extractor` | top-level only | Per-row would be 95% redundant (one extractor per catalog by construction). Preflight check operates on top-level; merge code never needs to inspect it per row. Multi-language merges keep catalogs separate (concatenation of entries, not pre-merge), so per-row extractor identity is unnecessary. |
| `generated_at` | top-level only | Per-catalog timestamp, not per-row. |
| `scope` | top-level only | Aggregate stats, by definition not per-row. |
| `package` | per-row, unchanged | Intra-repo workspace marker. `cross-package-shadows.jq` will continue to need this; do not repurpose. |
| `origin_package` | per-row, nullable | Published npm/PyPI/Cargo name *for this row's declaration*. Null for unpublished workspaces, intra-repo non-published code, or anything the extractor can't resolve. For a TS row, the source of truth is the nearest ancestor `package.json`'s `name` field walking up from `file`. **Recommendation:** read `package.json` once per scope (`main`/`shared`) at extractor startup; attach to every row from that scope. Per-file walking is overkill at v2; monorepos with multiple internal `package.json`s can be handled in a follow-up. |
| `field_names_sig` | per-row, nullable | Required-when-applicable wherever `fields` is non-null. Null otherwise. |

### 2.3 `field_names_sig` computation

```
field_names_sig = fields
  .map(f => f.split(':')[0])              // strip type
  .map(n => n.replace(/\?$/, ''))         // strip optional marker
  .map(n => n.toLowerCase())              // case-fold
  .sort()                                 // canonical order
  .join('|')
```

For `["album_title:string | null", "artist_name:string | null", "id:number"]` → `"album_title|artist_name|id"`.

Coordinates with #115: cross-language joins cannot rely on `shape_sig` because type spellings differ (`string` vs `String`, `number` vs `Int`). `field_names_sig` is the coarser key the #115 design memo explicitly calls for. It is *also* useful within a language as a Jaccard pre-bucketing key — `near-duplicates.jq` currently does the name-extraction on the fly (line 17-18); pre-computing it amortizes that work and lets a future query bucket by `field_names_sig` prefix to avoid O(n²) blowup.

### 2.4 Normalization rules

- `repo`: `"owner/name"` form (e.g., `wxyc/dj-site`). Lowercase. Just `name` is ambiguous across GitHub orgs.
- `commit_sha`: full 40-char hex, lowercase.
- `generated_at`: RFC 3339 UTC, second-precision (`"2026-05-25T14:32:01Z"`). No sub-second precision — adds noise to byte-reproducibility across re-runs.
- `extractor.version`: semver string (`"2.0.0"`).
- `extractor.language`: `"typescript" | "python" | "swift" | "rust" | "go" | …`. Lowercase, single-token.
- `origin_package`: as published (`"@wxyc/shared"`, `"pydantic"`, `"serde"`). No normalization — the join needs to be exact across consumer/publisher rows.

### 2.5 Required / required-when-applicable / optional

- **Required (top-level):** `schema_version`, `repo`, `commit_sha`, `generated_at`, `extractor.{name,version,language}`, `scope.{files_indexed,files_total}`, `entries`.
- **Required (per-row):** `name`, `kind`, `repo`, `commit_sha`, `package`, `file`, `line`.
- **Required-when-applicable (per-row):** `fields` + `shape_sig` + `field_names_sig` for shape-of-named-members constructs. `type_text` + `type_sig` for non-object type aliases. `origin_package` when the extractor can resolve the published name; null otherwise (don't omit the key — keeps row shapes uniform for jq).
- **Optional (per-row):** `exported`, `generated`, `touched_in_window`, `generics`, `infer_ref`, `db_table_name`.

## 3. Non-functional requirements

- **Byte-reproducibility:** two extractor runs at the same git SHA, same fixture, same wall clock minute must produce byte-identical catalogs *except for `generated_at`*. Support `SOURCE_DATE_EPOCH` env var (reproducible-builds convention); when set, use that for `generated_at`. CI uses this to assert byte-stability across runs.
- **Backwards-incompatible but mechanical:** every query needs `.` → `.entries`. Estimated diff: 4 files × 1 line each = 4 lines of jq churn. README change: one block. Pipeline-contract change: substantial rewrite of the "Catalog shape" section.
- **Size growth bound:** per-row additions are `repo` (~20B), `commit_sha` (~40B), `origin_package` (~30B avg, null when absent), `field_names_sig` (~varies, typically 20-100B). Top-level wrapper adds ~500B fixed. On the case-study fixture (595 entries), worst case is ~595 × 90B + 500B ≈ 54KB added to a ~250KB catalog — **~22% growth bound**. KPIs section pins ≤25% as the gate.
- **Catalog-merge cost:** `jq -s 'map(.entries) | add' repo-*.json` on 30 × 1k entry catalogs = 30k rows. Per #118's reasoning this is sub-second in jq.

## 4. KPIs

1. **Zero query breakage after refit.** Every existing query in `pipeline/queries/` produces functionally equivalent output (same clusters, same row counts) on a v1 catalog and a v2 catalog of the same fixture.
2. **Byte-reproducibility.** With `SOURCE_DATE_EPOCH` pinned, two runs of the v2 extractor against the same fixture produce `diff -q` clean output. CI gating: a workflow runs the extractor twice and `diff`s.
3. **Size growth ≤ 25%** on the wxyc/dj-site narrow-substrate fixture.
4. **Catalog merge for 30 × 1k entries completes in <1s with `jq -s`** on a developer laptop (M-series Mac).
5. **Cross-repo join correctness on synthetic fixture:** a 3-repo synthetic fixture where repo A publishes `@x/shared` with `type User`, repo B redeclares `type User` with the same shape, repo C imports from `@x/shared` — after merge, a join `entries | group_by(.field_names_sig)` followed by `select(map(.repo) | unique | length > 1)` surfaces (A, B) as a cross-repo shadow cluster.
6. **Preflight version check rejects cross-major catalogs:** `jq` script that reads `.extractor.version` from each catalog, fails loudly if any catalog's major is below the highest major in the set.

## 5. Testing strategy

### Fixtures

- **Golden fixture, synthetic.** A tiny 3-file TS project under `extractors/typescript/__fixtures__/v2-schema/` — 1 interface, 1 type alias, 1 zod object. Hand-written expected catalog committed alongside as `expected.json`. CI runs the extractor, diffs against the golden file. This is the byte-reproducibility test.
- **Real-codebase smoke fixture.** Point at `wxyc/dj-site` (already used by V2 methodology); confirm the v2 catalog's `.entries` length matches the v1 catalog's row count exactly (modulo the `field_names_sig` field being added — no entries should be added or dropped).
- **Cross-repo synthetic fixture.** Three small TS roots (`__fixtures__/cross-repo/repo-a`, `…/repo-b`, `…/repo-c`) with the publish/redeclare/consume pattern from KPI #5. CI script runs the extractor on each, then `jq -s 'map(.entries) | add'` to merge, then asserts the cross-repo shadow query finds the (A, B) cluster.

### Single-repo equivalence proof

For every query in `pipeline/queries/`, the v1-equivalence test is: given fixture F, the v1 query against v1 catalog `cat1.json` produces output `O1`. The v2 query against v2 catalog `cat2.json` produces output `O2`. Assertion: `O1` and `O2` are line-identical after stripping any timestamp suffixes. This proves the schema change is non-semantic for existing query consumers.

### Version-skew tests

- Two synthetic catalogs at `extractor.version` `"2.0.0"` and `"2.1.0"` → preflight passes with stderr warning.
- Two synthetic catalogs at `"2.0.0"` and `"3.0.0"` → preflight fails with non-zero exit.
- A `"1.0.0"` catalog (bare array) and a `"2.0.0"` catalog → preflight fails *and* surfaces the v1-bare-array case specifically with a "run `pipeline/migrate-v1-to-v2.jq` first" hint.

### CI gating

Add a workflow step that:

1. Runs the extractor against the synthetic golden fixture twice (different wall-clock seconds), diffs the outputs.
2. Runs all four queries against the golden v2 catalog, diffs against committed expected query outputs.
3. Runs the merged-3-repo cross-repo test, asserts shadow cluster is found.

## 6. Implementation recommendations

### File changes

- **`docs/pipeline-contract.md`** — full rewrite of the "Catalog shape" section (lines 5-37); add new "Top-level wrapper" section before it; new "Cross-repo fields" subsection covering `repo`, `commit_sha`, `origin_package`, `field_names_sig`; explicit deprecation note for v1 bare-array consumers. Update "Required fields" section (lines 54-56) and add "Required-when-applicable" notes for `field_names_sig` parallel to existing `shape_sig` notes.
- **`extractors/typescript/type-catalog.mjs`** —
  - Add `--repo`, `--commit-sha`, `--origin-package-main`, `--origin-package-shared` CLI flags to `parseArgs` (lines 16-25). Without these, the extractor falls back to: `--repo` from `git config --get remote.origin.url` parsed to `owner/name`; `--commit-sha` from `git rev-parse HEAD` in the `--root` directory; `--origin-package-*` from the nearest `package.json#name` field.
  - In `pushBase()` (lines 169-179), add `repo`, `commit_sha`, and `origin_package` to the row. Resolve `origin_package` per-scope at extractor startup (one `package.json` read per root) and pass into `extractFromFile`.
  - Add `field_names_sig` computation to `shapeSig()` call sites (lines 191, 207, 223 — wherever `shape_sig` is set, set `field_names_sig` too). Helper: `const fieldNamesSig = (fields) => fields.map(f => f.split(':')[0].replace(/\?$/, '').toLowerCase()).sort().join('|');`.
  - Replace `JSON.stringify(all, null, 2)` (line 311) with `JSON.stringify({ schema_version: 2, repo, commit_sha, generated_at, extractor: { name: 'type-catalog', version: '2.0.0', language: 'typescript' }, scope: { ... }, entries: all }, null, 2)`. Pull the histogram computation (lines 296-301) up so it can be attached to `scope.kind_histogram` instead of just printed to stderr.
  - Add `SOURCE_DATE_EPOCH` honoring for `generated_at`.
  - Bump `package.json` (`extractors/typescript/package.json`) version to `2.0.0`.
- **`pipeline/queries/exact-duplicates.jq:8`** — `[ .[] | … ]` → `[ .entries[] | … ]`. Same one-line change in `name-collisions.jq:9`, `cross-package-shadows.jq:12-14` (note: this one has a `. as $all` — needs `.entries as $all` and updates throughout), `near-duplicates.jq:12`.
- **`pipeline/preflight-versions.jq`** *(new file; full design lives in [118-E](118-E-operational-safety.md))*.
- **`pipeline/migrate-v1-to-v2.jq`** *(new file)* — wraps a bare-array v1 catalog into a v2 object. Top-level metadata uses placeholders (`repo: "unknown"`, etc.) with stderr warnings. Provides an upgrade path for any v1 catalogs persisted to disk.
- **`README.md`** — update Quick Start block (lines 45-57) to show the new flags and that the catalog is now an object. Update "What the catalog contains" section.

### PR ordering

**Two PRs in sequence.**

- **PR 1 (this sub-issue):** the schema v2 wrapper + all per-row fields + all query refits + golden fixtures + CI gating. Everything in this brief.
- **PR 2** (separate sub-issue of #118): the actual cross-repo orchestration — `fetch-catalogs.sh`, merge driver, the cross-repo query family. That work is a different shape (orchestration + new query types) and would push PR 1 well past the 1000-line guideline.

`field_names_sig` ships with PR 1 (the wrapper change) — it is a row-level addition computed at extractor time, and deferring it would force a second extractor bump before #115's second language lands. Doing it now is cheap (~5 lines).

### Handling the breaking change

The v1→v2 break is bounded: only this repo's queries depend on the v1 bare-array assumption. There are no external consumers of `catalog.json` documented anywhere. Strategy: update the queries in the same PR as the schema change. No version-both-formats period; the `pipeline/migrate-v1-to-v2.jq` script provides the upgrade path for anyone with a saved v1 catalog. The `schema_version: 2` field at the top makes the break explicit and lets preflight catch v1 inputs by inspecting `if . | type == "array"` (bare array → v1).

### Catalog format version

Explicit `schema_version` field at top level. Integer, increments on breaking changes only. `schema_version: 2` for this change. Distinct from `extractor.version` (the extractor's semver), which can move independently — e.g., extractor v2.1.0 bug fixes don't bump `schema_version`. The two-version model is cheap and unambiguous.

## 7. Open questions / decisions still needed

1. **`origin_package` source of truth for non-published workspaces.** What about `"private": true` in `package.json`? Set `origin_package` to the private name anyway, or null? **Suggested default:** set it anyway — it's still useful as a workspace identifier, and `null` is reserved for "extractor couldn't determine."
2. **`repo` form.** Auto-derive from `git config --get remote.origin.url` (parsing `git@github.com:wxyc/dj-site.git` → `wxyc/dj-site`), or require explicit `--repo` flag? **Suggested default:** auto-derive when flag absent, log to stderr what was derived, error if no remote is configured.
3. **`commit_sha` for dirty working trees.** What does the extractor emit if `git status --porcelain` shows uncommitted changes? Options: (a) emit the SHA anyway with no warning; (b) emit `<sha>+dirty`; (c) error out. **Suggested default:** (b), with stderr warning.
4. **`scope.files_total` definition.** "Total" = all candidate `.ts`/`.tsx`/`.mts`/`.cts` files after skip-dir filtering. `files_indexed` is the subset that the extractor successfully parsed.
5. **Should `field_names_sig` be lowercased?** Yes, consistent with `shape_sig`. Cross-language joins between TypeScript `userId` and Python `user_id` won't match either way — that's a snake_case ↔ camelCase normalization question for a hypothetical v3 `field_names_sig_normalized`, deferred.
6. **Preflight on minor version mismatch — warn-and-proceed, or strict?** Issue #118 says "stderr warning." Match the issue's reasoning; make `--strict` an opt-in on the preflight script for users who want CI to fail hard.

## 8. Sub-ticket boilerplate

**Title:** `Schema v2: wrap catalog in metadata object + add cross-repo fields (repo, commit_sha, origin_package, field_names_sig)`

**Direction (issue body opener):**

> The current catalog (`docs/pipeline-contract.md`) is a bare JSON array with `package`/`file`/`line` but no repo identity, commit pinning, or extractor identity — none of the metadata #118's cross-repo merge surface needs. This sub-issue lands the schema v2 wrapper: catalogs become `{schema_version, repo, commit_sha, extractor, generated_at, scope, entries: [...]}`, and every row carries `repo` and `commit_sha` (so post-merge streams keep provenance), `origin_package` (the published npm/PyPI/Cargo name, distinct from the intra-repo `package` workspace marker), and `field_names_sig` (the cross-language join key #115 calls for). This is a breaking change for the four existing `pipeline/queries/*.jq` files — each needs a one-line `.` → `.entries` refit, landed in the same PR. The cross-repo orchestration (merge driver, `consumers-of.jq`, R2 fetch) is deliberately out of scope here and ships as follow-up sub-issues of #118.

## Key file references

- [`/Users/jake/Developer/code-audit-pipeline/docs/pipeline-contract.md`](../pipeline-contract.md) (current schema, lines 5-37 require rewrite)
- [`/Users/jake/Developer/code-audit-pipeline/extractors/typescript/type-catalog.mjs`](../../extractors/typescript/type-catalog.mjs) (reference extractor; `pushBase` line 169, JSON.stringify call line 311, stderr stats lines 295-309)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/exact-duplicates.jq:8`](../../pipeline/queries/exact-duplicates.jq)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/name-collisions.jq:9`](../../pipeline/queries/name-collisions.jq)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/cross-package-shadows.jq:11-14`](../../pipeline/queries/cross-package-shadows.jq)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/near-duplicates.jq:12`](../../pipeline/queries/near-duplicates.jq)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/classify.jq`](../../pipeline/classify.jq) (unaffected — operates on PR JSON, not catalogs)
- [`/Users/jake/Developer/code-audit-pipeline/README.md:45-57`](../../README.md) (Quick Start needs flag updates)
