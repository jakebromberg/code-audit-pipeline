# F1 — Q1 `consumers-of.jq` — surface cross-repo API consumption patterns

**Parent:** [#118 — Cross-repo queries — merging N catalogs across the org](https://github.com/jakebromberg/code-audit-pipeline/issues/118).
**Blocked by:** [A — Schema v2](118-A-schema-v2.md), [B — Imports kind](118-B-imports-kind.md), [E — Operational safety](118-E-operational-safety.md).
**Sibling queries:** [F2 — cross-repo-duplicates](118-F2-cross-repo-duplicates.md), [F3 — renamed-consumers](118-F3-renamed-consumers.md).

## 1. Context summary

Given a published package (`@wxyc/shared`), enumerate every import-site of every exported symbol across the merged catalog. Reports symbols ranked by consumer breadth: "which repos pull which APIs, at which file:line." A surface-popularity map; nothing comparable exists today.

This is the **cross-repo inverse** of `pipeline/queries/cross-package-shadows.jq` (lines 11–17). Where cross-package-shadows asks "what should have been an import but wasn't?" (redeclarations of a canonical), F1 asks "what *is* an import, and from where?" (the consumer footprint of the canonical). Both queries together give the full picture of how a published API surface is used and abused across the org.

**Dependency chain.** F1 ships after:

- [A](118-A-schema-v2.md) provides `repo`, `origin_package`, and the merged-catalog substrate.
- [B](118-B-imports-kind.md) provides `kind: "import"` rows with `origin_package` resolved from bare specifiers.
- [E](118-E-operational-safety.md) provides the wrapper script that prepends coverage + preflight to every cross-repo query output.

## 2. Functional requirements

**Inputs.** Merged catalog (`jq -s 'map(.entries) | add' catalogs/*.json` per [C](118-C-substrate.md)). Requires `repo`, `kind`, `name`, `exported`, `origin_package`, `file`, `line`, `touched_in_window` fields. Requires `kind == "import"` rows emitted by extractors (per [B](118-B-imports-kind.md)). Parameter: `--arg pkg "@wxyc/shared"`.

**Join keys.** `(origin_package, name)` for joining import-sites against the publisher's exported decls. This is the **published-API join key** identified in #118 — "`name` alone is never a valid cross-repo join key — it must be qualified." Naturally language-agnostic: `origin_package` is the published package name (npm, PyPI, Cargo); cross-language consumption joins on the same key.

**Output format.** Mirrors `exact-duplicates.jq` lines 18–21 (cluster size header + indented `*`-marked tail). Sort by consumer count descending:

```
DiscogsTrack [interface] — used by 7 repos:
  * wxyc/dj-site:src/components/Track.tsx:14
    wxyc/library-api:src/etl/discogs.ts:89
    wxyc/etl-worker:jobs/lookup.ts:31
    wxyc/playlist-app:src/views/track.tsx:9
    wxyc/charts:src/transform.ts:55
    wxyc/api-server:src/handlers/track.ts:22
    wxyc/audit-tools:src/types.ts:103

LmlClient [interface] — used by 3 repos:
    wxyc/dj-site:src/lib/lml.ts:9
    wxyc/library-api:src/clients/lml.ts:18
    wxyc/etl-worker:jobs/lookup.ts:7
```

Touched-in-window asterisk per existing conventions (`exact-duplicates.jq` line 20). Cluster header format `<symbol> [<declared_kind>] — used by N repos:` to match the issue body's sketch and the established `[kind]` brace convention from `name-collisions.jq` line 20.

**Filtering.** Drop imports where `origin_package == repo's own publication name` (intra-repo imports are noise). Optional `--arg min_consumers 2` to filter out single-consumer surface (which by definition isn't a consumption pattern, just a dependency).

## 3. Non-functional requirements

Performance budget at 30-repo scale (~30k rows total, of which ~80% are imports):

- **Wall-clock budget:** <0.5s at 30k rows; <3s at 300k rows (if some repos balloon).
- **Complexity:** O(n log n) — single `group_by`. The expensive part is the surface lookup (joining import rows against publisher's exported decls); pre-filter to `kind == "import"` before group_by.
- **Memory:** linear in import-row count; ~10MB at 30k rows.

When budgets break: move to SQLite per #118's escape hatch.

## 4. KPIs

1. **Recall.** Matches the output of `git grep '^import.*@wxyc/shared' -- '*.ts'` aggregated across the 30-repo org. Acceptance: ≥98% of distinct `(repo, file, symbol)` import-sites surfaced.
2. **Precision.** Zero false positives on a fixture where no repo imports `@wxyc/shared`.
3. **Run-time.** <0.5s on 30k-row fixture; <3s on 300k-row fixture.
4. **Plausibility on real data.** Top three consumers for `DiscogsTrack`, `FlowsheetEntry`, and `WXYCRole` (symbols dj-site and library-metadata-lookup actually consume per the dj-site experiment) appear with correct file:line citations.
5. **Coverage header.** Wrapper script prepends "scope: N/30 repos covered" before any F1 output. Verified by the wrapper's own test suite (see [E](118-E-operational-safety.md)).

## 5. Testing strategy

Fixture catalogs go under `pipeline/queries/fixtures/consumers-of/`. Each fixture is a JSON file that can be fed directly to `jq -rf consumers-of.jq` without needing real extractors to run. Golden output committed alongside as `<fixture-name>.expected.txt`.

**Fixtures**

- `basic.json` — 3 repos, one publisher (`@wxyc/shared`) with 4 exported symbols, two consumers each importing 2 of them. Golden output: each symbol grouped by consumer count.
- `no-consumers.json` — publisher with exports, no import rows. Golden output: empty.
- `self-import.json` — publisher's own files contain imports from itself; verify filter drops them.
- `single-consumer.json` — exercises `--arg min_consumers 2` filter.
- `cross-language.json` — TS consumer of `@wxyc/shared`, Python consumer of `wxyc-shared-py` (same conceptual canonical, different published names). Verify each is grouped under its own `origin_package`.

**Real-codebase validation**

Run F1 against a merged catalog of `wxyc/dj-site` + `wxyc/library-metadata-lookup` + `wxyc/wxyc-shared` (the smallest meaningful cross-repo set). Cross-check via `git grep` that no consumer site is missing from the output.

## 6. Implementation recommendations

**File:** `pipeline/queries/consumers-of.jq`.

**Header** per CLAUDE.md "Adding a new cluster query":

```
# consumers-of.jq — enumerate cross-repo consumers of a published package's exports.
#
# Run:  jq -r --arg pkg "@wxyc/shared" -f consumers-of.jq merged-entries.json
# Or:   pipeline/run-cross-repo-query.sh consumers-of --pkg @wxyc/shared
#
# Requires schema v2 (entries flattened from catalogs-as-objects) and kind:"import" rows.
# Outputs: symbol clusters sorted by consumer breadth, mirroring exact-duplicates.jq format.
```

**Sketch** (refining the issue body's draft):

```jq
. as $all
| ([$all[] | select(.repo as $r | (.origin_package // "") | endswith("/" + ($r | split("/") | .[1])) | not)
           | select(.kind == "import" and .origin_package == $pkg)]) as $imports
| ([$all[] | select(.exported and .origin_package == $pkg) | {name, kind}]) as $surface
| $imports
| group_by(.name)
| map({
    symbol: .[0].name,
    consumers: (map({repo, file, line, touched_in_window}) | unique_by("\(.repo):\(.file):\(.line)")),
    declared_kind: (($surface | map(select(.name == ($imports | .[0].name))) | .[0].kind) // "unknown")
  })
| sort_by(-(.consumers | length))
| .[]
| "\(.symbol) [\(.declared_kind)] — used by \(.consumers | length) repos:\n"
  + (.consumers | map("  \(if .touched_in_window then "*" else " " end) \(.repo):\(.file):\(.line)") | join("\n"))
```

Drop the self-import filter as the first clause (avoid the noise from a publisher importing its own exports).

**Schema-v2 stance.** Require schema v2 explicitly. The catalog-as-object change ([A](118-A-schema-v2.md)) is breaking; trying to make every new query backwards-compatible with bare-array catalogs via `(.[] | .entries) // .` poisons the queries with conditional logic. Document schema v2 as a prerequisite in the header.

**`include "lib/cross-repo-filters"` import** ([E](118-E-operational-safety.md)) — use the `is_published` predicate for the self-import filter once that helper module lands.

**Ship as one PR** after [B](118-B-imports-kind.md) lands. The PR is ~50 lines of jq + fixtures + golden outputs. Under the 1000-line target.

## 7. Cross-language considerations

Naturally language-agnostic. `(origin_package, name)` is the cross-language join key — `@wxyc/shared`'s exports are typed in TS; a Python service that imports from a sibling Python package published under `wxyc-shared-py` (or a Swift target with module name `WxycShared`) would surface alongside in the same query *if* their respective extractors emit `kind:"import"` rows with `origin_package` set. No special-casing needed in the jq.

Default to grouping by `(origin_package, name)`. The `--arg pkg` parameter is intentionally one package — cross-package queries are F2's lane.

## 8. Open questions / decisions still needed

1. **Should the symbol's `declared_kind` be reported, or just imported_name?** The issue sketch shows `[interface]` after the symbol; useful for readers who want to know "is this a type, function, or zod schema?" Keep it. If the publisher repo's catalog isn't in the merge set, `declared_kind: "unknown"`.
2. **Should imports of types-only (with `type_only: true`) be reported separately?** A `import type` consumer is structurally a weaker dependency (only erased at runtime). Recommend annotating in the consumer line: `wxyc/dj-site:src/foo.ts:14 (type-only)`. Optional but cheap.
3. **Should re-exports be counted as consumers?** A re-export `export { DiscogsTrack } from "@wxyc/shared"` arguably is a consumer — it depends on the symbol existing. Recommend yes, mark them as `(re-export)` in the output.
4. **`--arg pkg` accepts one package — should we also support `--argjson pkgs '["a","b"]'`?** Defer until a query needs it.

## 9. Sub-ticket boilerplate

**Title:** `Q1: consumers-of.jq — surface cross-repo API consumption patterns`

**Direction:**

> Generalize `pipeline/queries/cross-package-shadows.jq`'s `package`-axis join to a 30-repo `origin_package`-axis surface map. Given a published package name, group all `kind:"import"` rows in the merged catalog by symbol name, list every importing `(repo, file, line)`, sort by consumer count descending. Mirrors the output format of `exact-duplicates.jq` (cluster header + indented `*`-marked tail). Depends on: [A](118-A-schema-v2.md) schema v2 (catalog-as-object, `repo`, `origin_package` fields); [B](118-B-imports-kind.md) imports-kind extractor change (`kind:"import"` rows); [E](118-E-operational-safety.md) operational safety wrapper. Ships after F2.

## Key file references

- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/exact-duplicates.jq`](../../pipeline/queries/exact-duplicates.jq) (lines 18–21 — cluster-header + asterisk-tail template)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/cross-package-shadows.jq`](../../pipeline/queries/cross-package-shadows.jq) (lines 11–17 — package-axis join, the pattern F1 inverts)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/name-collisions.jq`](../../pipeline/queries/name-collisions.jq) (lines 18–22 — `(N)` count + indented tail template)
- [`/Users/jake/Developer/code-audit-pipeline/docs/pipeline-contract.md`](../pipeline-contract.md) (`shape_sig` definition lines 78–81)
- [`/Users/jake/Developer/code-audit-pipeline/docs/case-study.md`](../case-study.md) ("Pure missed imports" section: the dual finding)
- [`/Users/jake/Developer/code-audit-pipeline/CLAUDE.md`](../../CLAUDE.md) "jq gotchas" section
