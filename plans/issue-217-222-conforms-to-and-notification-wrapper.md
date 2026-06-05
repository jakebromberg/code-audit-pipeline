# Conforms-to and notification-wrapper-grouping (issues #217 + #222)

Issues #217 (emit `conforms_to`; downrank already-abstracted clusters) and #222 (extract `Notification.Name` wraps; new grouping query) are bundled — both modify `TypeCatalogVisitor.swift` and the catalog contract on overlapping surface, so one schema bump and one rebase cycle covers both. Triage tracker: #256.

## Prior art (off-main only, not a regression)

A `conformsTo` field was added in commit `8673fddd substrate(v7): protocol-conformance edges + default-impl filter (#40)` and refined in `5763acba review(§6.2): fix default-impl intersection + merge same-name conforms_to`. **Neither commit ever merged to `main`** — they live on dropped V7 experiment branches. `main`'s Common.swift history ends at the V7 §6.1 name/type split. This work isn't reinstatement, it's first landing.

That prior code is still valuable as design reference. Two lessons borrowed:

1. The prior implementation took the simpler "everything goes in one `conforms_to[]`" stance (no extends/conforms_to split) and let `default-impl-candidates.jq` do the work. The intersection-bug review showed how the jq side is the load-bearing complexity — the substrate kept it byte-cheap.
2. The intersection bug pattern (`reduce ... select(IN($next[]))` was the fix) lives in `5763acba`. I'll borrow that pattern directly for the new `is_already_abstracted_cluster` helper rather than reinventing — the reviewer flagged this and the existing fix proves it works.

I depart from the prior design where #217 explicitly asks for the extends/conforms_to split. The split adds the curated-set complexity but enables the "shared parent class doesn't count as already-abstracted" judgement that the open question in #217 §2 wants left open.

## Goal

Make protocol/interface conformance a first-class catalog axis (today the substrate sees only the unified `extending` field, populated only on extensions), then exercise it for two precision wins:

1. Downrank `exact-duplicates` / `name-collisions` / `near-duplicates` clusters whose members already share a non-trivial protocol — kills the wxyc-ios-64 `MusicService` and `NowPlayingWidgetEntryView` false positives.
2. Find pairs of Swift `*Message`-style types that wrap the same `Notification.Name` — surfaces the wxyc-ios-64 `PlayerRateDidChangeMessage` / `HLSRateDidChangeMessage` cross-fire (filed downstream as wxyc-ios-64 #324).

## Background — pre-existing schema gaps the Swift extractor carries

Probing the Swift extractor against a synthetic fixture shows it currently does **not** emit `extends`, `references`, `references_count`, or `is_test` on type records, despite the pipeline-contract.md "Required fields" section listing all four. The TypeRecord struct only carries a single optional `extending: String?` that is populated for extensions and left null for struct/class/actor/enum/protocol. Cluster queries that consume `extends`/`references` against Swift catalogs degrade silently rather than crash because `entries[] | select(.extends | any(...))` over a missing-key entry evaluates to false, but the queries cannot honor the supertype edge they were designed for.

This plan is **not** the place to close every gap — that would balloon scope and conflict with Lane C's schema-v2 work. The Swift `extends`/`conforms_to` work here is targeted: populate both arrays from inheritance clauses so the new "already-abstracted" filter can fire and so `extends`-based queries on Swift catalogs start working at all. `references` / `references_count` / `is_test` stay deferred and the case-study contract conformance gap stays a separately-tracked debt.

## Schema changes (`docs/pipeline-contract.md`)

1. Add `conforms_to: string[]` to the type-catalog record shape near `extends`. Mark it required-on-every-row (empty array when no protocol/interface conformance) — same shape rule the contract already applies to `extends` and `references`. Document the split:
   - `extends` is the class-like-inheritance axis (Swift class superclass; TS interface extending interface; TS intersection-type named operand).
   - `conforms_to` is the protocol/interface-implementation axis (Swift `: Protocol`; TS `class implements I`).
   - When the AST cannot disambiguate (Swift type lookup is out of scope for this extractor — there is no type resolver in either extractor), the inherited identifier is duplicated into BOTH arrays. Cluster queries disambiguate by joining against the target's `kind`. This is documented as the "default-both" rule.
2. Add `wraps_notification_name: string | null` to the type-catalog record shape, in the "Optional but useful" subsection. Populated by the Swift extractor when it recognizes the `Notification.Name`-wrapper pattern. The TypeScript extractor leaves it absent. (Picking the singular `wraps_notification_name` over the array form: per audit observation, the pattern is one-name-per-message-type; making it a singular keeps the query trivial. If a multi-name case appears the schema can grow to an array additively without breaking the query.)
3. Add a "Heritage split convention" subsection under `extends` and `references` semantics explaining the extends-vs-conforms_to rule and the default-both fallback. Cross-reference the `notification-wrapper-grouping.jq` query for the use-case.

## Swift extractor (`extractors/swift/Sources/swift-catalog/`)

### `Common.swift` — TypeRecord shape

Replace the single optional `extending: String?` with two arrays:

```swift
var extends: [String] = []         // class-like inheritance / superclass
var conformsTo: [String] = []      // protocol conformance
var wrapsNotificationName: String? = nil
```

`keyEncodingStrategy = .convertToSnakeCase` already produces `extends`, `conforms_to`, `wraps_notification_name` from these field names — no custom keys needed. The legacy single-string `extending` is gone; cluster queries reading the Swift catalog were not using it (the contract names `extends`, plural), so this is byte-clean.

### `TypeCatalogVisitor.swift` — heritage walk

Add a helper with this exact signature:

```swift
/// Walk an inheritance clause and partition the inherited identifiers into
/// supertype (`extends`) vs. protocol conformance (`conforms_to`). The
/// `declaringKind` parameter narrows the partition: for `.protocolDecl`,
/// every inherited identifier must be a protocol (Swift forbids a protocol
/// inheriting from a concrete type), so the whole list goes to `conformsTo`
/// and `extends` is empty.
///
/// For struct / class / actor / enum / extension, the partition uses the
/// curated `CLASS_LIKE_INHERITED` and `PROTOCOL_LIKE_INHERITED` sets in
/// `Common.swift`. Identifiers in neither set fall through to the "default-
/// both" rule: appended to both `extends` and `conformsTo` so cluster
/// queries can disambiguate via the target's `kind` at query-time.
private func extractHeritageEdges(
    of clause: InheritanceClauseSyntax?,
    declaringKind: DeclaringKind
) -> (extends: [String], conformsTo: [String])
```

Where `DeclaringKind` is a small enum: `struct`, `class`, `actor`, `enumDecl`, `extensionDecl`, `protocolDecl`. (`enum`, `extension` are Swift keywords; appending `Decl` to those three keyword-collision cases mirrors the SwiftSyntax node-type suffix convention `EnumDeclSyntax`/`ExtensionDeclSyntax`/`ProtocolDeclSyntax`.) The clause covers struct, class, actor, enum, and extension via `node.inheritanceClause`; protocol declarations have the same accessor (`InheritanceClauseSyntax?`), so the signature is uniform. For each `InheritedTypeSyntax`, take `.type.trimmedDescription` as the identifier.

**Sorting contract.** Both returned arrays are sorted lexicographically and de-duplicated before return. The cluster queries rely on this — `exact-duplicates`-style sorting determinism and `intersect_string_arrays` semantics both expect sorted, unique input. This matches the existing `fields` convention (sorted in `extractFields` via `pairs.sort { $0.flat < $1.flat }`) and the `extends` convention documented in pipeline-contract.md ("sorted alpha"). Add an explicit `.sorted()` + dedup pass at the end of `extractHeritageEdges`; the cost is N≤~6 typical heritage clauses, trivial.

The classifier per identifier:

- Identifier in a curated **class-only** set (`NSObject`, `UIView`, `UIViewController`, `UIControl`, `UIResponder`, `View` only when nested in a SwiftUI body context but we cannot distinguish — drop `View` from the class set, keep it as protocol; the SwiftUI `View` protocol is by far the dominant case).
- Identifier in a curated **protocol-only** set (Swift stdlib markers: `Equatable`, `Hashable`, `Codable`, `Decodable`, `Encodable`, `Sendable`, `Comparable`, `CustomStringConvertible`, `CustomDebugStringConvertible`, `Error`, `LocalizedError`, `Identifiable`, `RawRepresentable`, `CaseIterable`, `OptionSet`, `Collection`, `Sequence`, `IteratorProtocol`, `AsyncSequence`, `AsyncIteratorProtocol`, `Observable`, `ObservableObject`, plus SwiftUI: `View`, `App`, `Scene`, `ViewModifier`, `PreviewProvider`, `EnvironmentKey`, `PreferenceKey`, `Shape`, `InsettableShape`, `LayoutValueKey`).
- Otherwise: **default-both** — append to `extends` AND `conformsTo`. Cluster queries that care about the distinction disambiguate via the target's `kind`.

The kind of the declaring node also informs us: a `ProtocolDeclSyntax` heritage clause CAN ONLY contain other protocols (Swift forbids a protocol inheriting from a concrete type). For protocol decls the helper short-circuits to `conformsTo` only.

Wire the helper into the five emit sites (struct, class, actor, enum via `emitEnum`, extension) plus the protocol path. The current `extending: nil` literal in every `emitShapeBearing` call site becomes the helper's `(extends, conformsTo)` tuple. For extensions, the current code uses `node.extendedType.trimmedDescription` for both the simple name AND the `extending` field — extensions still record their target type in `extends` (the extension *is-a* extension-of that type, structurally), with any explicit conformance clause on the extension contributing only to `conformsTo`. So an `extension Bar: Hashable {}` emits `extends: ["Bar"]`, `conforms_to: ["Hashable"]`.

For enums, the heritage clause's first identifier is a raw-value type, not a superclass — but the cluster queries that consume `extends` are not affected by that nuance (they cluster on the supertype-edge axis, and `String`/`Int` raw values are inherited-from in the same syntactic position). Leave the raw-value identifier in `extends` per the default-both rule; the curated protocol-only set above will route the obvious cases (`String: Hashable`) correctly.

### Notification-wrapper detection

A type `T` wraps a `Notification.Name` when:

1. `T.conformsTo` contains an identifier ending in `NotificationMessage` (project naming) OR equal to `NotificationCenter.MainActorMessage` / `NotificationCenter.AsyncMessage` (Foundation's iOS 26 protocols, qualified via `MemberTypeSyntax`); AND
2. `T` declares a `static var name: Notification.Name { ... }` whose body is a single expression evaluating to a notification-name identifier.

The visitor already walks `VariableDeclSyntax` for field extraction. Add a second pass over `members` (cheap — the member block is small) that looks for `static var name: Notification.Name { ... }`:

- Modifier list contains `static`.
- Binding pattern identifier is `name`.
- Type annotation is `Notification.Name` (verbatim text match after trim).
- Accessor block is either a getter or a single-expression closure that returns a member-access (`AVPlayer.rateDidChangeNotification`, `.someName`) or an identifier (`someName`).

Extract the body's expression as text (`accessor.body.statements.first?.item.trimmedDescription` for the getter form) and set `wrapsNotificationName` to that string. For the `.someName` short form, prefix is implicit — keep the literal text (`.someName`); the query groups by string equality so the convention "the writer uses the same spelling at both call sites" carries it. (Cross-checked against the wxyc-ios-64 case: both `PlayerRateDidChangeMessage` and `HLSRateDidChangeMessage` write `AVPlayer.rateDidChangeNotification` verbatim, so string equality is the right key.)

If detection fails any check, leave `wrapsNotificationName` nil — silently degrading is correct for an opt-in optional field. Add a stderr counter for "notification-wrapper rows emitted" in the type-subcommand summary, similar to the existing parse-error count.

**Deferred (called out in PR body):** `addObserver(forName:)` call-site detection (#222 §2 trailer). The visitor's complexity to find arbitrary call sites is non-trivial (would need a separate pass over function bodies or a global identifier-occurrence collector), and the higher-signal type-record case covers the bug class the issue identifies. Tracked as a follow-up.

### Tests — Swift extractor

Add `extractors/swift/tests/test_type_catalog_heritage.sh` (new file) following the pattern of `test_package_graph.sh`. The shell-based pattern is the existing precedent — `test_package_graph.sh` was the first Swift extractor test and uses an out-of-process invocation against fixture trees + `jq` assertions. The alternative (a `swift test` target with XCTest harness) would require restructuring `Package.swift` to add a test target and pulling SwiftSyntax into the test product; the shell-based approach is consistent with the precedent and one PR's scope tighter. Document this as the Swift extractor testing convention in the file's docstring.

Runs `swift-catalog type` against a fixture tree under `tests/fixtures/type-catalog-heritage/` and asserts the emitted JSON. Cases:

- `class Foo: BaseClass, ProtoA {}` → `extends: ["BaseClass", "ProtoA"]`, `conforms_to: ["BaseClass", "ProtoA"]` (default-both; the unknown names go to both).
- `class Bar: NSObject, Equatable {}` → `extends: ["NSObject"]`, `conforms_to: ["Equatable"]` (curated sets hit).
- `struct Baz: Sendable, Hashable {}` → `extends: []`, `conforms_to: ["Hashable", "Sendable"]` (structs don't class-inherit; curated protocols).
- `protocol P: Q, R {}` → `extends: []`, `conforms_to: ["Q", "R"]` (protocol heritage is conformance-only).
- `extension Foo: Hashable {}` → `extends: ["Foo"]`, `conforms_to: ["Hashable"]`.
- `struct M: SomeNotificationMessage { static var name: Notification.Name { AVPlayer.rateDidChangeNotification } }` → `conforms_to: ["SomeNotificationMessage"]`, `wraps_notification_name: "AVPlayer.rateDidChangeNotification"`.

TDD: write failing-test fixture first, then the extractor changes, then the green run.

## TypeScript extractor (`extractors/typescript/type-catalog.mjs`)

Today's TS extractor emits no class declarations as type records (probed; no `isClassDeclaration` branch in `visit()`). The contract change still requires emitting `conforms_to` on every row for shape uniformity, so:

- Add `conforms_to: []` to the empty-defaults branch in `pushBase` so **every** type row (interfaces, type aliases, zod objects, drizzle tables, type-alias-* of every flavor) carries the field uniformly. The TS side wires it identically to how `extends: []` is wired today — one line addition in `pushBase`, matching the contract's "required-on-every-row" rule.
- Where interfaces are pushed, `conforms_to` stays empty — interface-extends-interface is `extends` semantics, not `conforms_to`.
- The "classes with `implements`" path the issue mentions would require adding class-emission (a much larger change). Defer that to a follow-up; the schema is forward-compatible (empty array vs. populated). Note this explicitly in the PR body and in `docs/pipeline-contract.md` so a future contributor wiring class emission knows the `conforms_to` slot is already reserved.

**Asymmetry called out:** because TS class emission is deferred, the `is_already_abstracted_cluster` predicate will never fire on a TS-only catalog (no row has a populated `conforms_to`). Swift catalogs get the downrank; TS catalogs get the same `demoted: false` behaviour they have today. Document this in pipeline-contract.md's "Heritage split convention" subsection so the next contributor reading the schema doesn't assume `conforms_to` is uniformly populated across languages. File a follow-up issue tracking TS class extraction — reference it in the PR body and link from the contract docstring.

Update the TypeScript test suite to expect `conforms_to: []` on every emitted type row. The relevant test entry points (verify exact paths via `npm test` discovery before touching):

- `extractors/typescript/test/*.test.mjs` or `extractors/typescript/tests/*.test.mjs` — whichever harness produces the per-row equality assertions.
- Fixture-snapshot directories (`extractors/typescript/fixtures/`) — if any test asserts the full emitted catalog as a snapshot, the snapshot files gain `conforms_to: []` on every row.

The change is mechanical: extend every `extends: []` test expectation to also assert `conforms_to: []`. Mass-update via the test harness's update-snapshot mode (typically `npm test -- -u` or equivalent), then review the diff. If the harness has no snapshot mode, do the row-by-row addition by hand — the contract is "every row carries both fields, empty arrays unless populated."

## New query — `pipeline/queries/notification-wrapper-grouping.jq`

```
#! query: notification-wrapper-grouping
#! shape: cluster
#! catalog: type-catalog
#! formats: text, jsonl
#! desc: Group types wrapping the same Notification.Name; cross-module wraps are likely cross-fire bugs.
```

Grouping logic:

```
[ entries[] | select(.wraps_notification_name != null and .wraps_notification_name != "") ]
| group_by(.wraps_notification_name)
| map(select(length >= 2))
| map(select((map(.package) | unique | length) >= 2))
```

The "across different modules" requirement uses `.package` as the module unit, matching every other multi-module query in the directory. Cluster_id format: `notification-wrapper-grouping:<NotificationName>`. Use `cluster_id_single_name`.

Severity is implicit in the result: ANY ≥2-member cluster across modules is the high-signal case. The "both are observers" refinement #222 §4 names requires call-site detection that the extractor defers — so this query's v1 surfaces all multi-wrap cases and the agent reads the cluster to confirm bug-vs-pattern. Document this trade-off in the query header.

Add an integration-test fixture `pipeline/queries/_tests/fixtures/notification-wrapper.input.json` with FOUR rows:

1. Two `*Message` types in distinct packages wrapping the same `.rateDidChangeNotification` → expect to surface in one cluster of 2 members.
2. One in a third package wrapping a different name (`.somethingElseNotification`) → expect to NOT cluster (lone member).
3. One `*Message` type that conforms to `NotificationMessage` but does NOT declare a `static var name` field — i.e., `wraps_notification_name` is null → expect to NOT cluster. This negative case guards against a regression where a future detection-loosening pass would accidentally cluster on protocol-conformance alone.

Assertions on the query's output:

- Exactly one cluster row emitted.
- That cluster has exactly two members.
- The cluster's `wraps_notification_name` is `AVPlayer.rateDidChangeNotification` (positive).
- No cluster row whose `wraps_notification_name` is `SomethingElseNotification` (negative — the lone wrapper must not surface).
- The detection-failure row (no `static var name`) contributes nothing to the output.

These four assertions together guard both directions: the positive cluster surfaces, AND lone wrappers / null-wrap rows correctly drop out.

## Already-abstracted filter for existing queries

Per #217 §4. Define the predicate once in `_canonical.jq`, using the `IN()` intersection pattern that landed as a fix in `5763acba`:

```jq
# Intersection of N string arrays, preserving the contract that empty input
# yields empty output. Set-of-strings semantics — input arrays must already be
# de-duped (the .conforms_to convention on type records is sorted + unique).
def intersect_string_arrays:
  if length == 0 then []
  elif length == 1 then .[0]
  else (.[0]) as $first
       | reduce .[1:][] as $next ($first; map(select(IN($next[]))))
  end;

# A cluster is "already abstracted" when:
#   1. All members share at least one conforms_to entry, AND
#   2. That shared entry resolves to a real protocol in $protocols_idx —
#      kind == "interface" with at least 2 declared members (fields | length).
# $protocols_idx is a {name → entry-with-fields-count} lookup built once
# by the caller via group_by(.name) + add | unique merge (the same merge
# pattern used by default-impl-candidates after 5763acba). The fields-length
# heuristic is the substrate-cheap stand-in for "non-marker protocol" —
# Sendable / Equatable / Hashable have zero declared members; MusicService
# has many.
def is_already_abstracted_cluster($protocols_idx):
  ([.[].conforms_to // []] | intersect_string_arrays) as $shared
  | $shared
  | any(. as $name
        | $protocols_idx[$name] // null
        | . != null and .kind == "interface" and ((.fields // []) | length) >= 2)
  ;
```

**Helper placement:** the `intersect_string_arrays` and `is_already_abstracted_cluster` definitions go in `_canonical.jq` (general-purpose, three query consumers). The `$protocols_idx` construction also lives in `_canonical.jq` as a parameterless helper `protocols_index`:

```jq
def protocols_index:
  [ entries[] | select(.kind == "interface") ]
  | group_by(.name)
  | map({key: .[0].name,
         value: {kind: "interface",
                 fields: (map(.fields // []) | add | unique)}})
  | from_entries;
```

Each query binds it once at the top: `(. | protocols_index) as $protocols_idx`. This contrasts with `default-impl-candidates.jq`, which keeps its `$conforms_index` query-local — but the precedent there was a single consumer. Here we have three. Promoting the helper to `_canonical.jq` follows the "DRY when ≥2 consumers" rule already applied to `cluster_id_*`, `loc_key`, `entries`.

Apply in `exact-duplicates.jq`, `name-collisions.jq`, `near-duplicates.jq`. Each query builds `$protocols_idx` once near the top:

```jq
([ entries[]
   | select(.kind == "interface")
 ] | group_by(.name)
   | map({key: .[0].name,
          value: {kind: "interface",
                  fields: (map(.fields // []) | add | unique)}})
   | from_entries) as $protocols_idx
```

The `group_by` + `add | unique` merge handles Swift's `protocol Foo { ... } / extension Foo { ... }` case where the same protocol name appears in two records, matching the pattern 5763acba codified.

`near-duplicates.jq` is a pair query, not a cluster query — adapt the predicate by wrapping the left/right pair as `[$a, $b]` and passing that to `is_already_abstracted_cluster`. The predicate's contract is "an array of decls"; pair queries pass a 2-element array, cluster queries pass the N-element cluster.

**Spike before locking.** Build a minimal jq test in `test_canonical.sh` that runs the predicate against a hand-crafted protocols_idx and a 3-member cluster, with the expected boolean. Confirm the intersection and the kind/fields lookup both fire. If the index round-trip turns out awkward (e.g., name collisions between class and protocol with the same name), narrow the index further — but only if the spike surfaces a real failure.

**Output split**: introduce a structural-content marker `demoted: true` on rows that pass the already-abstracted predicate; the renderer in text mode prints them in a separate `--- already abstracted (demoted) ---` section after the main clusters; JSONL emits both with the marker so a downstream consumer can filter. Same query, two sections — keeps the cluster_id discoverable.

This pattern (helper in `_canonical.jq`, applied at three call sites, with a `demoted` marker) keeps the existing query rows byte-stable for the non-demoted case, satisfies the "signal not lost" requirement, and is small enough to keep the schema-change PR under the 1000-line cap.

### Integration tests

Add fixture rows in `pipeline/queries/_tests/fixtures/types.input.json` (or a new sibling fixture if collision with existing tests) that exercise:

- An exact-duplicates cluster of 3 types all conforming to a real protocol (with `references_count >= 2`) — expect `demoted: true`.
- An exact-duplicates cluster of 3 types all conforming only to `Sendable` (`references_count: 0`) — expect `demoted: false` / absent (still surfaces in the main section).
- A near-duplicates pair where both conform to a real protocol — expect demotion.

Update `test_queries_integration.sh` to assert at least one demoted row and at least one non-demoted row for each of the three queries.

## go generate + commit embeds

`pipeline/queries/_canonical.jq`, `pipeline/queries/notification-wrapper-grouping.jq`, `pipeline/queries/exact-duplicates.jq`, `pipeline/queries/name-collisions.jq`, `pipeline/queries/near-duplicates.jq`, and the Swift extractor sources all have committed copies under `cmd/code-audit/queries/` and `cmd/code-audit/extractors/swift/`. Run `go generate ./...` and stage the regenerated copies in the same commit (the precursor PR #237 set up the CI gate that fails otherwise — see the recent `fix(release): commit generated embeds so go install works` commit).

## PR delta budget — split decision

Rough line counts:

- `docs/pipeline-contract.md` schema additions: ~80 lines
- `extractors/swift/Sources/swift-catalog/Common.swift` shape changes: ~20 lines
- `extractors/swift/Sources/swift-catalog/TypeCatalogVisitor.swift` heritage walk + wrapper detection: ~150 lines
- Swift extractor test + fixtures: ~200 lines
- `extractors/typescript/type-catalog.mjs` conforms_to defaults: ~10 lines (with fixture updates: ~50)
- `pipeline/queries/_canonical.jq` helper: ~30 lines
- 3× query already-abstracted filter: ~60 lines
- `pipeline/queries/notification-wrapper-grouping.jq` + fixture + integration test: ~120 lines
- `cmd/code-audit/queries/` regen: same as pipeline diffs (~60 lines mirror)
- `cmd/code-audit/extractors/swift/` regen: same as Swift source diffs (~170 lines mirror)

Estimated total: ~950 lines. Tight but under the 1000-line cap. If review iterations push it over (e.g., the test surface grows during TDD), split at the natural seam: Swift extractor + schema + conforms_to first (PR-A), notification-wrapper-grouping + already-abstracted filter second (PR-B chained off PR-A). Both PRs close their respective issue.

## Sequencing during implementation (TDD)

1. **Branch & worktree** already prepared (this worktree).
2. **Write failing Swift test** — `tests/test_type_catalog_heritage.sh` asserts extends/conforms_to/wraps_notification_name shapes against fixtures. Confirm it fails (the extractor emits neither field today).
3. **Schema bump** — `docs/pipeline-contract.md`. (Test still fails, but contract now declares the target shape.)
4. **Swift extractor** — `Common.swift` shape, `TypeCatalogVisitor.swift` heritage walk + wrapper detection. Test passes.
5. **TypeScript extractor** — `conforms_to: []` defaults + fixture updates. `npm test` green.
6. **`_canonical.jq` helper** — `is_already_abstracted_cluster`. Unit test in `test_canonical.sh`.
7. **Three queries** — apply the helper. Update `test_queries_integration.sh` to assert demoted rows.
8. **New query** — `notification-wrapper-grouping.jq` + fixture + assertion in `test_queries_integration.sh`.
9. **`go generate ./...`** — regenerate the embeds. Commit.
10. **Local CI sweep** — `cd extractors/typescript && npm test`, `extractors/swift/tests/*.sh`, `pipeline/queries/_tests/*.sh`, `go test ./...`.
11. **Rebase against `origin/main`** — Lane C is shipping schema work on the same files; expect conflicts.
12. **Push, open PR (or PRs if split)** — body closes #217 and #222, references #256. Watch CI green via `gh run watch`.

## Risks / open questions

- **Class set vs. protocol set ambiguity.** A first-pass curated set is admittedly crude. The `default-both` rule is the safety net: anything we don't recognize lands in both arrays, and the cluster queries' join against the target's `kind` does the disambiguation at query-time. The wxyc-ios-64 false-positives the issue names BOTH involve repo-local protocols (`MusicService`, `NowPlayingWidgetEntryView`) that the curated set wouldn't recognize — they'd land in `conforms_to` via the default-both rule, and the `is_already_abstracted_cluster` predicate would find them via the protocols_idx lookup (where they ARE registered as `kind == "interface"` in the catalog). So the curated set is the precision-tightening pass for the well-known stdlib/SwiftUI markers; the default-both + catalog-join handles repo-local cases automatically. Pre-flight smoke-test once the worktree has a wxyc-ios-64 catalog to hand: re-run `exact-duplicates` and confirm both target clusters carry `demoted: true`. If not, the curated PROTOCOL set is over-tight (a marker protocol the cluster's members happen to share is registered in PROTOCOL_LIKE_INHERITED and thus excluded from default-both) — narrow it.
- **`references_count` threshold for "real protocol."** Issue says `>= N`; I'm proposing `N = 2` (the protocol has at least two referenced types in its surface). The wxyc-ios-64 `MusicService` protocol has ~5 referenced types in its surface, so `>= 2` clearly fires. `Sendable` / `Equatable` / `Hashable` have zero referenced types in their declaration (marker protocols by definition). `Codable` is a typealias and is special-cased by `is_already_abstracted_cluster` declining to match a `kind: "type-alias-other"` target — only `kind: "interface"` lookups count.
- **Swift extractor's missing `references` array.** The `is_already_abstracted_cluster` predicate looks up the target protocol's `references_count` — which the Swift extractor doesn't emit. On Swift-only catalogs the predicate would always read 0 and never downrank. Two options:
  1. Add a minimal `references_count` pass for Swift protocols (count `IdentifierTypeSyntax` / `MemberTypeSyntax` references in the protocol's body).
  2. Use a fallback signal: `fields | length >= N` (protocol with at least N member requirements). For protocols (where `includeMethodSignatures` is already true), `fields` carries method signatures — a non-marker protocol has ≥1, often many.
  Option 2 is materially smaller and uses what's already extracted. Going with option 2: define "real protocol" as `kind == "interface" and ((fields // []) | length) >= 2`. Document this fallback explicitly in `_canonical.jq` and the pipeline contract.

  **Heuristic limitations (called out in `_canonical.jq` docstring AND `pipeline-contract.md`):**
  - **Overprediction on test-local protocols.** A protocol declared in a single test file with ≥2 method requirements but no cross-module references will be classified as "real," and clusters whose members all conform to it will be downranked. This is the wrong call for a test-local marker — but it's also rare in practice (test files rarely declare protocols that the production types conform to), and a downranked cluster is a precision loss, not a missing finding. Acceptable for v1.
  - **Underprediction on richly-referenced marker protocols.** A `protocol StringID = String` style alias doesn't emit `kind: "interface"` so it correctly drops out. But a `protocol Codable: Decodable & Encodable {}` style three-line protocol that exists only as a composition shorthand has zero declared members and would NOT count as a real protocol — even though its semantic content (the composition) is non-trivial. This is correct for the issue's signal: the downrank wants protocols with method bodies that justify shared-implementation, and composition-only protocols don't.
  - **The lossy step is documented, not hidden.** Both the canonical helper and the pipeline-contract section name `fields | length >= 2` as the heuristic, citing `references_count` as the principled signal that's not yet emitted for Swift. The next iteration (separate issue, not in this PR) is "wire references_count on Swift protocols, swap the predicate to use it" — a strict precision win.

## Out of scope (deferred)

- `addObserver(forName:)` call-site notification detection (#222 §2 trailer).
- TypeScript class declaration extraction (the `implements` clause cannot fire without it; deferred, schema slot reserved).
- Swift `references[]` / `references_count` population (substantial separate change; the already-abstracted filter uses `fields | length` as a fallback signal documented above).
- Swift `is_test` flag population (separate contract-conformance debt; pre-existing).
- `extends`-based "already-abstracted" downrank (issue's open question #2; deferred until we observe whether protocol-conformance downranks are sufficient).
