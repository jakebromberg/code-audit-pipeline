# Issue #128 — touched-window debt summary plan

Closes [#128](https://github.com/jakebromberg/code-audit-pipeline/issues/128). Parent: [#116](https://github.com/jakebromberg/code-audit-pipeline/issues/116) (Phase 1 — zero schema delta).

The issue body already carries the design memo, KPIs, test plan, and four open questions. This plan resolves the open questions, locks the cluster-types scope at the four originals, fixes the file/test paths against the current substrate, and pins the test matrix before any `.jq` is written.

## Deliverables

One query file plus matching tests, fixture, and a README row. Re-derives the four original cluster groupings inline (Option A in the issue body). Zero extractor delta.

| File | Purpose | LOC budget |
|---|---|---|
| `pipeline/queries/touched-window-debt-summary.jq` | Meta-query: for each of the four original cluster types, compute `(total clusters, clusters with ≥1 touched member)` and list the touched cluster names with anchors. Default text mode emits a 4-row header table + per-type detail blocks. JSONL mode emits four objects, one per cluster type. | ~110 |
| `pipeline/queries/_tests/fixtures/debt-summary.input.json` | Hand-tuned catalog covering one touched cluster + one untouched cluster per cluster type. | ~30 rows |
| `pipeline/queries/_tests/fixtures/debt-summary-no-context.input.json` | Same shape, with `touched_in_window: false` everywhere — exercises the "no PR context" banner branch. Two fixture files are necessary because the no-context case is a global property of the catalog (no row has `touched_in_window: true`); filtering the primary fixture cannot exercise it. | ~8 rows |
| `pipeline/queries/_tests/test_queries_integration.sh` | Smoke + text-cid + semantic + knob coverage. ~10 new tests. | +180 lines |
| `README.md` | One new row in the Cluster queries table. | +1 line |

## Scope decision: which cluster queries does the meta-query index?

The issue body lists four — the original substrate. Since the issue was filed, #125 added `migration-progress.jq` + `shape-sig-frequency.jq`, and #126 added `generic-arity-drift.jq` + `generic-convention-bound.jq`. The natural question is whether v1 should index all eight.

**Pin v1 to the original four** — `exact-duplicates`, `name-collisions`, `cross-package-shadows`, `near-duplicates`. Rationale:

1. **Issue scope.** The issue body anticipates the migration-progress addition explicitly ("when migration-progress lands as a fifth cluster query, the meta-query gets a fifth row appended — a 3-line change"). Treating each new query as a follow-up patch matches the documented extension contract; including six-or-eight types up front would not be wrong but is out of scope for *this* issue.
2. **Two of the additions don't fit the "cluster-with-touched-member" frame cleanly.** `migration-progress` is a parameterized invocation (requires `--arg old_sig/new_sig/label`); it does not produce a static cluster list from `catalog.json` alone. `shape-sig-frequency` is a frequency report — each shape_sig is one row, not a cluster of decls; "touched fraction" applies but the row-vs-cluster framing differs.
3. The generics queries DO fit the frame, but folding them in is a follow-up — file under `#116` once v1 ships and we see whether the cluster-type detail blocks scale.

The meta-query's header docstring documents the extension contract: "to index an additional cluster query, append a tuple to the `clusters` array in this file with `{name, grouping_jq_fragment}`." Concretely the array is just a jq pipeline with four parallel branches; adding a fifth is a 5-7 line append.

## Resolutions to the issue's open questions

The issue body ends with four open questions. Resolutions, with rationale:

1. **Threshold pass-through for near-duplicates** — yes, with a default of 0.7 (matches `near-duplicates.jq`). Surface it as an env var (`THRESHOLD=0.7`), not a `--argjson threshold`. Rationale: `migration-progress.jq:40-42` already established the env-var-with-default convention for `PACKAGE`, `KIND_PREFIX`, `INCLUDE_GENERATED`. Going env-only here means the meta-query has no required CLI flags — just `jq -L pipeline/queries -rf pipeline/queries/touched-window-debt-summary.jq catalog.json`, matching every other query in the directory. The final jq will NOT declare `--arg threshold` anywhere; the only entry point is `$ENV.THRESHOLD`. Parsing: `($ENV.THRESHOLD // "0.7" | tonumber) as $thr` — empty/unset → 0.7, garbage → jq runtime error (acceptable fail-fast).
2. **Severity weighting** — no. Keep mechanical. Severity is the LLM tier's job; the substrate's job is to count cleanly. Documented in the header as a non-goal.
3. **Output format mode** — text default, JSONL via `OUTPUT_FORMAT=jsonl`. Matches every other query in the directory. The issue body's "raw text when interactive, JSON otherwise" idea is rejected — jq has no `isatty`, and a magic-mode-switch breaks reproducibility.
4. **`ONLY_TOUCHED` filtering granularity** — show full cluster context. When `ONLY_TOUCHED=true`, omit untouched cluster types from the detail blocks (a row showing `0/N` in the summary table is enough), but within a touched cluster, list every member (touched and untouched), marking touched members with `*`. The reviewer wants the cluster's full shape, not just the one member their PR touched. Implementation: filter the cluster *list*, not the cluster's *members*. Knob name: `ONLY_TOUCHED=true` (env, matching `OUTPUT_FORMAT` / `PACKAGE` / `KIND_PREFIX` convention).

## Output design

### Text mode (default)

```
TOUCHED-WINDOW DEBT SUMMARY  (threshold=0.7)

CLUSTER TYPE              TOUCHED  TOTAL    %  cid
exact-duplicates              1       2   50  touched-window-debt-summary:exact-duplicates
name-collisions               1       2   50  touched-window-debt-summary:name-collisions
cross-package-shadows         0       1    0  touched-window-debt-summary:cross-package-shadows
near-duplicates               1       2   50  touched-window-debt-summary:near-duplicates

exact-duplicates touched (1 of 2):
  [3 decls] SyncResult+SyncResult+SyncResult
    * SyncResult (interface) — main:jobs/etl.ts:10
      SyncResult (interface) — main:jobs/other.ts:20
      SyncResult (type-alias-object) — shared:types.ts:5

name-collisions touched (1 of 2):
  Repository
    * Repository [interface] main:db/a.ts:1
      Repository [interface] main:db/b.ts:1

near-duplicates touched (1 of 2):
  [88%] A@main:f1.ts:1  <->  B@main:f2.ts:1
    * A field-set: id, name, email
      B field-set: id, name, mail
```

### JSONL mode

Four objects, one per cluster type:

```jsonl
{"cluster_id":"touched-window-debt-summary:exact-duplicates","query":"touched-window-debt-summary","cluster_type":"exact-duplicates","touched":1,"total":2,"percent_touched":50,"touched_clusters":[{"cluster_id":"exact-duplicates:SyncResult+SyncResult+SyncResult","decls":[...]}]}
{"cluster_id":"touched-window-debt-summary:name-collisions",...}
{"cluster_id":"touched-window-debt-summary:cross-package-shadows","touched":0,"total":1,"percent_touched":0,"touched_clusters":[]}
{"cluster_id":"touched-window-debt-summary:near-duplicates",...}
```

### No-context branch

When NO row in the catalog has `touched_in_window: true`, the text-mode output prepends a one-line banner:

```
note: no touched_in_window flags set — run extractor with --touched <pr.json> for PR-time mode
```

Then continues with the normal table (showing `0` in every TOUCHED column). The JSONL mode emits the same four objects with `touched:0` everywhere; the banner is a text-mode-only affordance.

## Fixture (`debt-summary.input.json`)

One hand-tuned array covering each cluster type with both a touched and an untouched cluster.

| # | Cluster type covered | Rows |
|---|---|---|
| 1 | exact-duplicates (touched) | 3 decls with identical `shape_sig`, one with `touched_in_window: true`. Names: `SyncResult` ×3 across files. |
| 2 | exact-duplicates (untouched) | 2 decls with identical `shape_sig`, neither touched. Names: `CleanType` ×2. |
| 3 | name-collisions (touched) | 2 decls of `Repository` (different shapes, different files), one touched. |
| 4 | name-collisions (untouched) | 2 decls of `Logger` (different shapes, different files), neither touched. |
| 5 | cross-package-shadows (untouched only — keeps the row distinct from name-collisions) | 1 `shared` declaration `User`, 1 `main` declaration `User`, neither touched. |
| 6 | near-duplicates (touched) | 2 `main` interfaces with high Jaccard (e.g., `Person {id, name, email}` ↔ `Contact {id, name, mail}`), one touched. |
| 7 | near-duplicates (untouched) | 2 `main` interfaces with high Jaccard, neither touched. |

The expected summary:
- exact-duplicates: 1 touched / 2 total
- name-collisions: 1 touched / 2 total
- cross-package-shadows: 0 touched / 1 total
- near-duplicates: 1 touched / 2 total

Second fixture `debt-summary-untouched.input.json`: same rows as `debt-summary.input.json` *but every `touched_in_window` is false* (or omitted). Drives the "no context" banner branch.

## Test additions to `test_queries_integration.sh`

Add `DEBT_SUMMARY_FIXTURE` and `DEBT_SUMMARY_NO_CONTEXT_FIXTURE` constants near the existing `GENERICS_FIXTURE`. Add two semantic helpers. Naming: hybrid of the two precedents in the suite. The "counts" helper takes the `_semantic` suffix that matches `assert_migration_progress_semantic` (from #125, the larger-grained check); the "is-listed" helper takes `_present` matching `assert_generic_arity_drift_present` (from #126, the existence check):

- `assert_debt_summary_row_semantic(cluster_type, expected_touched, expected_total)` — runs the query in JSONL mode, parses the row for the given `cluster_type`, asserts `touched` and `total`.
- `assert_debt_summary_touched_cluster_present(cluster_type, source_cid_substring)` — JSONL mode; asserts the named source cluster (matched by substring against its embedded source cluster_id) appears in the meta-row's `touched_clusters[]` for the given cluster type.

Test cases:

1. **Smoke** — `assert_jsonl_has_prefix touched-window-debt-summary.jq` (four lines, all with `touched-window-debt-summary:` prefix).
2. **Smoke (text)** — `assert_text_has_cid touched-window-debt-summary.jq` (header table contains four `cid=touched-window-debt-summary:...` annotations).
3. **Semantic — counts per type:** four `assert_debt_summary_row_semantic` calls hitting the table from the fixture (1/2, 1/2, 0/1, 1/2).
4. **Semantic — touched clusters listed:** `SyncResult` appears under exact-duplicates; `Repository` under name-collisions; the `Person↔Contact` pair under near-duplicates.
5. **No-context edge case:** against `debt-summary-no-context.input.json`, the text-mode output contains the no-context banner; the JSONL output emits four rows all with `touched:0`.
6. **Knob — `ONLY_TOUCHED=true`:** detail block for `cross-package-shadows` is suppressed (it has 0 touched), but the header-table row remains. Three other detail blocks remain.
7. **Knob — `THRESHOLD=0.99`:** near-duplicates row goes to `0/0` (no pairs meet the high bar in the fixture). Confirms the env-var pass-through.
8. **Knob — `OUTPUT_FORMAT=jsonl`:** confirms parse-able JSON, four lines.

## Implementation order

TDD: fixtures + tests first, then implementation.

1. Add `debt-summary.input.json` + `debt-summary-no-context.input.json`.
2. Add the `DEBT_SUMMARY_FIXTURE` constant + ~10 `assert_*` calls to `test_queries_integration.sh`. Run — confirm new tests fail because the query doesn't exist.
3. Implement `touched-window-debt-summary.jq`. Iterate to green.
4. Add README row. Run full integration suite + canonical tests; confirm all ~90 pass.
5. Rebase against origin/main; create issue + PR; watch CI.

## Key implementation notes

- **`. as $all` once** at the top; each cluster-type computation references `$all` to avoid re-iterating the catalog four times.
- **Reuse the source queries' grouping rules verbatim** — copy-paste, not refactor into a shared `lib/`. The five-to-seven-line grouping fragments are stable and the duplication is documented in the header docstring with a pointer back to each source query.
- **Near-duplicates Jaccard:** the inner pair-loop from `near-duplicates.jq` is the only non-trivial fragment (~10 lines). Match it exactly; if `near-duplicates.jq` ever changes, the header docstring's "see also" pointer flags the meta-query for update.
- **cluster_id format:** `touched-window-debt-summary:<cluster-type>`. One row per cluster type per invocation — the cluster-type slug is already substrate-conventional and whitespace-free.
- **`touched-cluster predicate`:** `any(.decls[]; .touched_in_window // false)` works for grouped queries (exact-duplicates, name-collisions, cross-package-shadows). For near-duplicates the pair object has `a` and `b` instead of `decls[]` — use `(.a.touched_in_window // false) or (.b.touched_in_window // false)`. Will need a small per-type predicate function.
- **No-context banner predicate:** `any($all[]; .touched_in_window // false) | not`. Computed once, threaded into the text-mode emit.
- **Threshold ENV parsing:** `($ENV.THRESHOLD // "0.7" | tonumber) as $thr`. Empty / unset → 0.7. Letters → jq runtime error (acceptable — user-visible fail-fast).
- **jq gotchas** (per `CLAUDE.md`): `-r` everywhere; plain `"..."` inside `\(...)` interpolation; no `\"...\"` over-escaping.

## What this PR does not change

- No extractor changes.
- No `docs/pipeline-contract.md` changes — the meta-query consumes only existing required fields (`shape_sig`, `name`, `kind`, `package`, `file`, `line`, `fields`, `touched_in_window`, `generated`).
- No `_canonical.jq` changes — `cluster_id_single_name` covers the meta-query's per-type cluster_id format.
- No changes to the source queries — the meta-query is read-only with respect to them.

## Out-of-scope follow-ups (deliberate)

- Indexing the generics queries (`generic-arity-drift`, `generic-convention-bound`) and #125's queries (`migration-progress`, `shape-sig-frequency`). Filed as a follow-up once v1 lands and the detail-block scaling is understood.
- Severity weighting (issue's open question #2). Out of lane — that's the LLM tier's responsibility.
- A `--diff-from-prev-run` mode (regression detection). The substrate emits per-invocation snapshots; a separate "diff two snapshots" tool would be its own utility, not a flag on this query.
- Function-level cluster types (`function-duplicates`, etc.). The four originals are type-level; mixing in function-level rows is a future expansion of the cluster-types array, documented as the extension contract.
