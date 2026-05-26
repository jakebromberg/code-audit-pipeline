# Issue #126 — generic-parameter audit plan

Closes [#126](https://github.com/jakebromberg/code-audit-pipeline/issues/126). Parent: [#116](https://github.com/jakebromberg/code-audit-pipeline/issues/116) (Phase 1 — zero schema delta).

The issue body already carries the design memo, KPIs, test plan, and jq sketches. This plan resolves the four "Open Questions" the body lists, fixes the implementation paths against the current substrate, and locks in the test matrix before any `.jq` is written.

## Deliverables

Two query files plus matching tests, fixture, and a README row each. Both files target the existing type-catalog schema — zero extractor delta.

| File | Purpose | LOC budget |
|---|---|---|
| `pipeline/queries/generic-arity-drift.jq` | Group declarations by `.name`; flag groups whose `generics` arities are not all equal. Deterministic — output is a function of the schema's `generics` field. | ~30 |
| `pipeline/queries/generic-convention-bound.jq` | Per-row regex residue check: extract `[A-Z]\w*` identifiers from `fields[]` right-of-colon, subtract row's `generics` + built-in allowlist, flag if any residue token looks like a type parameter (`T`, `K`, `V`, `U`, `R`, `E`, or `T[A-Z]\w*`). Heuristic — header docstring says so, with upgrade path to the structured `type_refs` work tracked in #146 (the original #131 design folded into the schema v1.1 edges work). | ~45 |
| `pipeline/queries/_tests/fixtures/generics.input.json` | Hand-tuned plant catalog covering the seven test cases enumerated in the issue body. | ~25 lines JSON |
| `pipeline/queries/_tests/test_queries_integration.sh` | Two `assert_jsonl_has_prefix` calls + two `assert_text_has_cid` calls + one semantic helper per query. | +60 lines |
| `README.md` | Two new rows in the Cluster queries table. | +2 lines |

## Resolutions to the issue's open questions

The issue body ends with four open questions. Resolutions, with rationale:

1. **Parameterizable built-in list?** Hardcode the ~35-entry TypeScript baseline (the issue body lists 30; add `Iterable`, `AsyncIterable`, `Iterator`, `Generator`, `Tuple`). Project-specific extension goes through `EXTRA_BUILTINS` env var as a comma-joined string — matches the `OUTPUT_FORMAT` / `PACKAGE` / `KIND_PREFIX` env-knob convention already established in `migration-progress.jq` and `shape-sig-frequency.jq`. *Drizzle / Zod ambient globals (`InferSelectModel`, `z.infer`, `JSX.Element`) are project-specific; making them required would punish other-codebase reuse.*
2. **Same name, same arity, different parameter names** (e.g., `Repository<T>` vs `Repository<K>`)? Out of scope for arity-drift — TypeScript treats those as equivalent and the issue's own recommendation is to skip. If a downstream consumer needs it, a `generic-param-name-drift.jq` sibling can be added later under #116.
3. **Convention-bound query reporting non-typeparam-shaped residue** (e.g., `["User", "OrderId", "ProductId"]`)? Out of scope. That's a cohesion question, not a parameter-binding question.
4. **Cross-kind same-name grouping in arity-drift:** restrict to `kind in {interface, type-alias-object, type-alias-union, type-alias-intersection, type-alias-other}`. Excludes `zod-object`, `drizzle-table`, `type-alias-infer-model` — those don't carry user-authored `generics` in any of the existing extractor outputs, so cross-kind groups including them would be noise. Implementation: `select(.kind | startswith("interface") or startswith("type-alias"))` — matches the contract's "keep prefix conventions" guidance in `docs/pipeline-contract.md`.

## Fixture (`generics.input.json`)

One hand-tuned array matching the issue's seven test cases. Both queries consume it.

| # | Row | Arity-drift expected | Convention-bound expected |
|---|---|---|---|
| 1 | `Repository<T>` interface | participant | clean (T is bound) |
| 2 | `Repository<T,K>` interface | participant (cluster with #1) | clean (T,K bound) |
| 3 | `SyncResult` type-alias-object, `generics: null`, fields `[ok:boolean, stats:TStats]` | not participant (single decl) | flagged (`TStats` unbound, matches `T[A-Z]\w*`) |
| 4 | `Bar<T>` with `fields: [x:T]` | not participant | clean (T is bound) |
| 5 | `Baz` with `fields: [x:Date, y:Promise<string>]` | not participant | clean (built-in subtraction) |
| 6 | `Order` with `fields: [user:User, id:OrderId]` | not participant | clean (User/OrderId don't match typeparam regex — *precision protection*) |
| 7 | `Foo` interface `generics:"T"` + `Foo` type-alias-object `generics:"T,U"` | participant (cross-kind, both prefixes pass) | clean |
| 8 | `BuiltinExhaustion` with every built-in in the allowlist in a field | not participant | clean (no residue after built-in subtraction) |
| 9 | `BackfillJob<TInput>` with `fields: [input:TInput, output:TOutput]` | not participant (single decl) | flagged (`TOutput` unbound) |

The fixture also adds two negative-control rows that exist purely to confirm the arity-drift kind filter:
- `ShouldNotGroup` as `zod-object` with `generics: null`, and `ShouldNotGroup` as `drizzle-table` with `generics: null`. Both same name, both zero arity → arity-drift would group them by name *but the kind filter excludes both, so no row*. This pins the open-question-4 resolution.

## Test additions to `test_queries_integration.sh`

Mirror the migration-progress structure:

1. **Smoke** (prefix + uniqueness): `assert_jsonl_has_prefix generic-arity-drift.jq` and `assert_jsonl_has_prefix generic-convention-bound.jq` against `GENERICS_FIXTURE`.
2. **Text mode cid=**: `assert_text_has_cid` for both.
3. **Semantic — arity drift**: a helper `assert_generic_arity_drift_semantic(name, expected_arities_csv)` (matches `assert_migration_progress_semantic` naming pattern) that asserts the named cluster row exists and its decls' arities (sorted, joined) match. Use it on:
   - `Repository` → `1,2`
   - `Foo` → `1,2`
   - `SyncResult` absent (single decl ⇒ no row)
   - `ShouldNotGroup` absent (kind filter)
4. **Semantic — convention-bound**: a helper `assert_generic_convention_bound_semantic(name, expected_suspects_csv)` that asserts the row exists with the named suspect set. Use it on:
   - `SyncResult` → `TStats`
   - `BackfillJob` → `TOutput`
   - `Order`, `Baz`, `BuiltinExhaustion`, `Bar`, `Repository`, `Foo` absent
5. **Cluster_id uniqueness across cross-kind groups**: arity-drift's `cluster_id_single_name("generic-arity-drift"; name)` collides if two cross-kind groups share a name — but the fixture's `Foo` is a single cross-kind group, so we're testing that the *single* row's cid is `generic-arity-drift:Foo`. (Multi-group collision is structurally impossible since group_by produces one row per unique name.)
6. **Knob coverage** (convention-bound): `EXTRA_BUILTINS=TStats` should drop `SyncResult` from the output — exercises the env-driven extension path. A second call with `EXTRA_BUILTINS=TStats,TOutput` should drop both `SyncResult` and `BackfillJob` — exercises the comma-split.

## Implementation order

TDD: write fixture + tests first, then implement query 1 to green, then query 2 to green, then README, then push.

1. Add fixture `generics.input.json`.
2. Add the four `assert_*` blocks (smoke pair, text pair, semantic helpers, knob coverage) to `test_queries_integration.sh`. Run — expect new tests to fail because queries don't exist yet.
3. Write `generic-arity-drift.jq`. Run tests; iterate to green.
4. Write `generic-convention-bound.jq`. Run tests; iterate to green.
5. Add README rows. Run full integration test suite + canonical tests; confirm all 80+ pass.
6. Rebase, push, open PR with `Closes #126`.

## Key implementation notes

- **`generic-arity-drift.jq` arity function:** `def arity: if . == null or . == "" then 0 else (split(",") | length) end;` — the `or . == ""` is defensive, since the contract permits omission but the extractor today emits `null` for non-generic.
- **`generic-convention-bound.jq` scan idiom:** `[$row.fields[] | split(":")[1:] | join(":") | [scan("[A-Z]\\w*")] | .[]] | unique` — the `[1:]` slice + `join(":")` handles field types that themselves contain a `:` (rare but defensive; Swift's `Result<Foo, Error>` doesn't but TS conditional types occasionally do).
- **`looks_like_typeparam` regex:** `test("^T[A-Z]") or test("^[TKVUER]$")`. Single-letter set covers the conventional names; `T[A-Z]\w*` covers the Microsoft/TS convention.
- **`EXTRA_BUILTINS` parsing:** `($ENV.EXTRA_BUILTINS // "" | split(",") | map(select(length > 0)))`. Empty default, split on comma, drop empty tokens.
- **Header docstring for convention-bound** must include the heuristic disclaimer + upgrade path to the live `type_refs` ticket (#146 today, originally #131) — substrate principle is "deterministic where possible; honest about the seams where not."
- **jq gotchas** (per `CLAUDE.md`): `-r` everywhere, plain `"..."` inside `\(...)` interpolation, no `\"...\"` over-escaping.

## What this PR does not change

- No extractor changes.
- No `docs/pipeline-contract.md` changes — both queries consume only existing required-when-applicable fields (`generics`, `fields`, `kind`).
- No `_canonical.jq` changes — `cluster_id_single_name` covers both queries' single-name cluster_id format.

## Out-of-scope follow-ups (deliberate)

- `generic-param-name-drift.jq` (open question #2 fallout) — defer until a real refactor needs it.
- `type_refs`-based rewrite of convention-bound — blocked on #146 (the earlier #131 ticket closed as not-planned; the work folded into the schema v1.1 edges design). Header docstring documents the upgrade path.
- Function-signature generics — out of lane entirely; tracked in #133's function-kind work.
