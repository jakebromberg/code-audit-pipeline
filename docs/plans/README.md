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

| Slug | Brief | Filed as | Priority | Blocked by | Status |
|---|---|---|---|---|---|
| A — Schema v2 | [118-A](118-A-schema-v2.md) | — | — | — | **Not filed under #118** — covered externally by **#141** (catalog 1.0→1.1 envelope, `symbol_id`, extractor provenance) + **#137** (Schema v2 ratification, `language_data.<lang>.*`). `field_names_sig` lands as part of that work. |
| B — Imports kind | [118-B](118-B-imports-kind.md) | **#152** | P1 | #137, #141 | Filed |
| C — Catalog substrate | [118-C](118-C-substrate.md) | **#153** | P1 | — | Filed |
| D — Per-repo CI publication | [118-D](118-D-ci-publication.md) | **#154** | P2 | #153 | Filed (coordinates with **#123** for the shared `audit-core` composite) |
| E — Operational safety | [118-E](118-E-operational-safety.md) | **#155** | P2 | #153, #137, #141 | Filed |
| F1 — Q1 `consumers-of.jq` | [118-F1](118-F1-consumers-of.md) | **#156** | P3 | #152, #155, #137, #141 | Filed |
| F2 — Q2 `cross-repo-duplicates.jq` | [118-F2](118-F2-cross-repo-duplicates.md) | **#157** | P3 | #155, #137, #141 | Filed (ships first among the F queries) |
| F3 — Q3 `renamed-consumers.jq` | [118-F3](118-F3-renamed-consumers.md) | **#158** | P4 | #152, #155, #137, #141, #142, #148 | Filed |

All filed sub-issues are linked as native sub-issues of #118 and use GitHub's native "blocked by" dependencies — see #118's tracker section for the parent-side view.

## Dependency graph

```
External (under #115 / #117):
  #137 (Schema v2 ratify) ──┐
  #141 (Schema 1.0 → 1.1) ──┼──> #152, #155, #156, #157, #158
  #142 (Snapshot store) ────┤
  #148 (Catalog diff) ──────┴──> #158 only

Under #118:
  #153 (R2 substrate) ──┬──> #154 (per-repo CI publish)   [shares audit-core with #123]
                        └──> #155 (ops safety: preflight + coverage)
                                  │
                                  └──> #156 (F1), #157 (F2), #158 (F3) — every cross-repo query runs via the wrapper

  #152 (imports kind) ──┬──> #156 (F1 consumers-of)
                        └──> #158 (F3 renamed-consumers)

  #157 (F2 cross-repo-duplicates) — first cross-repo finding deliverable; only needs #155 + the external schema work
```

**Strict ordering** — #137 + #141 must land first (the schema is the lingua franca). #152 and #153 are independent and can ship in parallel. #154 needs #153; #155 needs #153 + the external schema. #157 is the first F-query to ship (only needs #155 + external schema). #156 also needs #152. #158 also needs #142 + #148 from #117's tree.

## Resolved decisions (apply across briefs)

- **Storage backend:** Cloudflare R2 (S3-compatible API, zero egress, ~$0.015/GB). Implementation works against AWS S3 unchanged if R2 is later swapped out.
- **Catalog read access:** public-read on the bucket. Removes auth setup as adoption friction; safe because the source repos are public on GitHub anyway.
- **Stale catalog threshold:** 7 days (env-var overridable via `CROSS_REPO_STALE_DAYS`). A 7-day-old catalog suggests the repo's CI dropped or the substrate's fetch failed.
- **`field_names_sig`:** ships as part of the external schema work (#137 / #141), not as a standalone change under #118.

## Conventions used in the briefs

- File paths cited use the project's absolute paths (`/Users/jake/Developer/code-audit-pipeline/…`) so an implementer with the repo open can jump directly.
- "Schema v2" in the briefs refers to the wrapper-object change; the actual implementation lands under #141 (envelope, `symbol_id`, extractor provenance) + #137 (two-tier ratification). Any brief that says "depends on schema v2" depends on those two tickets landing.
- KPIs are concrete and measurable. Where a brief estimates a number (e.g., "≥80% noise reduction"), the brief flags it as a hypothesis to validate against the first real fixture.

## See also

- [#117 — Time: catalog snapshots and structured diffs](https://github.com/jakebromberg/code-audit-pipeline/issues/117) — provides #141 (schema envelope), #142 (snapshot store), and #148 (diff algorithm) that several #118 children depend on.
- [#115 — Breadth: language extractors](https://github.com/jakebromberg/code-audit-pipeline/issues/115) — provides #137 (Schema v2 ratification) that all #118 children depending on schema work block on.
- [#120 — Dev-flow integration](https://github.com/jakebromberg/code-audit-pipeline/issues/120) — provides #123 (PR-comment Action) that shares the `audit-core` composite with #154.
