# F3 — Q3 `renamed-consumers.jq` — detect stale imports after publisher rename

**Parent:** [#118 — Cross-repo queries — merging N catalogs across the org](https://github.com/jakebromberg/code-audit-pipeline/issues/118).
**Blocked by:** [A — Schema v2](118-A-schema-v2.md), [B — Imports kind](118-B-imports-kind.md), [E — Operational safety](118-E-operational-safety.md), [#117 — Time: catalog snapshots and structured diffs](https://github.com/jakebromberg/code-audit-pipeline/issues/117).
**Sibling queries:** [F1 — consumers-of](118-F1-consumers-of.md), [F2 — cross-repo-duplicates](118-F2-cross-repo-duplicates.md).

## 1. Context summary

Given a t0 and a t1 merged catalog, detect renames inside the publisher repo (same `shape_sig` + same `file`, different `name`), then anti-join against t1's imports to find consumers still referencing the old symbol name. A surfacing-of-rot query: the cross-repo failure mode that `tsc` will not flag because each repo type-checks independently.

**Ships last among the F queries** — it has the largest dependency surface (everything F1 has, plus #117's temporal layer for the t0/t1 catalogs). However, F3 is **testable on hand-crafted fixture catalogs before #117 ships**; only the wrapper that *produces* the t0/t1 inputs depends on #117.

## 2. Functional requirements

**Inputs.** Two merged catalogs (t0, t1). Both must include imports rows (kind:"import") and decl rows. Recommended invocation: `jq --slurpfile t0 merged-t0.json --slurpfile t1 merged-t1.json -rf renamed-consumers.jq` with a wrapper because slurpfile gives an outer array per file.

Required fields: full schema v2 (same as F1).

**Join keys.** Two-stage:

1. **Detect renames** inside the publisher repo (default scope: every `repo` that appears as an `origin_package`): pair t0 decls and t1 decls where `(repo, file, shape_sig)` is identical but `name` differs. This is the in-place rename signal — Pass 1 of #117's three-pass matcher specialized to "same shape + same file" (see #117 body, "Pass 1 — exact identity match" through "Pass 3 — Jaccard fallback"). **Punt on Jaccard-renames for v1 of F3**; require `shape_sig` equality to keep precision high.
2. **Anti-join** against t1 imports: for each `(old_name, origin_package)` from stage 1, find t1 import rows with `name == old_name && origin_package == publisher_pkg`. Those are stale consumers.

**Output format.** Group by `(origin_package, old_name)`. Mirrors `name-collisions.jq` lines 18–22 (header + indented tail with `*`):

```
@wxyc/shared :: DiscogsTrackItem (renamed → DiscogsTrack at wxyc/shared:src/types/discogs.ts:12)
  3 stale consumers:
    wxyc/dj-site:src/components/Track.tsx:14
  * wxyc/etl-worker:jobs/lookup.ts:31
    wxyc/library-api:src/etl/discogs.ts:89

@wxyc/shared :: oldFn (renamed → newFn at wxyc/shared:src/utils/fn.ts:5)
  1 stale consumer:
    wxyc/dj-site:src/lib/util.ts:18
```

Sort by stale-consumer count descending, then `origin_package` ascending. Asterisk-mark imports whose `touched_in_window` is true at t1 (recent import was added against the stale name, suggesting the consumer team hasn't seen the rename).

**Filtering.** Skip renames where stale-consumer count == 0 (those are clean migrations). Optional `--arg publisher "wxyc/shared"` to restrict the publisher repo; default scans all repos that publish under any `origin_package`.

## 3. Non-functional requirements

Performance at 30-repo scale across two catalogs:

- **Wall-clock budget:** <1.5s at 30k rows per catalog; <5s at 300k rows.
- **Complexity:** O(n_t0 × n_t1) worst case for naive join, but dominated by group_by on shape_sig — effectively O(n log n). Build `shape_sig`-keyed hash table over t0 publisher decls before scanning t1.
- **Memory:** ~20MB at 30k rows × 2 catalogs.

## 4. KPIs

1. **Recall.** ≥90% of stale-consumer references on a synthetic rename fixture: t0 has `DiscogsTrackItem` declared in `wxyc/shared`, 5 consumer imports across 3 repos; t1 has `DiscogsTrack` (same shape, same file, new name) in `wxyc/shared`, with 4 of the 5 consumer imports unchanged.
2. **Precision.** Zero false positives on a control fixture where t0 == t1.
3. **Run-time.** <1.5s on 30k-row paired catalogs.
4. **Touched-in-window flagging.** Imports added during the audit window (t1's `touched_in_window: true`) are asterisk-marked correctly.

## 5. Testing strategy

Fixture catalogs go under `pipeline/queries/fixtures/renamed-consumers/`. F3 is testable on hand-crafted fixtures before #117 ships — only the wrapper that produces real t0/t1 inputs from snapshots depends on #117.

**Fixtures**

- `t0.json` and `t1.json` — two hand-crafted catalogs simulating what a t0/t1 pair from #117's snapshot tool *would* look like. Each catalog has the schema-v2 top-level metadata block. t1 has one rename (`DiscogsTrackItem` → `DiscogsTrack` in `wxyc/shared`) and a control unchanged decl. Three consumer repos in t1 still import `DiscogsTrackItem`. Golden output: 3 stale consumers listed under one rename group.
- `identity.json` × 2 — t0 == t1. Golden output: empty.
- `clean-migration.json` × 2 — t0 has stale consumers; t1's rename is propagated to all consumers. Golden output: empty.
- `multi-rename.json` × 2 — t1 has two renames in the same publisher repo. Golden output: two rename groups.
- `shape-changed.json` × 2 — t1's rename also changed the shape (a field was added). v1 (shape-equality only) does NOT detect this; documents the known limitation. v2 (Jaccard fallback) would.

## 6. Implementation recommendations

**File:** `pipeline/queries/renamed-consumers.jq`.

**Header**:

```
# renamed-consumers.jq — detect cross-repo stale imports after publisher rename.
#
# Run:  jq -r --slurpfile t0 merged-t0.json --slurpfile t1 merged-t1.json -f renamed-consumers.jq
# Or:   pipeline/run-cross-repo-query.sh renamed-consumers --t0 ... --t1 ...
#
# Requires schema v2, kind:"import" rows, and two merged catalogs (t0/t1) from #117.
# v1: shape-equality only (no Jaccard fallback); known limitation in shape-changed.json fixture.
# Outputs: rename groups sorted by stale-consumer count, mirroring name-collisions.jq format.
```

**Sketch:**

```jq
($t0 | first) as $t0_all
| ($t1 | first) as $t1_all
# Stage 1: detect renames in any repo that publishes under origin_package
| ($t1_all | map(select(.kind != "import")) | group_by({repo, file, shape_sig})) as $t1_groups
| ($t0_all | map(select(.kind != "import")) | group_by({repo, file, shape_sig})) as $t0_groups
| [
    $t0_groups[] as $t0g |
    $t1_groups[] | select(
      .[0].repo == $t0g[0].repo and
      .[0].file == $t0g[0].file and
      .[0].shape_sig == $t0g[0].shape_sig and
      .[0].shape_sig != null
    ) as $t1g |
    ($t0g | map(.name)) as $t0names |
    ($t1g | map(.name)) as $t1names |
    $t0names[] | select(. as $n | $t1names | index($n) | not) as $old |
    ($t1names[0]) as $new |  # naive: assume one new name per rename
    {
      publisher_repo: $t0g[0].repo,
      publisher_file: $t0g[0].file,
      publisher_line: ($t1g | .[0].line),
      old_name: $old,
      new_name: $new,
      origin_package: ($t0g | .[0].origin_package)
    }
  ] as $renames
# Stage 2: anti-join against t1 imports
| $renames
| map(. as $r |
    . + {
      stale_consumers: [
        $t1_all[] | select(
          .kind == "import" and
          .name == $r.old_name and
          .origin_package == $r.origin_package
        ) | {repo, file, line, touched_in_window}
      ]
    }
  )
| map(select(.stale_consumers | length > 0))
| sort_by(-(.stale_consumers | length), .origin_package)
| .[]
| "\(.origin_package) :: \(.old_name) (renamed → \(.new_name) at \(.publisher_repo):\(.publisher_file):\(.publisher_line))\n"
  + "  \(.stale_consumers | length) stale consumers:\n"
  + (.stale_consumers | map("  \(if .touched_in_window then "*" else " " end) \(.repo):\(.file):\(.line)") | join("\n"))
```

**Ship as one PR** after [B](118-B-imports-kind.md) and #117 land. ~70 lines of jq + fixtures.

## 7. Cross-language considerations

Same-language only for v1 — rename-detection across language boundaries (a TS symbol renamed; a Python type alias renamed in sympathy) is a second-order signal that requires the publisher to have published in *both* languages, and the rename to have happened in both extracted catalogs. Treat as out-of-scope; the publisher is by definition single-repo (most often `wxyc/shared`, a TS package), so the rename detection runs on TS rows. The stale-consumer anti-join naturally handles cross-language consumers because `(origin_package, name)` is the join key on the import side.

## 8. Open questions / decisions still needed

1. **Rename-detection precision.** Should v1 require `shape_sig` equality (precise — only catches in-place renames with no shape change) or include #117's Jaccard pass-3 fallback (recalls renames that also changed shape, lower precision)? **Recommendation: shape-equality only for v1**; the Jaccard fallback adds dependency surface on #117's exact algorithm choice. F3.1 can add it once #117 ships and its rename-threshold defaults are validated.
2. **What if t1 has multiple new names in the same `(repo, file, shape_sig)` group?** The sketch's naive assumption "one new name per rename" breaks. Real case: a refactor that splits one type into two. Recommend: surface as ambiguous-rename and report all old→new candidate pairs in the output, flagged.
3. **What if the publisher repo changed in t1 (e.g., a type moved from `wxyc/shared` to `wxyc/types`)?** Out of scope for v1; the move is detectable but the cross-publisher migration is a different rename pattern. Defer.
4. **Should ranges of `t0` history matter?** Currently a single t0 → t1 pair. Could extend to "find renames in the last N snapshots" for trend analysis. Out of scope for v1.
5. **What about renames *to* a name that already existed in t0?** This is a collision-resolution rename (`Foo` was something else, now means the renamed thing; the old `Foo` is now something else). Rare but possible. v1 detection may produce false positives; document the limitation and address in v2 if it surfaces in real audits.

## 9. Sub-ticket boilerplate

**Title:** `Q3: renamed-consumers.jq — detect stale imports after publisher rename`

**Direction:**

> Two-stage cross-repo rename-detection. Stage 1: pair t0 and t1 publisher decls where `(repo, file, shape_sig)` is identical but `name` differs — in-place renames. Stage 2: anti-join against t1 imports to find consumers still referencing the old name. Output groups by `(origin_package, old_name)` and lists stale consumer call-sites; mirrors `name-collisions.jq` output format. Asterisk-marks t1 imports added during the audit window. Depends on: [A](118-A-schema-v2.md) schema v2; [B](118-B-imports-kind.md) imports-kind extractor change (F1 prereq); [E](118-E-operational-safety.md) operational safety wrapper; [#117](https://github.com/jakebromberg/code-audit-pipeline/issues/117) temporal layer (t0/t1 catalogs produced by `pipeline/snapshot.mjs`). Ships last. F3 is testable on hand-crafted fixture catalogs before #117 ships.

## Key file references

- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/name-collisions.jq`](../../pipeline/queries/name-collisions.jq) (lines 18–22 — `(N)` count + indented tail template F3 mirrors)
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/near-duplicates.jq`](../../pipeline/queries/near-duplicates.jq) (lines 17–22 — Jaccard pattern; relevant for #117's Pass-3 fallback if F3 v2 reaches for it)
- [`/Users/jake/Developer/code-audit-pipeline/docs/pipeline-contract.md`](../pipeline-contract.md) (`shape_sig` definition lines 78–81)
- [`/Users/jake/Developer/code-audit-pipeline/CLAUDE.md`](../../CLAUDE.md) "jq gotchas" section
- [#117 — Time: catalog snapshots and structured diffs](https://github.com/jakebromberg/code-audit-pipeline/issues/117) — provides the t0/t1 catalog production
