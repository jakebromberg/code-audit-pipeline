# E — Operational safety: preflight + coverage + run-cross-repo-query wrapper

**Parent:** [#118 — Cross-repo queries — merging N catalogs across the org](https://github.com/jakebromberg/code-audit-pipeline/issues/118).
**Blocked by:** [A — Schema v2](118-A-schema-v2.md), [C — Substrate](118-C-substrate.md).
**Blocks:** F1, F2, F3 (every cross-repo query depends on the wrapper).

## 1. Context summary — why these are operational safety, not feature work

Parent issue #118 generalizes the two-root (`--root` + `--shared`) pattern to N=~30 sibling repos in the org. The merge model is intentionally dumb: each repo emits its own catalog object, and merging is a `jq -s 'map(.entries) | add'` at query time. That dumbness is virtuous — until two failure modes silently corrupt every cross-repo answer:

- **Extractor version skew.** If repo A's catalog was produced by TS extractor v1.x and repo B's by v2.x, the `shape_sig` normalization rules differ. Joining on `shape_sig` across A and B then produces *false negatives* (true duplicates whose sigs no longer match) or *false positives* (incidental sig collisions caused by changed normalization). The merged report still prints — it just lies. There is no in-query way to detect this; the only signal lives in each catalog's top-level `extractor` block.
- **Coverage gaps and staleness.** The issue explicitly chooses "merge proceeds with the missing repo absent" over fail-closed (most queries are still meaningful with 29/30 repos). But that choice is only safe if every report *prominently* declares what scope it ran over. A report that says "0 cross-repo collisions found" reads very differently when the substrate covered 30/30 vs. 12/30 repos. Likewise, a finding rooted in a week-old catalog of repo B (which has since renamed half its public API) is misleading without staleness annotation.

Neither query produces a finding. Both run *before* any finding and gate or annotate the report. They share a deployment model (run on every cross-repo query, in the same wrapper script), share a single source of input (the merged catalog stream plus the substrate's `index.json`), share a "header line" output convention, and are both ~50-line `.jq` files. Shipping them in one sub-issue keeps the integration wrapper (`run-cross-repo-query.sh`) as one PR and avoids the awkward intermediate state where coverage lands but version-preflight doesn't (or vice versa) and any cross-repo report can produce silently wrong output.

## 2. Functional requirements for `pipeline/preflight-versions.jq`

**Input** — the merged catalog stream as a JSON array of catalog objects (schema v2: each is `{repo, commit_sha, extractor: {name, version, language}, generated_at, scope, entries}`). Invocation: `jq -sf pipeline/preflight-versions.jq catalogs/*.json`.

**Output** — to stderr: a per-language table of "extractor versions seen across catalogs," e.g.

```
extractor versions in merge set (10 catalogs):
  typescript/type-catalog: v1.3.2 (6 repos), v1.3.5 (2 repos)
  python/type-catalog:     v0.2.0 (2 repos)
```

To stdout: nothing on success (so the wrapper script can pipe stdin-stdout cleanly), or a structured JSON refusal record on failure (`{ status: "refused", reason: "...", details: {...} }`) that downstream tools can capture without scraping stderr.

**Exit codes**

- `0`: all catalogs share the same major version within each language. Minor differences trigger a stderr warning but proceed.
- `1`: at least two catalogs in the same language have different major versions. Refuse to merge. Refusal message names the offending repos and versions.
- `1`: at least one catalog is missing the `extractor` block, or it's malformed (no `version` field, version doesn't parse as semver). This is a data-integrity signal — a catalog without extractor identity is unidentifiable. Refuse.

**Multi-language behavior** — major-bump comparisons are scoped *within* `extractor.language`. A TS extractor at v1.x and a Python extractor at v3.x is fine; they emit non-overlapping rows. The query groups by `extractor.language`, then compares within each language group. This is critical — a global "max major across all catalogs" check would refuse every multi-language merge.

**Semver parsing** — extractor versions follow semver (`vN.N.N` or `N.N.N`). The query parses out the major as the integer before the first `.`, falling back to the full string if it doesn't parse (and treating "doesn't parse" as a refusal — see malformed-extractor case). Don't try to handle pre-release tags; document that extractors must tag releases with bare semver.

**Performance budget** — runs once per cross-repo query invocation, on a single-pass scan of catalog headers (not entries). At 30 catalogs, <10ms.

## 3. Functional requirements for `pipeline/coverage.jq`

**Input** — two arguments:

1. The merged catalog stream (same as preflight).
2. The substrate's `index.json` manifest (path passed via `--slurpfile expected pipeline/expected-repos.json` or `--arg expected_path ...`). The `index.json` lists every repo *expected* in the org-wide merge — i.e., "what we expected" — while the catalog stream is "what we have." The diff between them is the coverage gap.

The question of "what we expected" needs a source of truth. **The substrate's `index.json` IS the source of truth** — it records the repos the substrate is tracking, and is the natural pin for "expected." A separate per-audit config file adds a second source of truth and forces consumers to keep them in sync. If a repo should be excluded from a particular query (e.g., archive repos), that's a query-level concern, not a coverage concern. Single source of truth: `index.json`.

**Output** — both:

1. A human-readable header (stderr or stdout depending on integration model — see §3.5 below) for inclusion in every cross-repo report:

   ```
   scope: 28/30 repos covered  |  catalog ages: 12h median, 7d max  |  2 missing, 1 stale (>7d), 0 errored
   missing: wxyc/wxyc-cards (last seen 2026-05-12), wxyc/playlist-archiver (never seen)
   stale (>7d): wxyc/dj-app (commit a1b2c3d, 2026-05-15)
   ```

2. A structured JSON object (stdout) that other queries can `--slurpfile` and project into their outputs:

   ```json
   {
     "scope": { "covered": 28, "expected": 30 },
     "covered": [{"repo": "wxyc/dj-site", "commit_sha": "...", "generated_at": "...", "age_hours": 9}],
     "missing": [{"repo": "wxyc/wxyc-cards", "reason": "absent"}],
     "stale": [{"repo": "wxyc/dj-app", "age_days": 10, "threshold_days": 7}],
     "errored": [{"repo": "wxyc/foo", "extractor_errors": 47}]
   }
   ```

**Fields surfaced**

- *Covered*: repo + commit_sha + generated_at + computed age.
- *Missing*: repos in `index.json` not present in merged stream.
- *Stale*: catalogs older than the stale threshold (default **7 days**, env-var override).
- *Errored*: repos where the catalog includes a top-level `extractor_errors` count above a threshold (this is a soft signal — extractor errors don't refuse the merge, but they should appear in the report header).

### 3.5 Integration mechanism — "first row in every report"

**Wrapper script `pipeline/run-cross-repo-query.sh`** — takes the query path and arguments, runs preflight first (exits if refused), then runs coverage (captures output to a header), then runs the actual query, prepending the header to its stdout.

Alternative considered: jq fragment with `include`. Rejected because every query author must remember to include it; can't enforce; the manifest path is awkward to pass as `--slurpfile` to every nested invocation. The whole point of these guardrails is that they are not opt-in. A query author should not be able to forget to include coverage; they should not be able to skip preflight. The wrapper script enforces it. The shell glue is ~30 lines and trivially testable with a golden-stdout fixture.

This also matches the case-study reproducibility footer convention (all pipeline invocations go through documented commands).

## 4. Noise filtering — `origin_package != null`

The "naming-by-accident" filter mentioned in the parent issue ("only report cross-repo collisions where at least one decl is from a published package") is *functionally* operational safety — without it, cross-repo `name-collisions` becomes 80%+ noise — but *mechanically* it's a query-level filter clause. Three options considered:

1. **Standalone `pipeline/queries/cross-repo-shadows.jq`** — a new query that extends `cross-package-shadows.jq` with the `origin_package != null` filter built in. Cons: another query to maintain; filter logic isn't reusable elsewhere.
2. **Inline filter in every cross-repo query** — each cross-repo query opens with `select(.origin_package != null)` where relevant. Cons: copy-paste; easy to forget; the filter rule lives in N places.
3. **Shared filter helper module `pipeline/lib/cross-repo-filters.jq`** — defines reusable jq functions (`def is_published: .origin_package != null;`, `def is_repo_local: .origin_package == null;`) that queries `include`.

**Recommendation: (3), shared helper module, owned by this sub-issue.** Coverage and preflight already justify a `lib/` directory (the wrapper script needs to source common shell functions too). The helper module's first occupants are the published-vs-local predicates plus the staleness threshold reader. Cross-repo queries (F1, F2, F3) then `include "lib/cross-repo-filters";` and use the named predicates. This sub-issue *defines* the helpers; the F sub-issues *consume* them.

## 5. Non-functional requirements

**Performance** — both queries run on every cross-repo invocation. Budget: <100ms each at 30 catalogs (30 × ~3KB header data = ~100KB scanned per query; jq does this in single-digit ms). Coverage parses entries only for the `extractor_errors` count, not the full entry stream — keep it header-only.

**Failure modes**

- *Corrupt catalog JSON* — the wrapper script should validate JSON parseability per file before invoking jq. A corrupt file gets logged as "errored" in the coverage report and excluded from the merged stream. The remaining 29 catalogs proceed; the report header flags the corruption. *Never crash the whole report on one bad file.*
- *Missing extractor block* — handled by preflight (refuse). This is stricter than corrupt-JSON: a parseable catalog with no extractor identity is a known-bad input, not an accident.
- *Empty merged set* — coverage prints "scope: 0/30 repos covered," wrapper exits 1 (no useful query possible). Distinguish from "preflight refused" via different exit codes (e.g., 1 = refused, 2 = empty merge set).

## 6. KPIs

1. **Cross-major version skew is refused.** Test: merge two catalogs with TS extractor v1.x and v2.x; wrapper exits non-zero; stderr message names both repos and versions. *Pass when 100% of skew cases refuse.*
2. **Coverage header appears in 100% of cross-repo query outputs.** Test: invoke every cross-repo query via the wrapper; grep stdout for the coverage header line. *Pass when 100% of invocations produce a header before any finding.*
3. **Stale catalogs (default >7 days) are visually flagged in every report.** Test: fixture with one stale + one fresh catalog; header includes "stale" in the summary line. *Pass when stale repos appear in the structured JSON `.stale` array.*
4. **Malformed/missing extractor block refuses the merge.** Test: fixture catalog with `extractor: null`, `extractor: {}`, and `extractor: {name: "x"}` (no version). All three refuse. *Pass when all three refuse with distinct stderr messages.*
5. **Published-name filter reduces cross-repo name-collisions noise by ≥80% on the wxyc fixture.** Test: run the cross-repo name-collisions query against a merged 30-catalog fixture both with and without the `is_published` filter; count cluster rows. **Validate this estimate empirically — if the real reduction is 50% or 95%, document the actual number and adjust the threshold message.** (This estimate is a hypothesis until a real org-wide catalog exists; treat as "validate during fixture construction.")

## 7. Testing strategy

**Fixture catalogs** — under `extractors/typescript/test/cross-repo-fixtures/`:

- `repo-a-v1.2.json`, `repo-b-v1.3.json`, `repo-c-v2.0.json` — minor & major skew.
- `repo-d-missing-extractor.json`, `repo-e-malformed-extractor.json` — refusal cases.
- `repo-f-fresh.json`, `repo-g-stale-10d.json` — staleness threshold.
- `repo-h-py-v0.2.json` alongside `repo-a-v1.2.json` — multi-language merge (must not refuse on TS-v1 + Py-v0).
- A `cross-repo-fixtures/index.json` listing 10 expected repos, of which only 8 have catalog files — exercises the missing path.

**Unit tests**

- `test_preflight_refuses_major_skew.sh` — invokes the query against v1.2 + v2.0; asserts exit 1 and refusal message.
- `test_preflight_warns_minor_skew.sh` — invokes against v1.2 + v1.3; asserts exit 0 and stderr contains "warning."
- `test_preflight_refuses_missing_extractor.sh` — three variants of malformed.
- `test_preflight_per_language.sh` — TS v1 + Py v0 + Swift v0; exits 0.
- `test_coverage_reports_missing.sh` — index says 10 repos, fixture has 8; coverage `.missing` has 2 entries.
- `test_coverage_flags_stale.sh` — fixture with `generated_at` 10 days ago; coverage `.stale` non-empty.

**Wrapper-script integration test** — `test_wrapper_golden_stdout.sh`: run `pipeline/run-cross-repo-query.sh` with a known-good fixture and a known query (e.g., `name-collisions.jq` adapted for cross-repo), compare stdout against `expected-output.txt`. Update the golden file when the report format intentionally changes.

**Fixture-driving regression** — KPI #5 (noise filter ≥80%) becomes a regression test: a merged fixture + the query produces a count, asserted to be below a threshold.

## 8. Implementation recommendations

**Proposed files**

- `pipeline/preflight-versions.jq` — the preflight refusal logic.
- `pipeline/coverage.jq` — the coverage computation.
- `pipeline/run-cross-repo-query.sh` — the integration wrapper. Documents itself with `--help` showing the standard invocation.
- `pipeline/lib/cross-repo-filters.jq` — shared helper module (`is_published`, `is_repo_local`, `stale_threshold_days`).
- `pipeline/expected-repos.json` — pointer into the substrate's `index.json`; document the convention.

**File-header documentation** — each .jq file starts with the project's standard header block (per `cross-package-shadows.jq` precedent):

```
# preflight-versions.jq — refuse cross-repo merge on extractor major-version skew.
#
# Run:  jq -sf pipeline/preflight-versions.jq catalogs/*.json
# Exit: 0 = OK or minor skew (stderr warning); 1 = refused.
# Schema: v2 (requires top-level extractor.{name,version,language} per catalog).
```

**Stale threshold configuration** — three options:

- *Constant in coverage.jq*: simple, but changing it requires editing the query.
- *CLI argument*: `--argjson stale_days 7`. Verbose at every invocation.
- *Env var*: `CROSS_REPO_STALE_DAYS=7`. Sticky per shell session.

**Recommendation: env var with default of 7 in the .jq file** (`($ENV.CROSS_REPO_STALE_DAYS // "7") | tonumber`). The wrapper script reads the env var and passes it as `--argjson` so the .jq file itself stays argument-driven and testable. Document the var in the wrapper's `--help` and in the .jq header.

**Standalone PR.** Strong recommend shipping this as its own PR, separately from any cross-repo *query*. The PR delta is small (~200 lines: two .jq files + one shell wrapper + tests + docs), defensive in nature, and it must land before any cross-repo query is run by anyone other than the author. Bundling it with a query PR delays the safety net.

## 9. Coordination with substrate (C) and queries (F1/F2/F3)

Strict ordering of work:

```
schema v2 lands (A)
        |
        v
substrate ships (C: index.json + R2 layout)
        |
        v
PREFLIGHT + COVERAGE + WRAPPER  ← this sub-issue, lands here
        |
        v
cross-repo queries (F1/F2/F3) start using the wrapper
```

Why this order is non-negotiable:

- **Preflight depends on schema v2.** Without the `extractor` top-level block, there's nothing to check.
- **Coverage depends on the substrate.** Without `index.json`, there's no notion of "covered" or "missing" or "stale."
- **Cross-repo queries depend on this sub-issue.** A cross-repo query that runs without preflight can produce silently wrong results. A cross-repo query that runs without coverage produces a report whose scope the consumer can't assess. The wrapper script and helper module must exist before any cross-repo query author starts wiring up F1/F2/F3.

If A and C land roughly together, this sub-issue can start in parallel with the F sub-issues as long as it merges first. F authors should not have to do any of this safety work themselves — they consume the wrapper script and the helper module's predicates.

## 10. Open questions / decisions still needed

1. **Extractor versioning policy.** Strict semver enforcement (parser refuses non-semver tags) or document-and-trust? **Lean: document-and-trust.** A malformed version tag refuses the merge with a clear "couldn't parse version" message, which is recoverable in seconds. Document the convention in `docs/pipeline-contract.md` alongside the [A](118-A-schema-v2.md) changes.
2. **Default stale threshold:** **7 days** per resolved decisions.
3. **Should coverage data be cached or recomputed every time?** **Lean: recompute.** Coverage is sub-100ms; caching introduces a "stale coverage report" failure mode that's worse than the cost.
4. **Where does the stale threshold's "now" come from?** UTC system time of the wrapper-script invocation. Document explicitly — the report header should print the comparison timestamp so consumers in different timezones can interpret "age" unambiguously.
5. **Is `extractor_errors` count actually emitted by extractors today?** The TS extractor emits stderr stats. Need a top-level structured `scope.errors` field added to schema v2; otherwise coverage's "errored" field can't be populated. Coordinate with [A](118-A-schema-v2.md).
6. **What does "absent" mean in `index.json` vs. "never seen"?** If a repo is in `index.json` but its catalog file is missing from the bucket, that's "missing." If a repo is not in `index.json` at all, it's not expected and shouldn't be reported. Document the contract.

## 11. Sub-ticket boilerplate

**Title:** `Operational safety — preflight-versions.jq, coverage.jq, run-cross-repo-query wrapper`

**Direction:**

> Before any cross-repo query against merged sibling-repo catalogs can be trusted, the merge needs two guardrails: a preflight that refuses to merge catalogs from extractors at incompatible major versions, and a coverage report that surfaces which repos are present, which are missing, and which catalogs are stale (>7 days, env-overridable). Both are header-only operations on the substrate's `index.json` and each catalog's top-level `extractor` block; both run before every cross-repo query via a thin shell wrapper (`pipeline/run-cross-repo-query.sh`) so they cannot be bypassed. This sub-issue also ships the shared filter helper module (`pipeline/lib/cross-repo-filters.jq`) — initial occupant: the `is_published` predicate for cross-repo name-collision noise reduction — which the cross-repo queries sub-issues will consume. The whole package is one small defensive PR that must land after schema v2 (A) and substrate (C), but before any cross-repo query (F1/F2/F3) is used in anger.

## Key file references

- [`/Users/jake/Developer/code-audit-pipeline/docs/pipeline-contract.md`](../pipeline-contract.md) — current schema; v2 deltas described in [A](118-A-schema-v2.md)
- [`/Users/jake/Developer/code-audit-pipeline/CLAUDE.md`](../../CLAUDE.md) — jq gotchas, conventions
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/cross-package-shadows.jq`](../../pipeline/queries/cross-package-shadows.jq) — header-format precedent
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/exact-duplicates.jq`](../../pipeline/queries/exact-duplicates.jq) — clustering output convention
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/name-collisions.jq`](../../pipeline/queries/name-collisions.jq) — the query that gets ≥80% noise reduction via `is_published` filter
- [`/Users/jake/Developer/code-audit-pipeline/pipeline/queries/near-duplicates.jq`](../../pipeline/queries/near-duplicates.jq) — `--argjson` precedent for the staleness threshold

**Cross-issue dependencies:** [A](118-A-schema-v2.md) schema deltas (preflight prerequisite), [C](118-C-substrate.md) substrate (`index.json` source of truth), #117 (commit_sha per-row for the SHA-pair column in cross-repo finding rows), and consumers in [F1](118-F1-consumers-of.md), [F2](118-F2-cross-repo-duplicates.md), [F3](118-F3-renamed-consumers.md).
