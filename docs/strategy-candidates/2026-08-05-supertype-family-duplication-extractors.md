# Extractor specs: supertype-family duplication

Companion to [`2026-08-05-supertype-family-duplication.md`](2026-08-05-supertype-family-duplication.md). That document proposes three cluster queries and tiers two of them as "ships now, no contract change." **This document is the result of running the checks that document asked for, and the tiering does not survive them.** All three patterns are blocked on the Swift extractor. What follows is the extractor work that unblocks them.

- **Captured:** 2026-08-05 (PT)
- **Verified against:** `code-audit-pipeline @ 1bff74f8`, `extractors/swift/Sources/swift-catalog/*`, `docs/pipeline-contract.md`
- **Status:** mostly shipped under tracker #321 — E1 as #317, E3a and E3c as #318, E4 as #319, E2 as #320. **E3b (`body_shape`) is deferred and unimplemented, tracked as #334**, so Pattern 3 of the companion document (`null-object-policy-drift.jq`) is still blocked. The consuming queries for Patterns 1 and 2 are unimplemented but no longer blocked.

> **This is a captured proposal, not current documentation.** [`docs/pipeline-contract.md`](../pipeline-contract.md) is normative for every field described here; where the two disagree, the contract wins. Line numbers cited throughout were accurate at `1bff74f8` and have since drifted — locate symbols by name. The one place the proposal below and the shipped field genuinely disagree is E2's shape, called out inline there.
>
> Follow-ups opened while implementing these, all still open: #323 (Xcode `<Target>Tests/` layouts are not tagged `is_test`), #324 (`file-hashes` and the type/function catalogs disagree on which Swift files exist), #325 (`(package, file)` does not disambiguate `--root` from `--shared`), #327 (`willSet`/`didSet` observers labelled `computed-property`), #328 (no param/return type refs, so `public-api-leaks.jq` is a silent zero against Swift), #331 (`access` under-reports declarations inside an access-modified extension), #332 (the contract's version-bump table disagrees with practice).

---

## The blocking finding

The source doc flagged one item as "the single most important thing to confirm first":

> **`is_test` semantics for testing-support products are unverified.** […] If `is_test` keys off a path segment like `/Tests/`, this holds; if it keys off "is this file in a test-ish target," `CoreTesting` may be misfiled and the predicate inverts.

Neither. **The Swift extractor does not emit `is_test` at all, on any catalog, and it excludes test files from the walk by default.**

- `TypeRecord` (`extractors/swift/Sources/swift-catalog/Common.swift:75-98`) has no `isTest` member. Its emitted keys are `exported, file, generated, kind, line, name, package, touched_in_window` plus the optional shape/heritage fields.
- `FunctionRecord` (`Common.swift:161-176`) has no `isTest` member either.
- `WalkedFile` (`Walker.swift:10-15`) carries `package` and `generated` — there is no test flag to propagate.
- `shouldSkipDirectory` prunes any directory named `Tests` unless `--include-tests` (`Walker.swift:80`), and `isTestFileName` drops any `*Tests.swift` basename (`Walker.swift:84-88`). Without the flag, the observed sites in the source doc are **not in the catalog at all**.

This contradicts the pipeline contract, which is normative on both points:

> Test files are always extracted; every row carries an `is_test: bool` flag derived from the file path. (`docs/pipeline-contract.md:416`)

Swift is the only extractor out of step. TypeScript (`extractors/typescript/_lib/paths.mjs:15`), Python (`extractors/python/_lib.py:43`), and Rust (`extractors/rust/src/util.rs:158`) all implement `is_test_path` and tag every row; Rust additionally keeps `--include-tests` as a documented no-op (`extractors/rust/src/lib.rs:29`).

Pattern 1 and Pattern 2 are built entirely on the `is_test` discriminator. Neither is Tier 1.

### This also un-tiers an already-filed issue

[#313 `test-double-conformance-clusters.jq`](https://github.com/jakebromberg/code-audit-pipeline/issues/313) — the nearest sibling of Pattern 1, distilled from the same codebase — opens with "Verified Tier 1 — the type-catalog already carries every field this needs," and its design starts with `Filter is_test == true`. It is blocked by the same gap. Extractor change **E1** below unblocks #313 and Patterns 1–2 together; that shared payoff is the argument for doing it first.

### Re-tiering

| Pattern | Doc's tier | Actual tier | Blocked on |
|---|---|---|---|
| 1 — supertype-family doubles | 1 | **2** | E1 (`is_test`) |
| 2 — per-kind doubles over a generic supertype | 1 | **2** | E1 (`is_test`); E2 sharpens |
| 3 — divergent null-object policy | 2 | **2** | E3 (`body_shape` + short-body rows + `enclosing_type`) |
| #313 — test-double conformance clusters | 1 (claimed) | **2** | E1 (`is_test`) |

---

# E1 — `is_test` on Swift type and function records

**Unblocks:** Pattern 1, Pattern 2, issue #313. **Required.**

## Change

**1. Path predicate.** Add `isTestPath(relativePath:) -> Bool` to `Walker.swift`, implementing the contract's normative pattern set (`docs/pipeline-contract.md:418-446`) verbatim:

- Directory segments (any depth, exact match, case-sensitive): `tests`, `test`, `__tests__`, `__test__`, `spec`, `__mocks__`, `__fixtures__`, `fixtures`, `e2e`, plus Swift's `Tests` (capital T, SwiftPM convention).
- Basename patterns: `*.test.swift`, `*.spec.swift`, `*.fixture.swift`, `*.fixtures.swift`, `*.mock.swift`, `*.mocks.swift`, plus Swift's existing `*Tests.swift`.

The existing `isTestFileName` (`Walker.swift:84-88`) is the seed — it already covers `*Tests.swift`, `.test.`, `.spec.` — but it is basename-only and it currently drives *exclusion*, not tagging. Widen it to the full set, add the segment scan, and repoint it.

**2. Propagate.** Add `let isTest: Bool` to `WalkedFile` (`Walker.swift:10-15`), populated at construction alongside `package` and `generated` (`Walker.swift:66-71`). Add `var isTest: Bool` to `TypeRecord` (`Common.swift:75`) and `FunctionRecord` (`Common.swift:161`); set it from `file.isTest` at every emit site (`TypeCatalogVisitor.swift:295`, `:387`, `:175`; `FunctionCatalogVisitor.swift:174`, `:222`). The encoder's `.convertToSnakeCase` strategy (`Common.swift:213`) renders it as `is_test` with no further work.

**3. Flip the walk polarity for `type` and `func`.** Both subcommands walk test files unconditionally and tag them. `--include-tests` becomes a documented no-op for those two, matching Rust's precedent — keep the flag so the manifest's `optional_args` entries and any existing invocation keep working.

**4. Leave `literal` alone.** The literal catalog is an occurrence catalog that deliberately omits `is_test` and keeps exclude-by-default polarity (`docs/pipeline-contract.md:680`, `:721`). Since the walker is shared, the cleanest split is: `walkRoot` always walks everything and tags each `WalkedFile`; the `literal` subcommand filters `files` on `!isTest` unless `--include-tests`. That keeps `literal-catalog.json` byte-stable across this change.

## Verification: the predicate lands right-way-round

The source doc's concern was that a testing-*support* product might be misfiled. It is not, under the path rule:

| Path | Segments | Basename | `is_test` |
|---|---|---|---|
| `Shared/Core/Sources/CoreTesting/QueuedStubURLProtocol.swift` | `Shared`, `Core`, `Sources`, `CoreTesting` | `QueuedStubURLProtocol.swift` | **false** ✓ |
| `Shared/Playlist/Tests/PlaylistTests/Helpers/CapturingURLProtocol.swift` | …`Tests`… | — | **true** ✓ |
| `Shared/MusicShareKit/Tests/MusicShareKitTests/DefaultAuthNetworkClientTests.swift` | …`Tests`… | `…Tests.swift` | **true** ✓ |

`CoreTesting` is not an exact match for any denied segment, so the shipped canonical reads `is_test: false` and the four test-local copies read `true`. Pattern 1's predicate is right-way-round. Add this table to the test fixture — it is the whole discriminator.

`resolvePackage` also cooperates: `Shared/<Pkg>/Tests/…` returns `<Pkg>` (`Walker.swift:98-100`), so a test double gets the same `package` as the production code it doubles. Pattern 1's "≥ 2 distinct packages" gate therefore counts `Core` (canonical) against `Playlist` / `MusicShareKit` / `Metadata` (copies) — four distinct values on the observed sites.

## Blast radius — call this out in the PR body

Swift type and function catalogs get larger and existing clusters get noisier, because test declarations become visible to every query that does not filter `is_test` (only three do today: `test-prod-drift.jq`, `cross-package-backward-imports.jq`, `persistence-store-field-density.jq`). This is contract alignment, not a regression, and it is the same trade TypeScript/Python/Rust already made — but it changes output for every existing Swift consumer, so it deserves its own PR and its own version bump rather than riding along with a query.

Escape hatch is already documented: `jq 'map(select(.is_test | not))'` (`docs/pipeline-contract.md:416`).

## Contract change

None. E1 brings Swift *into* compliance with text that already exists.

## Tests

New `extractors/swift/tests/test_type_catalog_is_test.sh`, following the `test_type_catalog_heritage.sh` convention (shell + jq assertions, out-of-process). Fixture tree `tests/fixtures/is-test-paths/` with one file per row of the table above, plus one `*.mock.swift`, one `Sources/FooTesting/` file, and one ordinary `Sources/Foo/` file. Assert `is_test` per file for both the `type` and `func` subcommands, and assert that a `Tests/` file appears in the default (no-flag) catalog at all — that assertion is the one that fails today.

Register the script in `.github/workflows/ci.yml` alongside the existing three (`ci.yml:31-33` for shellcheck, and a new step in the `swift` job at `ci.yml:270`).

---

# E2 — `associated_types` on type records

> **Shipped as #320, with the shape below superseded.** The field landed as `{ "name": string, "constraints": [string], "primary": bool }` — not `{name, primary}` as written below. `{name, constraints}` was already ratified for `language_data.swift.associated_types` in [`docs/pipeline-contract-v2-fixtures.jsonl`](../pipeline-contract-v2-fixtures.jsonl), so the implemented shape takes it as a superset rather than introducing a second, incompatible spelling of one field name.
>
> Two further corrections to what follows. Protocol rows with **no** associated types emit `[]` rather than omitting the field; omission is reserved for non-protocol rows, so `has("associated_types")` cleanly means "this row is a protocol." And the "collapses to one entry with `primary: true`" dedupe described below cannot arise: Swift requires every primary associated type to *also* be declared as an `associatedtype` member, so implementations enumerate the member block and set `primary` as a flag, with no union to merge.
>
> [`docs/pipeline-contract.md`](../pipeline-contract.md) is normative. Read this section as the original captured proposal.

**Sharpens:** Pattern 2. **Optional but cheap.**

Pattern 2's known recall gap says the sharpest form of the finding is "the protocol has an associated type, yet its doubles are monomorphic," and asks whether that is captured, pointing at `pat-candidates.jq` for prior art.

**It is not captured, and there is no prior art.** `ProtocolDeclSyntax` is visited with `generics: nil` hardcoded (`TypeCatalogVisitor.swift:115`), so `protocol SpotlightReindexer<Source>` records nothing about `Source`. `extractFields` only walks `VariableDeclSyntax` and `FunctionDeclSyntax` members (`TypeCatalogVisitor.swift:516-526`), so `associatedtype` declarations are invisible too. `pat-candidates.jq` *infers* PAT-ness from field-shape slot diffs across a type pair — it never reads a declared associated type, and grep confirms `associatedtype` appears nowhere in the codebase outside that query's prose.

## Change

Add `associated_types` to type records as an array of objects, mirroring the `fields_structured` precedent:

```jsonc
"associated_types": [
  { "name": "Source", "primary": true }    // sorted by name; primary = declared in <angle brackets>
]
```

Populated from two SwiftSyntax sources on `ProtocolDeclSyntax`:

- `node.primaryAssociatedTypeClause?.primaryAssociatedTypes` → `primary: true`
- `AssociatedTypeDeclSyntax` members of the member block → `primary: false`

Emitted only on `kind == "interface"` rows; absent (nil, so omitted from JSON) elsewhere. Sorted by name, deduped — a name appearing in both positions collapses to one entry with `primary: true`.

**Do not route these into `generics`.** `generics` is consumed by `generic-arity-drift.jq`, `generic-convention-bound.jq`, and `generic-struct-candidates.jq`; protocol rows carry no `generics` today, and populating it would silently change all three queries' inputs. A new field costs nothing and changes nothing.

## Contract change

Additive. One row in the type-catalog example block and one paragraph under the field-semantics section of `docs/pipeline-contract.md`. Ships in the same PR as the extractor, per the schema-first rule.

## What it buys Pattern 2

The predicate tightens from "test-local types conforming to one protocol whose names differ only by an infix" — which fires over *any* shared protocol — to "…where the protocol declares ≥ 1 associated type." On the observed site, `SpotlightReindexer<Source>` qualifies and the two monomorphic spies (`SpyConcertReindexer`, `SpyPlaycutReindexer`) are exactly the residue. Without it, ship the broader net and pay the precision cost in the `desc` line, as the source doc says.

---

# E3 — function-catalog: `body_shape`, contract-conformant short-body rows, `enclosing_type`

**Unblocks:** Pattern 3. **Required for it, and it is three changes, not one.**

## E3a — Emit rows for short bodies (contract violation, fix first)

The contract is explicit:

> Functions whose normalized body has fewer than `--min-body-lines` (default 3) lines emit a row with `body_hash` / `body_lines` / `body_line_count` / `body_length` all `null`. **The row is still emitted** so signature-level data is available for one-liner functions. (`docs/pipeline-contract.md:594`)

The Swift extractor returns early instead:

```swift
guard normalized.lines.count >= minBodyLines else { return }   // FunctionCatalogVisitor.swift:171
```

So `func donate(_ concerts: [Concert]) async throws {}` — the literal observed site in Pattern 3 — produces **no function-catalog row at all**. `body_shape: "empty"` is unreachable until this is fixed. There is no way to detect a family of no-op shims from a catalog that structurally cannot contain no-ops.

**Change:** drop the guard; make `bodyHash: String?`, `bodyLineCount: Int?`, `bodyLength: Int?`, `bodyLines: [String]?` on `FunctionRecord` (`Common.swift:172-175`) and emit `nil` for all four below the threshold. Same treatment in `emitFromAccessorBlock`'s `.getter` branch (`FunctionCatalogVisitor.swift:220`).

**Downstream is already safe.** All three body-clustering queries gate on `(.body_line_count // 0) >= 3` before touching `body_hash` — `function-duplicates.jq:33`, `default-impl-candidates.jq:61`, `generic-function-candidates.jq:89` — and `null // 0` evaluates to `0`, so null-body rows are filtered out before any `group_by(.body_hash)`. No giant null cluster. (Note the contract's prose at `:594` describes the guard as `select(.body_hash != null)`; the queries use the line-count form instead. Equivalent effect — worth correcting the prose in the same PR.)

**Cost:** Swift function catalogs grow substantially — every one-liner, every trivial accessor. Same trade TypeScript and Python already make.

## E3b — `body_shape`

Add `body_shape: string` to function records, an enum over `empty | throw_only | constant_return | delegating | substantive`. Emitted on **every** row, including null-body ones — that is the entire point, and it is why E3a comes first.

Classified from the AST, not from the normalized text, over the body's `CodeBlockItemListSyntax`. Strip `TryExprSyntax` / `AwaitExprSyntax` / `ForceUnwrapExprSyntax` / `OptionalChainingExprSyntax` wrappers before inspecting an expression. Evaluate in order; first match wins:

| Shape | Rule |
|---|---|
| `empty` | `statements.isEmpty` |
| `throw_only` | every statement is a `ThrowStmtSyntax` |
| `constant_return` | exactly one statement, whose value expression (bare, or `ReturnStmtSyntax.expression`, or a valueless `return`) is an integer/float/boolean/nil literal, a non-interpolated string literal, an empty array or dictionary literal, or a base-less `MemberAccessExprSyntax` (`.unavailable`, `.none`) |
| `delegating` | exactly one statement whose value expression is a `FunctionCallExprSyntax` with a `MemberAccessExprSyntax` callee (`foo.bar(…)`, `self.client.send(…)`) |
| `substantive` | everything else |

A bare `DeclReferenceExprSyntax` (`return cached`) is deliberately **not** `constant_return` — it reads a property, which is not a constant. Keeping the classifier conservative is what makes the enum worth trusting; over-claiming here poisons every downstream consumer.

`body_shape` is a classification of the same span the body hash already covers, so it is additive at the same granularity — no per-statement records.

## E3c — `enclosing_type`

Pattern 3 needs a function-catalog → type-catalog join, and the source doc flags the join key as unverified. **There is no `enclosing_type` on function rows.** `name` is dotted-qualified from the visitor's `nameStack` (`FunctionCatalogVisitor.swift:173`), so the enclosing type is *derivable* — but naively splitting on `.` is wrong: extensions push the extended type's text (`:56`) and nested types push a multi-segment stack, so `WidgetSafeConcertReindexer.donate` and `Outer.Inner.method` and `Array<Foo>.helper` all need different handling at the query layer.

The literal catalog already solved this: `LiteralRecord.enclosingType` (`Common.swift:207`), documented at `docs/pipeline-contract.md:709` as "dotted nesting-stack qualification, extensions push the extended type." Mirror it exactly.

**Change:** add `var enclosingType: String?` to `FunctionRecord`, set to `nameStack.joined(separator: ".")` or `nil` when the stack is empty. This is the same string `TypeCatalogVisitor.qualify` produces for the enclosing declaration's own `name` (`TypeCatalogVisitor.swift:203-205`), so the join is exact rather than heuristic.

## Contract change

Three additive entries in the function-catalog section: `body_shape` (with the classification table), `enclosing_type`, and a correction to the `:594` body-gating prose. Schema-first — contract PR lands before the query PR, as the source doc sequences.

---

# E4 — `access` on type records (optional)

**Sharpens:** Pattern 1.

The source doc says (line 73) that there is "no visibility field on type rows," and that `access` exists only on numeric-literal rows. Half right. Type rows carry `exported: bool` (`docs/pipeline-contract.md:39`), computed by `TypeCatalogVisitor.isExported` (`:207-219`): `public` / `open` / `package` → true, `private` / `fileprivate` → false, **no modifier → true**.

That default is why `exported` cannot carry Pattern 1 on its own. On the observed sites:

| Declaration | `exported` |
|---|---|
| `public final class QueuedStubURLProtocol` (the canonical) | true |
| `final class CapturingURLProtocol` (internal) | **true** — conflated |
| `private final class AuthRequestInterceptor` | false |

So `exported == true` does not isolate the shipped canonical. Pattern 1's `is_test`-based phrasing stands as the primary discriminator.

**Change if pursued:** add `access: string` to type records — the modifier as written (`public`, `open`, `package`, `internal`, `fileprivate`, `private`), defaulting to `"internal"` when none is present. `isExported` already walks the modifier list; this is a few lines beside it, and it mirrors the field name and semantics the literal catalog already uses (`docs/pipeline-contract.md:702`). It would let Pattern 1 say what it actually means — "a **public** shipped canonical coexists with test-local copies" — instead of proxying through `is_test` alone.

Not required. Do not block Patterns 1–3 on it.

---

# Sequencing

Five PRs. E1 is the unlock; everything else is independent of everything else.

1. **E1 — Swift `is_test`.** No contract change. Unblocks Patterns 1–2 and issue #313. Bump `extractors/swift/manifest.toml` `[extractor] version` 0.6.0 → 0.7.0; regenerate embeds (`go generate ./...`) and commit `cmd/code-audit/extractors/swift/`; add the new test script to `.github/workflows/ci.yml` in both the shellcheck list and the `swift` job.
2. **Query PR — Patterns 1 and 2** (`supertype-family-duplication.jq`, `per-kind-test-doubles.jq`). Shared helpers, one catalog; ship together if the diff stays under ~1000 lines. Both consume `conformance_index` / `with_conformance` from `_canonical.jq:333,344` — and per that helper's own docstring, read merged conformance rather than a row's own `conforms_to`, since Swift declares conformance retroactively via `extension Foo: P {}` as a separate record.
3. **E3 — function-catalog: short-body rows + `body_shape` + `enclosing_type`,** with the contract edits. Independent of E1; can run in parallel.
4. **Query PR — Pattern 3** (`null-object-policy-drift.jq`). Gated on 3.
5. **E2 / E4 — sharpeners.** Whenever. Neither blocks anything.

## Restraint carried forward

The source doc's restraint sections stand unchanged and are load-bearing — particularly the denylist for mass-conformance protocols (`Codable`, `Sendable`, `Equatable`, `Hashable`, `Identifiable`, `View`, `Error`, `CaseIterable`), which would otherwise each produce one enormous group. Issue #313's restraint section lists the same denylist plus `Decodable`, `Encodable`, `CustomStringConvertible`, `LocalizedError`, `Comparable`, `RawRepresentable`; use the union.

One extraction-level note that the query layer must handle, inherited from #313's verification: `URLProtocol` is in neither `CLASS_LIKE_INHERITED` nor `PROTOCOL_LIKE_INHERITED` (`Common.swift:109`, `:127`), so it hits the default-both rule and appears in **both** `extends` and `conforms_to` on every subclass. Pattern 1's spec explodes over `extends[] + conforms_to[]` — **dedupe keys per row before grouping**, or every `URLProtocol` subclass counts twice and the group-size gate fires on half the real membership.

## Corrections to the source document

Fold these back into `2026-08-05-supertype-family-duplication.md` if it is kept as the standing spec:

- Patterns 1 and 2 are Tier 2, not Tier 1. "Ships now, single PR, no contract change" is wrong; E1 comes first.
- `is_test` is not merely unverified for testing-support products — it is absent from Swift catalogs entirely, and Swift skips test files by default. Once E1 lands per the contract's path rule, the assumed polarity is correct.
- Pattern 2's PAT sharpener is unavailable. `pat-candidates.jq` infers PAT-ness from field-shape slot diffs; it does not read declared associated types, and nothing in the catalog does.
- Pattern 3's `body_shape` is blocked by more than a missing field: short bodies produce no row at all, in violation of `docs/pipeline-contract.md:594`.
- Pattern 3's function → type join key does not exist as a field, but `name` is nameStack-qualified so it is derivable; add `enclosing_type` to make the join exact, mirroring the literal catalog.
- Type rows *do* carry a visibility signal — `exported: bool` — but it maps Swift's default `internal` to `true`, so it cannot isolate a public canonical. See E4.
- Doc-comment presence (Pattern 3's downrank) is **not** extracted anywhere. Say so in the query's `desc`, per the doc's own instruction, or drop the downrank.
