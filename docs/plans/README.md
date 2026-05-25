# Plans for issue #118 — Cross-repo queries across the org

Parent ticket: [#118 — Cross-repo queries — merging N catalogs across the org](https://github.com/jakebromberg/code-audit-pipeline/issues/118).

This directory holds the design briefs for the lines of work embedded in #118. Each brief is a self-contained design memo: context, requirements (functional and non-functional), KPIs, testing strategy, implementation recommendations, and the sub-ticket boilerplate. The briefs are the substrate for the GitHub sub-issues filed under #118.

> **⚠️ Repository state caveat — read before implementing.** The briefs in this directory were drafted against a stale snapshot of the repo (local `main` was 12 commits behind `origin/main` at drafting time). Several proposals overlap with already-shipped work on `origin/main` that the briefs do not cite. Before implementing any brief, **read this section** and reconcile the proposed work against the current state.
>
> **Already shipped (read these first):**
>
> - **`pipeline/queries/_canonical.jq`** — the `lib/` helper module pattern proposed in [E](118-E-operational-safety.md) already exists here. It provides `cluster_id_*` helpers, `loc_key`, `output_format`, `tokens_of`, `type_of`. Add new shared helpers here rather than creating `pipeline/lib/cross-repo-filters.jq`.
> - **`pipeline/queries/cross-catalog-name-collisions.jq`** — a 2-catalog cross-language join already exists (`--slurpfile left --slurpfile right`), with `FIELD_NAMES_MATCH` / `FIELD_NAMES_DIVERGE` / `COMPARISON_UNAVAILABLE` verdict categories. [F2](118-F2-cross-repo-duplicates.md) should generalize this from N=2 to N=30 and add the canonical-shadow classification, not start from scratch. The verdict-category convention is reusable.
> - **Substrate-emitted `cluster_id` convention** — every query in `pipeline/queries/` precomputes a stable, content-addressed `cluster_id` via `_canonical.jq` helpers. `docs/pipeline-contract.md` §"Cluster-query output contract" (lines 320–397) is authoritative. F1, F2, F3 must follow this convention; the briefs do not currently reference it.
> - **`OUTPUT_FORMAT=jsonl` mode** — every query supports both text and JSONL output via `output_format` from `_canonical.jq`. F1/F2/F3 must support both.
> - **Multi-catalog substrate** — the contract has four catalog files today: `type-catalog.json`, `function-catalog.json`, `file-hashes.json`, `package-graph.json`. The "schema v2 wrapper" in [A](118-A-schema-v2.md) must apply to all four (or be scoped to type-catalog with an explicit punt on the others).
> - **`fields_structured`** — already added to the type-catalog contract (V7 §6.1). Each member is split into `{ name, type, is_optional, is_static }`. The `field_names_sig` proposal in [A](118-A-schema-v2.md) is a derived value of `fields_structured`; consider whether to compute it at extractor time or in `_canonical.jq` as a helper function `field_names_sig(.fields_structured)`.
> - **Swift extractor (`extractors/swift/Sources/swift-catalog/`)** — already exists with `PackageGraphExtractor`, `TypeCatalogVisitor`, `FunctionCatalogVisitor`, `Walker`. [B](118-B-imports-kind.md)'s cross-language contract section is partially obsolete; the Swift extractor is shipped, not future work.
> - **TypeScript function-catalog (`extractors/typescript/function-catalog.mjs`)** — also already shipped. The "imports kind" in [B](118-B-imports-kind.md) is for the type-catalog; function-catalog import handling is a separate question.
> - **Test infrastructure (`pipeline/queries/_tests/`)** — has `test_canonical.sh`, `test_queries_integration.sh`, `smoke_test_real_catalog.sh`, and fixtures. The "synthetic fixtures + golden outputs" testing strategy in F1/F2/F3 should go here, not under a new `fixtures/` directory.
>
> **Concrete reconciliation work needed before filing implementer-ready issues:**
>
> | Brief | Update needed |
> |---|---|
> | [A](118-A-schema-v2.md) | Apply schema v2 to **all four catalog files**, not just type-catalog. Reconcile `field_names_sig` with existing `fields_structured`. Reference V7 §6.1 conventions. |
> | [B](118-B-imports-kind.md) | Drop the "cross-language contract" Python/Swift sections from `Future work` — Swift extractor ships. Specify whether function-catalog needs an imports kind too. |
> | [C](118-C-substrate.md) | Note that publishing means publishing **a directory of catalogs per repo**, not one catalog file. Index.json schema needs a `catalogs: [...]` array per repo. |
> | [D](118-D-ci-publication.md) | `audit-core` composite must invoke 2–4 extractors per language (type + function + file-hash + package-graph for Swift), not one. |
> | [E](118-E-operational-safety.md) | Add `is_published` and other helpers to `pipeline/queries/_canonical.jq`, not a new `lib/cross-repo-filters.jq` file. Update file references accordingly. |
> | [F1](118-F1-consumers-of.md) | Use `cluster_id` convention (e.g., `cluster_id_single_name("consumers-of"; .name)`). Include `_canonical.jq`. Support JSONL mode. Fixture location: `pipeline/queries/_tests/fixtures/`. |
> | [F2](118-F2-cross-repo-duplicates.md) | Generalize `cross-catalog-name-collisions.jq` from N=2 to N=30 rather than greenfield. Inherit the verdict-category convention. Same `cluster_id` + JSONL story as F1. |
> | [F3](118-F3-renamed-consumers.md) | Same `cluster_id` + JSONL story. Coordinate with the rename-detection plan in [#117](https://github.com/jakebromberg/code-audit-pipeline/issues/117). |
>
> **What's still load-bearing in the briefs even after this reconciliation:** the decomposition into 8 lines of work (A through F3), the dependency graph, the resolved decisions (R2 / public-read / 7-day stale / `field_names_sig` ships with v2), the KPIs, the testing strategies, the open questions, and the cross-cutting analysis. The implementation file paths and convention references need updates per the table above; the design substance does not.

## Lines of work

| Slug | Title | Depends on | Status |
|---|---|---|---|
| [A — Schema v2](118-A-schema-v2.md) | Wrap catalog in metadata object; add `repo`, `commit_sha`, `extractor`, `origin_package`, `field_names_sig`, top-level `schema_version: 2`. Refit the four existing `.jq` queries to `.entries`. | — | Plan |
| [B — Imports kind](118-B-imports-kind.md) | New `kind: "import"` rows in the TypeScript extractor (consumer-edges, not declarations). Bare-specifier resolution in v1; ships behind `--include-imports`. | A | Plan |
| [C — Catalog substrate](118-C-substrate.md) | Cloudflare R2 landing zone with `index.json` + `by-repo/<repo>/{latest.json, SHA-keyed}` layout. `fetch-catalogs.sh`, `publish-catalog.sh`, `refresh-index.mjs` (reconcile-from-listing). | — | Plan |
| [D — Per-repo CI publication](118-D-ci-publication.md) | Reusable `audit-core` composite action (shared with #120) + `publish-catalog-reusable.yml`. Per-repo opt-in is ~10 lines. OIDC-to-IAM auth. | C | Plan |
| [E — Operational safety](118-E-operational-safety.md) | `preflight-versions.jq` + `coverage.jq` + `lib/cross-repo-filters.jq` (`is_published`) + `run-cross-repo-query.sh` wrapper. Non-bypassable. | A, C | Plan |
| [F1 — Q1 `consumers-of.jq`](118-F1-consumers-of.md) | Group import rows by `(origin_package, name)`; list importing `(repo, file, line)`; sort by consumer breadth. | A, B, E | Plan |
| [F2 — Q2 `cross-repo-duplicates.jq`](118-F2-cross-repo-duplicates.md) | Same-language (`shape_sig`) + cross-language (`field_names_sig`) modes. Classify clusters as shadow-of-canonical vs independent-reinvention. Cross-repo generalization of `cross-package-shadows.jq`. | A, E | Plan |
| [F3 — Q3 `renamed-consumers.jq`](118-F3-renamed-consumers.md) | Two-stage rename + anti-join. Shape-equality only in v1 (no Jaccard fallback). Fixture-testable before #117 ships. | A, B, E, #117 | Plan |

## Dependency graph

```
                                         ┌─> F2 (cross-repo-duplicates)
            ┌─ A (schema v2) ────────────┤
            │                            ├─> E (preflight + coverage)
            │                            │     └─> F1, F2, F3 use the wrapper
            │                            │
#118 ───────┤                            └─> B (imports kind) ─> F1 (consumers-of)
            │                                                ─> F3 (depends also on #117)
            │
            │   ┌─ C (substrate) ────────┐
            └───┤                         │
                └─ D (per-repo CI) ───────┘
                       │
                       └─ shares `audit-core` composite with #120
```

**Strict ordering** — A must land first (the schema is the lingua franca). C and D are independent infrastructure and can ship alongside B. E must land after A and C, before any F. F2 is the first cross-repo finding to demo on (A + E) alone. F1 needs B; F3 needs B + #117.

## Resolved decisions (apply across briefs)

- **Storage backend:** Cloudflare R2 (S3-compatible API, zero egress, ~$0.015/GB). Implementation works against AWS S3 unchanged if R2 is later swapped out.
- **Catalog read access:** public-read on the bucket. Removes auth setup as adoption friction; safe because the source repos are public on GitHub anyway.
- **Stale catalog threshold:** 7 days (env-var overridable). A 7-day-old catalog suggests the repo's CI dropped or the substrate's fetch failed.
- **`field_names_sig`:** ships in the same PR as the schema v2 wrapper change. Compute it in the TS extractor now (~5 lines); avoids a second schema bump before #115's first non-TS extractor lands.

## Conventions used in the briefs

- File paths cited use the project's absolute paths (`/Users/jake/Developer/code-audit-pipeline/…`) so an implementer with the repo open can jump directly.
- "Schema v2" refers to the wrapper change defined in [118-A-schema-v2.md](118-A-schema-v2.md). Any brief that says "depends on schema v2" depends on that PR landing first.
- KPIs are concrete and measurable. Where a brief estimates a number (e.g., "≥80% noise reduction"), the brief flags it as a hypothesis to validate against the first real fixture.

## See also

- [#117 — Time: catalog snapshots and structured diffs](https://github.com/jakebromberg/code-audit-pipeline/issues/117) — the temporal layer F3 depends on.
- [#115 — Breadth: language extractors](https://github.com/jakebromberg/code-audit-pipeline/issues/115) — the cross-language work that `field_names_sig` exists for.
- [#120 — Dev-flow integration](https://github.com/jakebromberg/code-audit-pipeline/issues/120) — shares the `audit-core` composite action with D.
