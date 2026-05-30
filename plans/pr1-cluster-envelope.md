# PR 1 — Canonical JSONL cluster envelope + `#! shape:` headers

Substrate-prep PR for the audit binary. Mechanical rename of cluster-row fields across the 25 `.jq` queries so every JSONL row conforms to a shape-typed envelope, plus a `#! shape: <value>` front-matter line on each query so the eventual binary's renderer can dispatch on shape without per-query knowledge.

Per [ADR-0003](../docs/adr/0003-canonical-cluster-envelope.md): three shapes (`cluster`, `pair`, `metric`). Per [ADR-0002](../docs/adr/0002-hybrid-registration.md): single-line `#! key: value` front-matter convention. This PR adds only the `shape:` key; the full front-matter (input-catalog, args, description, etc.) lands in PR 2.

Tracker: [#177](https://github.com/jakebromberg/code-audit-pipeline/issues/177).

## Shape categorization

The 25 queries break down by shape as follows. The shape is determined by the row's structural form, not the source language or domain.

### `cluster` — N members grouped by a common key (12 queries)

The cluster envelope is `{cluster_id, query, shape: "cluster", members: [...], ...query-specific aggregate fields}`. Members are decls; the renderer iterates `members` and prints a per-decl line.

| Query | Current field | Renamed to |
|---|---|---|
| `exact-duplicates.jq` | `decls` | `members` |
| `name-collisions.jq` | `decls` | `members` |
| `cross-package-shadows.jq` | `members` | (already migrated) |
| `cross-package-shadows-any.jq` | `locations` | `members` |
| `generic-arity-drift.jq` | `decls` | `members` |
| `function-duplicates.jq` (exact section) | `decls` | `members` |
| `file-duplicates.jq` (exact + norm sections) | `members` | (already migrated) |
| `cross-catalog-name-collisions.jq` | `decls` | `members` |
| `default-impl-candidates.jq` | `decls` | `members` |
| `orphan-infer-model.jq` | — (per-decl row, flat fields) | wrapped into `members: [{...}]` (length 1) |
| `generic-convention-bound.jq` | — (per-decl row, flat fields) | wrapped into `members: [{...}]` (length 1) |

**Single-member clusters** (`orphan-infer-model`, `generic-convention-bound`): each row represents one offending decl, but the envelope still wraps it as `members: [{...}]` of length 1. This keeps a single dispatcher for cluster-shape rows. The renderer is shape-aware, not arity-aware; a "cluster of one" renders cleanly as "1 decl flagged for X reason."

### `pair` — two endpoints (11 queries)

The pair envelope is `{cluster_id, query, shape: "pair", left, right, ...query-specific fields}`. `left` and `right` are the two endpoint decls; the renderer prints both sides plus any per-query metric (`jacc`, `intersection`, `union`, etc.).

| Query | Current fields | Renamed to | Direction convention |
|---|---|---|---|
| `near-duplicates.jq` | `a`/`b`/`af`/`bf` | `left`/`right`/`left_fields`/`right_fields` | symmetric |
| `near-duplicates-any.jq` | `a`/`b`/`af`/`bf` | `left`/`right`/`left_fields`/`right_fields` | symmetric |
| `subset-pairs.jq` | `sub`/`sup`/`sub_fields`/`sup_fields` | `left`/`right`/`left_fields`/`right_fields` | **directed: left ⊂ right** |
| `cross-package-shape-near-duplicates.jq` | `main`/`shared`/`af`/`bf`/`main_only`/`shared_only` | `left`/`right`/`left_fields`/`right_fields`/`left_only`/`right_only` | **asymmetric: left=main, right=shared** |
| `cross-package-shape-near-duplicates-any.jq` | `a`/`b`/`af`/`bf`/`a_only`/`b_only` | `left`/`right`/`left_fields`/`right_fields`/`left_only`/`right_only` | symmetric |
| `function-duplicates.jq` (near section) | `a`/`b` | `left`/`right` | symmetric |
| `test-prod-drift.jq` | `a`/`b`/`af`/`bf` | `left`/`right`/`left_fields`/`right_fields` | **asymmetric: left=prod, right=test** |
| `generic-function-candidates.jq` | `a`/`b`/`swap_tokens_a`/`swap_tokens_b` | `left`/`right`/`left_swap_tokens`/`right_swap_tokens` | symmetric |
| `generic-struct-candidates.jq` | `a`/`b`/`a_slots`/`b_slots` | `left`/`right`/`left_slots`/`right_slots` | symmetric |
| `pat-candidates.jq` | `a`/`b`/`a_slots`/`b_slots` | `left`/`right`/`left_slots`/`right_slots` | symmetric |
| `protocol-inheritance-candidates.jq` | `a`/`b`/`a_only`/`b_only` | `left`/`right`/`left_only`/`right_only` | symmetric |

**Asymmetric pair convention** (directed or role-bearing): the query header documents which side maps to `left` and `right`. The renderer treats all pairs uniformly; the asymmetric meaning lives in the query's documentation and any `direction` / `pair_role` field the query chooses to add. For PR 1, no `direction` field — the asymmetric queries keep their semantics in the header and the cluster_id format. The renderer in PR 4 can opt into per-query rendering hints if needed.

### `metric` — single-value or summary row (3 queries)

The metric envelope is `{cluster_id, query, shape: "metric", ...arbitrary query-specific fields}`. No structural fields beyond `cluster_id`/`query`/`shape` are required; the renderer treats the row as a key-value bag.

| Query | Notes |
|---|---|
| `migration-progress.jq` | Single object per invocation; carries `on_old`, `on_new`, `percent_migrated`, `stragglers`, etc. |
| `shape-sig-frequency.jq` | One row per shape_sig; carries `count`, `sample_names`. |
| `touched-window-debt-summary.jq` | One row per cluster-type; carries `touched`/`total`/`percent_touched` + nested `touched_clusters[]`. |

## Dual-shape queries

Two queries emit rows of more than one shape:

- `function-duplicates.jq` — exact section (cluster) + near section (pair).
- `file-duplicates.jq` — exact section (cluster) + norm section (cluster). Same shape both sections; only the `query` discriminator differs (`function-duplicates-exact` vs `function-duplicates-near`; `file-duplicates-exact` vs `file-duplicates-norm`).

**Header convention for dual-shape queries**: `#! shape: cluster, pair` (comma-separated, ordered by section order in output). Single-shape queries use the singular form: `#! shape: cluster`.

**Per-row dispatch**: every emitted JSONL row carries a `shape:` field at the top level (e.g., `"shape": "cluster"`). The header is informational/declarative; the renderer dispatches on the row's `shape` field. This means a renderer never needs to know about queries — only about shapes. PR 3's `audit query` registers each query with its declared shape(s) for validation; PR 4's `audit report` reads each row and routes to the cluster / pair / metric renderer based on the row's `shape` field.

This separation is cheap (one extra field per row, ~20 bytes) and decouples queries from renderers entirely. The alternative — renderer-dispatches-on-query-name — would force PR 4 to ship a lookup table of every query, which is exactly the per-query renderer the ADR rejected.

## Field-rename conventions (precise)

Across all queries:

| Old | New | Rationale |
|---|---|---|
| `decls` | `members` | ADR-0003 envelope contract |
| `locations` (cross-package-shadows-any only) | `members` | Same |
| `a` | `left` | ADR-0003 envelope contract; unifies all pair queries |
| `b` | `right` | Same |
| `af` | `left_fields` | Spell out for clarity; consistent prefix |
| `bf` | `right_fields` | Same |
| `a_only` | `left_only` | Consistent prefix |
| `b_only` | `right_only` | Same |
| `a_slots` | `left_slots` | Same |
| `b_slots` | `right_slots` | Same |
| `swap_tokens_a` | `left_swap_tokens` | Reordered to use the `left_` prefix convention |
| `swap_tokens_b` | `right_swap_tokens` | Same |
| `sub` (subset-pairs) | `left` | Direction documented in header |
| `sup` (subset-pairs) | `right` | Same |
| `sub_fields` (subset-pairs) | `left_fields` | Same |
| `sup_fields` (subset-pairs) | `right_fields` | Same |
| `main` (cross-package-shape-near-duplicates) | `left` | Role documented in header |
| `shared` (cross-package-shape-near-duplicates) | `right` | Same |
| `main_only` (cross-package-shape-near-duplicates) | `left_only` | Same |
| `shared_only` (cross-package-shape-near-duplicates) | `right_only` | Same |

Existing query-specific fields that don't fit the rename map (`jacc`, `intersection`, `union`, `field_count`, `body_hash`, `body_line_count`, `shape_sig`, `name`, `kind`, `package`, `file`, `line`, `db_table_name`, `missing`, `suspects`, `slot_diff_count`, `distinct_types`, `pkg_count`, `verdict`, `per_catalog_field_names`, `catalogs`, `overlap`, `shared_members`, `label`, `on_old`/`on_new`/`percent_migrated`/`stragglers`/`no_matches`/`sigs_identical`, `count`/`sample_names`, `cluster_type`/`touched`/`total`/`percent_touched`/`touched_clusters`) stay unchanged. They're not envelope-level; they're per-query payload.

## `shape:` field placement

Each query's emitted row gets `shape: "cluster"|"pair"|"metric"` as a top-level field. Insertion convention: between `query:` and the first envelope-specific field (`members` / `left` / payload). Example:

```jq
# Before:
{
  cluster_id: cluster_id_sorted_names("exact-duplicates"; map(.name)),
  query: "exact-duplicates",
  shape_sig: .[0].shape_sig,
  field_count: (.[0].fields | length),
  decls: map({name, kind, package, file, line, touched_in_window})
}

# After:
{
  cluster_id: cluster_id_sorted_names("exact-duplicates"; map(.name)),
  query: "exact-duplicates",
  shape: "cluster",
  shape_sig: .[0].shape_sig,
  field_count: (.[0].fields | length),
  members: map({name, kind, package, file, line, touched_in_window})
}
```

## Text-mode output

Text-mode rendering (the `else` branch in `if output_format == "jsonl" then ... else ... end`) is also touched because it references the renamed fields (e.g., `.decls | length`, `.a.name`, `.sub.file`). Per ADR-0003, text mode stays inside each `.jq` file's branch on `output_format` — only the JSONL path routes through the binary's shape-dispatcher. So this PR updates text mode in lockstep with JSONL field names but does not change text-mode formatting beyond the symbol substitutions.

Asymmetric-pair text mode (`test-prod-drift`, `cross-package-shape-near-duplicates`, `subset-pairs`) preserves the semantic labels in the rendered text: "prod:" / "test:", "main:" / "shared:", "sub:" / "sup:". The JSONL row uses `left`/`right`; the text rendering uses the role labels. The convention: JSONL is structural, text is human-facing.

## `_canonical.jq` updates

Add a top-of-file comment block enumerating the three shapes and their envelope contracts so future query authors don't have to read every existing query to learn the convention. No new helper functions — existing cluster_id helpers already cover all queries, and the envelope itself is just field naming. PR 2 may add helpers when full front-matter parsing lands; PR 1 keeps `_canonical.jq` light.

## `docs/pipeline-contract.md` updates

Add a new sub-section under "Cluster-query output contract" titled **"Cluster envelope (post-PR-1)"** that documents:

1. The three shapes and their required envelope fields.
2. The `shape:` per-row field and its values.
3. The `#! shape:` front-matter convention (single value or comma-separated for dual-shape queries).
4. The asymmetric-pair convention (left/right vs role labels in text).

The existing "Query-specific fields (decls, members, jaccard, ...)" sentence is updated to: "Query-specific payload fields are emitted as the query computes them; envelope fields (`members`, `left`, `right`) are reserved per the shape contract above."

## Test updates

The integration test suite (`pipeline/queries/_tests/test_queries_integration.sh`) has four sites referencing renamed fields:

| Line | Reference | Action |
|---|---|---|
| 420 | `.decls \| map(.arity)` (generic-arity-drift) | `→ .members \| map(.arity)` |
| 770–771 | Comments: `sort_by(-(.decls \| length))` | Update to `members` |
| 796 | Comment: `source-query sort_by(-(.decls \| length))` | Update to `members` |
| 1117–1120 | `.a.name`, `.b.name`, `.a.is_test`, `.b.is_test` (test-prod-drift) | Rename to `.left`/`.right` |

The `assert_jsonl_has_prefix` helper checks cluster_id prefix and uniqueness — not envelope fields — so it needs no update. The `cluster_has_touched` predicate in `touched-window-debt-summary.jq` uses `.decls[]` internally; the in-jq predicate updates as part of the query rename.

`test_canonical.sh` — no field references; unaffected.
`smoke_test_real_catalog.sh` — no field references; unaffected.
`docs/plans/118-F2-cross-repo-duplicates.md`, `plans/issue-128-touched-window-debt-plan.md` — historical planning documents using old field names. Out of scope (planning artifacts, not living code).

## Out of scope (deferred to subsequent PRs)

- Full front-matter (description, args, input-catalog, default-output-format) — PR 2.
- `manifest.toml` files for extractors — PR 2.
- gojq compatibility verification — between PR 2 and PR 3.
- Renderer dispatcher Go code — PR 4.
- `_canonical.jq` envelope-construction helpers — likely PR 2 once full front-matter is in.

## Validation

After applying the renames:

1. Run `pipeline/queries/_tests/test_queries_integration.sh` — every assertion should pass against the updated fixtures (the fixtures themselves are catalog inputs and are unaffected by the output-field rename).
2. Run `pipeline/queries/_tests/smoke_test_real_catalog.sh` on a representative catalog — verify queries execute without jq errors and produce non-empty output.
3. Diff JSONL output against a pre-PR-1 capture for one query (`exact-duplicates.jq`) on the same fixture, confirming the only differences are the renamed keys.
4. Grep across `.jq`/`.sh`/`.md` for residual `\.decls\b|\.a\.|\.b\.|\.sub\b|\.sup\b` to ensure full coverage.

## Estimated complexity

- Query edits: ~25 files, ~600 line delta (mostly substring substitutions on field names and text-mode templates).
- Documentation: ~80 lines added to `docs/pipeline-contract.md`, ~30 lines added to `_canonical.jq` header.
- Test updates: ~10 lines in `test_queries_integration.sh`.
- Total: ~720 lines added/changed. Well under the 1000-line PR target.
