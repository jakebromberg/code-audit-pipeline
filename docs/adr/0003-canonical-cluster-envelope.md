# Render reports from JSONL via shape-typed dispatch

**Status:** Accepted. Terminology refined in ADR-0007 — this wrapper is referred to as the "cluster envelope" in cross-cutting docs to distinguish from #141's "catalog envelope."

Every query declares a `shape` in its front-matter — `cluster`, `pair`, or `metric` — and emits JSONL conforming to that shape's envelope. The binary's markdown renderer dispatches on `shape` and consumes JSONL exclusively; it never concatenates text from queries' text-mode output. Cluster counts come from JSONL row counts. Text in the report is rendered from structured data by the binary, not by re-invoking the query in text mode.

## Considered Options

- **Concatenate verbatim text.** The obvious shape. Couples reports to query text format — changing a query's text changes every prior report. Counts also require running each query twice (once for text, once for JSONL row count). Two coupled failure modes.
- **Per-query markdown renderers in the binary** (F1). N renderers for N queries. Decoupling achieved but at high per-query cost; every new query requires both a jq implementation and a binary-side markdown renderer.
- **Per-query markdown templates declared in front-matter** (F3). Introduces a new template grammar inside `#!` lines for the marginal cost of writing renderers in Go.
- **Shape-typed dispatch over a canonical envelope** (chosen). Three renderers — `cluster`, `pair`, `metric` — cover every existing query and most plausible additions. Adding a query that fits an existing shape requires no renderer change. A genuinely novel shape requires one new dispatcher entry.

## Consequences

- The JSONL envelope is a stable contract. Existing queries undergo a one-time field normalization (`decls` → `members`, `a`/`b` → `left`/`right`, etc.) under PR 1 of the migration plan. After that, field names are pinned and any future change requires a `catalog_format` bump.
- Both the markdown report and the V7 agent layer consume the same JSONL. The schema work pays double — agents that consume cluster output get a uniform contract regardless of which query produced the row.
- Interactive text mode (`audit query exact-duplicates` on a TTY) is unaffected. The text rendering remains inside each `.jq` file's branch on `output_format`. Only the report path routes through JSONL.
- Genuinely novel query output shapes require either a new dispatcher (one Go function plus a `shape:` value addition) or an explicit text-only opt-out where the query is excluded from `audit report`.
