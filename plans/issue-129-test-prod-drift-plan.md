# Plan — Issue #129: `is_test` flag + `test-prod-drift.jq`

Phase 2 child of #116. Schema delta (universal `is_test: bool` flag) plus a sibling cluster query that surfaces test/prod parity drift — fixture shapes diverging from the prod model they mirror.

## Why one PR, not two

The schema change and the consumer query are mutually load-bearing. Shipping the flag alone leaves dead bytes in the catalog with no query reading them (until #129's second PR), and the query depends on the flag existing. Bundle.

## Files map

| File | Change | Reason |
|---|---|---|
| `extractors/typescript/type-catalog.mjs` | Insert `isTestPath(relPath)` helper after `typeSig` (~line 124) and before the `idCounts` identifier-counter section (~line 126), matching the utilities-first structure of the file. Descend into test dirs always; remove `--include-tests` flag (and `INCLUDE_TESTS` constant and the `SKIP_DIRS.add('tests')` conditional and the `walkDir` skip on `*.test.*` / `*.spec.*`); add `is_test` field to every row via `pushBase`; stderr rollup gains an `is_test: <n>` count. | Schema delta and corresponding extractor behavior. |
| `pipeline/queries/test-prod-drift.jq` | NEW. Sibling of `near-duplicates-any.jq`, with XOR `is_test` filter and a lower default Jaccard (0.5). Prod side rendered first in text output. | The case-study finding (FSEntryRaw ↔ flowsheet) collapses cleanly into this bucket. |
| `pipeline/queries/_tests/fixtures/test-prod-drift.input.json` | NEW. Hand-built drift case + sharing case + back-compat case (rows lacking `is_test`). | TDD red-then-green on the query. |
| `pipeline/queries/_tests/fixtures/is-test-tree/` | NEW directory: small synthetic source tree for the extractor smoke test (`src/foo.ts`, `src/foo.test.ts`, `tests/integration/bar.ts`, `__tests__/baz.ts`, `__fixtures__/factory.ts`, `e2e/login.ts`, `src/fixtures/data.ts`, plus a `.spec.ts` and a `.mock.ts`). | Drives `assert_is_test_extractor` so we can assert path classification end-to-end. |
| `pipeline/queries/_tests/test_queries_integration.sh` | Add `assert_is_test_extractor` and `assert_test_prod_drift_*` checks; add `assert_jsonl_has_prefix test-prod-drift.jq …` and `assert_text_has_cid test-prod-drift.jq …` for the standard contract checks. | New query needs the same coverage as the existing ones. |
| `docs/pipeline-contract.md` | Add `is_test` to the example record + Required-fields list. New "Test path patterns" subsection under Conventions. Remove `--include-tests` from CLI signature. Strike the "Files matching `*.test.*`, `*.spec.*`" line from the default skip-list. | The contract is the cross-language coordination surface (#115). |
| `README.md` | New cluster-query table row for `test-prod-drift.jq`. | User-facing surface. |

## Open-questions disposition (from issue body §Open Questions)

1. **Configurable patterns?** — Defer. Contract is normative; no `--extra-test-pattern` flag yet. If real-world projects need an escape hatch we add it as a tiny addition later. Today's lock-in is cheap.
2. **Does `e2e/` count as test?** — **Yes**. The OQ §2 lean (`is_test=true` for `e2e/`) wins over the requirements-section exclusion. Reasoning: when in doubt, default to test=true; the absent-finding cost (e2e drift goes unnoticed) is higher than the false-positive cost (e2e flagged as test).
3. **Non-code fixtures (`*.json`, `*.sql`)?** — Out of scope for the TS extractor; contract is silent on data files.
4. **Asymmetry filter strictness.** — **XOR**, exactly one side `is_test`. Same-side pairs (two fixtures, two prod models) are different findings and don't belong in this bucket.
5. **`--include-tests` removal external impact.** — Issue body verified no external scripts reference it. Removing outright (no deprecation cycle) per project convention against backwards-compatibility shims.

## Test-path patterns (verbatim — normative in contract)

`isTestPath(relPath)` returns `true` if **any** of the following match:

**Filename patterns** (basename match):
- `*.test.<ext>` where `ext` ∈ {`ts`, `tsx`, `mts`, `cts`}
- `*.spec.<ext>` (same extension set)
- `*.fixture.<ext>` / `*.fixtures.<ext>`
- `*.mock.<ext>` / `*.mocks.<ext>`

**Directory patterns** (any path segment match, any depth):
- `tests`, `test`, `__tests__`, `__test__`
- `spec`
- `__mocks__`
- `__fixtures__`, `fixtures`
- `e2e`

Implementation: split `relPath` on `/`, check each segment against the dir set; check basename against the file regexes. Pure function, no I/O. Documented verbatim in `docs/pipeline-contract.md` Conventions section, with a language-agnostic-vs-language-specific split for #115.

## Query design — `test-prod-drift.jq`

Mirrors `near-duplicates-any.jq` (the package-unrestricted form) since drift can cross packages — a fixture in `apps/foo/tests/` legitimately drifts from `packages/shared/src/Model.ts`. Structural differences from `near-duplicates-any`:

1. **Candidate-set XOR filter** on `is_test`: `select(($a.is_test // false) != ($b.is_test // false))` immediately after candidate pair generation, **before** Jaccard. Cheaper to filter on a boolean than on a similarity ratio.
2. **Default threshold 0.5** (vs `near-duplicates-any`'s typical 0.7). Fixtures legitimately drop optional fields, dropping Jaccard; we want recall.
3. **Output ordering: prod side first.** Swap `$a` / `$b` in the output object if `$a.is_test == true`, so the rendered line always shows the non-test side first. The reader's mental model is "did the fixture drift from prod?" — anchoring on prod is the right framing.
4. **cluster_id format**: `test-prod-drift:LocA+LocB` via `cluster_id_sorted_pair`. (Despite the per-row prod-first display ordering, the cluster_id stays sorted — pair identity is symmetric.)
5. **Back-compat**: every reference to the flag uses `.is_test // false`. Older catalogs without the field flow through with both sides `false`, the XOR evaluates false, no pair emits. Graceful degradation.

## Sibling, not filter — locking in

Per issue body §Query placement, this is **not** a flag on `near-duplicates.jq`. Reasons relevant here:
- `near-duplicates.jq` is the general primitive every audit runs; changing its default output (or adding an awkward flag) is the wrong cost/benefit.
- Different default threshold (0.5 vs 0.7).
- Different output ordering (prod first vs sorted).
- Matches existing convention: every other clustering primitive has its own `.jq` file.

The sibling copy-pastes the Jaccard skeleton (~15 lines). Idiomatic for this codebase.

## TDD order

**Cycle A — extractor (`is_test` flag)**:
1. Create `pipeline/queries/_tests/fixtures/is-test-tree/` with the 8 file paths enumerated in the table above. Each file contains a minimal `export type Foo = { id: number }` so the extractor produces ≥1 row per file.
2. Add `assert_is_test_extractor` to `test_queries_integration.sh`. It runs `type-catalog.mjs --root <tree>` and uses a single-pass jq script to verify each `(file, expected_is_test)` pair. **Test fails** because `is_test` doesn't exist yet.
3. Implement `isTestPath` + walkDir change + `pushBase` field. Test passes.
4. Verify the `tests/integration/bar.ts` and `__tests__/baz.ts` files are extracted (not skipped) by asserting their rows are present.

**Cycle B — `test-prod-drift.jq` query**:
1. Write `test-prod-drift.input.json` fixture with at minimum:
   - Drift case: `User { id, name, email, created_at }` (prod, `is_test: false`) vs `UserFixture { id, name, email }` (test, `is_test: true`). Jaccard 0.75 → must surface at default 0.5.
   - Sharing case: same shape on both sides (Jaccard 1.0 → excluded by `< 1.0` clause).
   - Same-side pair: two test fixtures of each other. Must NOT emit (XOR filter).
   - Back-compat case: row with `.is_test` field absent. Must not crash; must not emit (XOR on `false != false`).
   - **Generated-row case**: a `generated: true` row paired with a prod row that would Jaccard ≥ 0.5 if not for the generated filter. Must NOT emit (generated filter strips the candidate set).
2. Add `assert_jsonl_has_prefix test-prod-drift.jq` and `assert_text_has_cid` checks.
3. Add `assert_test_prod_drift_baseline`: single-pass jq verifies the drift case is emitted with the expected `cluster_id` AND the expected prod-side-first ordering, and that no other pair emits.
4. Implement the query. Tests pass.

## Risks / known limitations (document in query header)

- **False positive class**: a test fixture deliberately mirroring prod for type-assertion isolation. Estimated 30–50% of emitted pairs in real codebases; absolute count per audit is small (single digits) so manual triage is acceptable.
- **No nominal link**: the query infers drift from name similarity; it can't tell two semantically related shapes (e.g., `User` ↔ `UserView`) from drift. Same limitation as `near-duplicates.jq`.
- **Generated-test code**: the catalog already filters `generated:true` rows via the `generated` predicate (added in candidate-set filter, mirroring `near-duplicates-any.jq`). No additional handling needed.

## Contract changes — exact edits

1. Insert `"is_test": false,` line into the example record block under the other booleans (next to `"touched_in_window"`).
2. Add `is_test` to **Required fields** list (alongside `name`, `kind`, `package`, `file`, `line`).
3. New subsection `### Test path patterns` under `## Conventions`. Lists the universal patterns (MUST), then language-specific extensions as MUST-when-applicable:
   - TypeScript: filename `.test.<ext>` / `.spec.<ext>` for `ext ∈ {ts,tsx,mts,cts}`; `.fixture(s).<ext>`; `.mock(s).<ext>`.
   - Python: `test_*.py`, `conftest.py`, `*_test.py`.
   - Go: `*_test.go`.
   - Swift: `Tests/` (capital T, SwiftPM convention); `XCTestCase`-subclass detection deferred (AST-based, permitted extension).
   - Rust: `tests/` integration dir; `#[cfg(test)]` modules (AST-based, permitted extension).
4. Strike "Files matching `*.test.*`, `*.spec.*`" from the default-skip list.
5. Strike the line "Use `--include-tests` to keep test directories in scope when auditing test-fixture duplication." Replace with "Test files are always extracted; filter with `select(.is_test | not)` to exclude post-hoc."
6. Update **CLI contract** signature: remove `[--include-tests]`.

## Rollout & migration

No data migration. Existing catalog JSONs simply lack the `is_test` field; all queries that touch it use `.is_test // false`. Catalogs regenerated post-PR get the field populated. Mention in commit body so anyone scripting against the extractor flag knows it's gone.
