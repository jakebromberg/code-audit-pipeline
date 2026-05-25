# F2 — Q2 `cross-repo-duplicates.jq` — shadow-of-canonical vs independent reinvention

**Parent:** [#118 — Cross-repo queries — merging N catalogs across the org](https://github.com/jakebromberg/code-audit-pipeline/issues/118).
**Blocked by:** [A — Schema v2](118-A-schema-v2.md), [E — Operational safety](118-E-operational-safety.md).
**Sibling queries:** [F1 — consumers-of](118-F1-consumers-of.md), [F3 — renamed-consumers](118-F3-renamed-consumers.md).

## 1. Context summary

Group declarations by shape across the merged catalog, keep only clusters whose declarations span ≥2 repos, separate "shadows of a canonical (e.g., `wxyc/shared`) decl" from "independent reinvention." This is the **cross-repo generalization of `pipeline/queries/cross-package-shadows.jq` (lines 11–17) + `exact-duplicates.jq` (lines 8–16)** — promoting `package` from a 2-valued field (`"main" | "shared"`) to a 30-valued repo dimension. The case-study finding "`DiscogsTrackItem` redeclared in `apps/backend` but already in `@wxyc/shared`" (`docs/case-study.md` §"Pure missed imports", lines 107–109) is the in-monorepo analog that F2 catches *across* repos.

**Ships first among the F queries** because it has the smallest dependency surface — only schema v2 ([A](118-A-schema-v2.md)) and the operational safety wrapper ([E](118-E-operational-safety.md)). No imports-kind dependency (it operates on declarations).

## 2. Functional requirements

**Inputs.** Merged catalog. Requires `repo`, `name`, `kind`, `shape_sig`, `field_names_sig` (for cross-language paths), `origin_package`, `file`, `line`, `touched_in_window`. No imports-kind dependency.

**Join keys.** Two modes:

- **Same-language mode (default):** group by `shape_sig`. Matches `exact-duplicates.jq` line 9 directly; the only delta is the post-group filter `(map(.repo) | unique | length) > 1`.
- **Cross-language mode (`--argjson cross_lang true`):** group by `field_names_sig` (sorted-lowercased field-names, no types). This is the cross-language join key called out in #118's "Failure modes at 30 repos & mitigations" — "type-text equality as a within-language affordance only" — and seconded in #115's "Open questions" — "the cross-language join key (`field_names_sig`, coarser than `shape_sig`) needs to land in the contract once a second language extractor ships."

**Output format.** Mirrors `exact-duplicates.jq` line 18 cluster header. Add a `classification` column distinguishing canonical-shadow from independent-reinvention:

```
[3 fields, 4 decls across 4 repos]  CLASSIFICATION: shadow-of-canonical (wxyc/shared)
    DiscogsTrack (interface) — wxyc/shared:src/types/discogs.ts:12
  * DiscogsTrackItem (interface) — wxyc/dj-site:src/components/Track.tsx:9
    DiscogsTrack (interface) — wxyc/library-api:src/types.ts:33
    DiscogsTrackItem (interface) — wxyc/etl-worker:jobs/discogs/types.ts:7

[2 fields, 3 decls across 3 repos]  CLASSIFICATION: independent-reinvention
    SyncResult (interface) — wxyc/dj-site:src/state.ts:21
  * SyncResult (interface) — wxyc/etl-worker:jobs/sync.ts:14
    SyncResult (interface) — wxyc/library-api:src/api/sync.ts:8
```

Sort: shadow-of-canonical clusters first (more actionable — the fix is "import from canonical"), then independent-reinvention by cluster size descending.

**Filtering.** Drop clusters where `(map(.repo) | unique | length) == 1` — those are already covered by `exact-duplicates.jq` within a single repo. For cross-language mode, optional `--argjson min_field_count 3` to suppress trivial 1-2-field collisions. Classification logic: if any decl in the cluster has `origin_package` equal to a "canonical" published package (default `@wxyc/shared`, override with `--arg canonical_pkg`), emit `shadow-of-canonical`; otherwise `independent-reinvention`.

## 3. Non-functional requirements

Performance at 30-repo scale (~30k rows, of which ~20% are declarations):

- **Wall-clock budget:** <0.5s same-language; <1s cross-language (group key is shorter, grouping is actually faster but the field-names normalization has light pre-compute cost).
- **Complexity:** O(n log n) — single `group_by`.
- **Pre-filter to** `exported == true && !generated` for cross-repo queries (per #118 perf analysis); reduces row count by ~5×.

## 4. KPIs

1. **Reproduces V1 case-study findings.** Synthetic 4-repo fixture seeded with `DiscogsTrackItem` (shadow-of-canonical), `SyncResult` ×3 (independent-reinvention), and `LogLevel` ×4 (independent-reinvention). Golden output committed under `pipeline/queries/fixtures/cross-repo-duplicates/`. F2 must surface all three clusters with correct classifications.
2. **Cross-language mode.** Fixture with a TS `interface Foo { id: string; name: string }` and a Python `class Foo(BaseModel): id: str; name: str`. Default same-language mode does not group them; `--argjson cross_lang true` does.
3. **Run-time.** <0.5s on 30k-row fixture; <1s on 300k-row fixture.
4. **Within-repo exclusion.** Clusters where all decls are within one repo do not appear (those are `exact-duplicates.jq`'s lane).
5. **Shadow-vs-reinvention ordering.** Shadow-of-canonical clusters always appear before independent-reinvention in the output.

## 5. Testing strategy

Fixture catalogs go under `pipeline/queries/fixtures/cross-repo-duplicates/`.

**Fixtures**

- `dj-site-case-study.json` — synthetic recreation of the case-study findings: `DiscogsTrackItem` in `wxyc/dj-site` + `DiscogsTrack` in `wxyc/shared` (same `shape_sig`); `SyncResult` ×3 across 3 repos with same `shape_sig` and no canonical. Golden output classifies the first as shadow-of-canonical, the second as independent-reinvention.
- `same-repo-only.json` — clusters where all decls are within one repo (should be filtered out — `exact-duplicates.jq`'s lane).
- `cross-language.json` — TS interface + Python BaseModel with same `field_names_sig` but different `shape_sig`. Default same-language mode does not group them; `--argjson cross_lang true` does.
- `multiple-canonicals.json` — exercise `--arg canonical_pkg` override and the case where the cluster has decls from two different "canonical" packages.

## 6. Implementation recommendations

**File:** `pipeline/queries/cross-repo-duplicates.jq`.

**Header**:

```
# cross-repo-duplicates.jq — group shape-equal declarations spanning ≥2 repos.
#
# Run:  jq -r [--arg canonical_pkg "@wxyc/shared"] [--argjson cross_lang true] -f cross-repo-duplicates.jq merged-entries.json
# Or:   pipeline/run-cross-repo-query.sh cross-repo-duplicates [args]
#
# Requires schema v2. Cross-language mode requires field_names_sig populated.
# Outputs: clusters sorted by classification (shadow-of-canonical first), then by cluster size.
```

**Sketch:**

```jq
($cross_lang // false) as $cl
| [.[] | select(.exported and (.generated | not))]
| group_by(if $cl then .field_names_sig else .shape_sig end)
| map(select(length > 1))
| map(select((map(.repo) | unique | length) > 1))
| map({
    sig: (.[0].shape_sig // .[0].field_names_sig),
    field_count: (.[0].fields // [] | length),
    repo_count: (map(.repo) | unique | length),
    decls: map({name, kind, repo, file, line, touched_in_window, origin_package}),
    classification: (
      if (map(.origin_package == $canonical_pkg) | any)
      then "shadow-of-canonical (\($canonical_pkg))"
      else "independent-reinvention"
      end
    )
  })
| sort_by(
    if (.classification | startswith("shadow-of-canonical")) then 0 else 1 end,
    -(.decls | length)
  )
| .[]
| "[\(.field_count) fields, \(.decls | length) decls across \(.repo_count) repos]  CLASSIFICATION: \(.classification)\n"
  + (.decls | map("  \(if .touched_in_window then "*" else " " end) \(.name) (\(.kind)) — \(.repo):\(.file):\(.line)") | join("\n"))
```

**Ship as one PR** after [A](118-A-schema-v2.md) and [E](118-E-operational-safety.md) land. ~80 lines of jq + fixtures.

## 7. Cross-language considerations

Requires both modes. Default same-language mode (group by `shape_sig`) is the default because shape-equality is the strongest precision signal *within* a language. Cross-language mode (group by `field_names_sig`) is opt-in via `--argjson cross_lang true`. The case-study finding `DiscogsTrackItem` vs `DiscogsTrack` would be detected in same-language mode because both decls are TS; finding a Python `DiscogsTrack(BaseModel)` that shadows the TS canonical would require cross-language mode. Both signals matter; surfacing them under the same header with a different `--argjson` is cleaner than two queries.

## 8. Open questions / decisions still needed

1. **Classification: column or separate query?** Should "shadow-of-canonical" vs "independent-reinvention" be a separate query (`shadows-of-canonical.jq`) or a `classification:` column inside `cross-repo-duplicates.jq`? **Recommendation: column.** Splitting into two queries duplicates the group_by work and forces consumers to mentally merge two outputs to see the full duplication landscape. One query, one classification column, sort-by-classification-first keeps the output scannable.
2. **Canonical-package allowlist.** Start with `--arg canonical_pkg "@wxyc/shared"` (single-value default); upgrade to a JSON list (`--argjson canonical_pkgs '["@wxyc/shared", ...]'`) when a second canonical published package emerges.
3. **What happens when a cluster has decls from multiple canonical packages?** Edge case — exercise it in `multiple-canonicals.json` fixture; recommend the classification become `shadow-of-canonical (multiple)` and list all in the cluster header.
4. **Should `near-duplicates.jq` (Jaccard) also have a cross-repo mode?** Future work. Defer to a follow-up; same group-by-then-Jaccard pattern, different threshold semantics across repos.

## 9. Sub-ticket boilerplate

**Title:** `Q2: cross-repo-duplicates.jq — shadow vs independent-reinvention`

**Direction:**

> Cross-repo generalization of `pipeline/queries/exact-duplicates.jq` + `cross-package-shadows.jq`. Group merged-catalog decls by `shape_sig` (same-language) or `field_names_sig` (cross-language, opt-in via `--argjson cross_lang true`); keep clusters spanning ≥2 repos; classify each cluster as `shadow-of-canonical` (if any decl has `origin_package` matching the canonical-package allowlist, default `@wxyc/shared`) or `independent-reinvention`. The cross-repo extension of the case-study's "Pure missed imports" finding (`docs/case-study.md` lines 107–109). Depends on: [A](118-A-schema-v2.md) schema v2 only and [E](118-E-operational-safety.md) operational safety wrapper. Ships first among the F queries.

## Key file references

- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/exact-duplicates.jq`](../../pipeline/queries/exact-duplicates.jq) (lines 8–21 — cluster-header + asterisk-tail template; the same-language mode is a direct extension)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/cross-package-shadows.jq`](../../pipeline/queries/cross-package-shadows.jq) (lines 11–17 — package-axis join, the pattern F2 generalizes)
- [`/Users/jake/Developer/code-audit-pipeline/docs/pipeline-contract.md`](../pipeline-contract.md) (`shape_sig` definition lines 78–81; `field_names_sig` is the schema-v2 extension)
- [`/Users/jake/Developer/code-audit-pipeline/docs/case-study.md`](../case-study.md) lines 107–109 (`DiscogsTrackItem` finding — the in-monorepo analog of F2)
- [`/Users/jake/Developer/code-audit-pipeline/CLAUDE.md`](../../CLAUDE.md) "jq gotchas" section
