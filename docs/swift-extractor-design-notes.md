# Swift extractor: design notes from wxyc-ios-64

> A feasibility study. Before writing the Swift extractor, walk a real Swift 6.2 codebase and see what an AST-based extractor can faithfully capture, where the [deterministic-extraction principle](../CLAUDE.md) bends, and where it breaks. The conclusions are evidence for a future iteration of [`pipeline-contract.md`](pipeline-contract.md); they do not prescribe one.

## Context

The pipeline's [TypeScript extractor](../extractors/typescript/type-catalog.mjs) is the lighthouse implementation. It was written against a TypeScript monorepo and produces the JSON shape documented in [`pipeline-contract.md`](pipeline-contract.md). The [case study](case-study.md) tells that story.

Adding a Swift extractor immediately pressures the contract. Swift is a structurally rich language — attached macros, generics with associated types, retroactive conformance, isolation domains, result builders, property wrappers, opaque return types — and each construct is a non-trivial extraction question. Together they compose. Before writing the extractor and before evolving the contract, this study walks real files from [`wxyc-ios-64`](https://github.com/WXYC/wxyc-ios-64) — the WXYC iOS app, written in Swift 6.2, targeting iOS 26 with backports to iOS 18.6, supporting tvOS, watchOS, and macOS — to ground the design conversation in artifacts rather than abstract feature taxonomy.

The study addresses three questions:

1. What does an AST-only extractor capture faithfully?
2. Where does it lose fidelity, and is the loss admissible?
3. What does the catalog need to grow to cover Swift adequately?

The relevant project roadmap entries are [`future-directions.md`](future-directions.md) §2 (the catalog as a universal structural index) and §5 (the polemic and case-study library). The findings here feed both: §2 because Swift exposes kinds the current schema doesn't model, and §5 because a Swift audit grounded in a real codebase is the kind of artifact the polemic accumulates.

## The codebase

`wxyc-ios-64` is roughly 2,400 Swift files across 19 local [Swift packages](https://swift.org/package-manager/) plus a multi-target Xcode project. Across surveyed files it exercises:

- Attached macros with multiple roles (member injection + extension conformance), implemented as Swift compiler plugins using [`swift-syntax`](https://github.com/swiftlang/swift-syntax). The macros covered by the [Apple Swift book "Macros" chapter](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/macros/) and the underlying Swift Evolution proposals [SE-0382 Expression Macros](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0382-expression-macros.md) and [SE-0389 Attached Macros](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0389-attached-macros.md).
- Protocols with associated types ([Swift book: Generics](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/generics/), [Swift book: Protocols](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/)).
- Retroactive conformance via `@retroactive` (introduced in Swift 5.10 to address the [retroactive-conformance warning](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0364-warning-for-retroactive-conformances.md)).
- Isolation annotations — `@MainActor`, `nonisolated`, `sending`, `@preconcurrency import` — covered by [Swift book: Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/).
- Generic constraints via `where` clauses.
- `@Observable` synthesizing observation tracking ([SE-0395 Observation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0395-observability.md)).
- Result builders, principally `@ViewBuilder` ([SE-0289 Result Builders](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0289-result-builders.md)).
- Opaque return types (`some View` / [SE-0244](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0244-opaque-result-types.md)) and existential types (`any P` / [SE-0335](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md)).
- `AsyncSequence` conformance with an associated `Element` typealias and a nested `AsyncIterator: AsyncIteratorProtocol`.
- `@unchecked Sendable` retroactive conformances on Foundation types.

The TS-flavored kinds in the current contract — `interface`, `type-alias-*`, `zod-object`, `drizzle-table` — model none of this. A Swift extractor needs the catalog to grow.

## Three files, three records

This section walks three real files. Each shows the source, the catalog records an extractor might emit, and what the records do and do not preserve. The records are illustrative — they extend the current contract in ways that would need to be ratified before they could ship — and are written to make the fidelity boundaries legible.

### File 1: a macro use site

[`Shared/Playlist/Sources/Playlist/FetchPlaylistEvent.swift`](https://github.com/WXYC/wxyc-ios-64/blob/main/Shared/Playlist/Sources/Playlist/FetchPlaylistEvent.swift), in full:

```swift
@AnalyticsEvent
struct FetchPlaylistEvent {
    let duration: TimeInterval
}
```

After the `AnalyticsEvent` macro expands, the type conforms to `AnalyticsEvent` and gains a synthesized `static let name: String = "fetch_playlist_event"` and `var properties: [String: Any]? = ["duration": duration]`. None of that appears in the source AST. A parse-only extractor would emit:

```jsonc
{
  "kind": "type",
  "name": "FetchPlaylistEvent",
  "package": "Playlist",
  "file": "Sources/Playlist/FetchPlaylistEvent.swift",
  "line": 15,
  "language": "swift",
  "fields": ["duration:TimeInterval"],
  "shape_sig": "duration:timeinterval",
  "language_data": {
    "swift": {
      "decl_kind": "struct",
      "access": "internal",
      "conformances": [],
      "macro_applications": [{ "name": "AnalyticsEvent", "args": [] }]
    }
  },
  "core_projection_complete": false,
  "omitted_features": ["macro_expansion"]
}
```

The structural truth — *this is an analytics event* — lives in the macro's expansion, which is not in the file. A query asking "which types conform to `AnalyticsEvent`?" would miss every use site of the macro.

The honest representation pairs the type record with a separate kind:

```jsonc
{
  "kind": "macro_application",
  "macro_name": "AnalyticsEvent",
  "target_name": "FetchPlaylistEvent",
  "target_file": "Sources/Playlist/FetchPlaylistEvent.swift",
  "target_line": 15
}
```

The `macro_application` record alone is information-free. It becomes useful only when joined against a separate `macro_definition` record — the next file.

### File 2: a macro declaration

[`Shared/Analytics/Sources/Analytics/AnalyticsEventMacro.swift`](https://github.com/WXYC/wxyc-ios-64/blob/main/Shared/Analytics/Sources/Analytics/AnalyticsEventMacro.swift), abbreviated:

```swift
@attached(member, names: named(name), named(properties))
@attached(extension, conformances: AnalyticsEvent)
public macro AnalyticsEvent() =
    #externalMacro(module: "AnalyticsMacrosPlugin", type: "AnalyticsEventMacro")
```

The macro's *contract* is fully present in the source: the `@attached` attributes declare what members the macro injects and what conformances it adds. The extractor can read this statically and emit:

```jsonc
{
  "kind": "macro_definition",
  "name": "AnalyticsEvent",
  "package": "Analytics",
  "file": "Sources/Analytics/AnalyticsEventMacro.swift",
  "line": 75,
  "language": "swift",
  "language_data": {
    "swift": {
      "implementation_module": "AnalyticsMacrosPlugin",
      "implementation_type": "AnalyticsEventMacro",
      "roles": ["member", "extension"],
      "synthesized_member_names": ["name", "properties"],
      "synthesized_conformances": ["AnalyticsEvent"]
    }
  }
}
```

This record is what makes the `macro_application` records useful. Joining `macro_application` × `macro_definition` on `macro_name` yields a derived conformance edge: any type with an `@AnalyticsEvent` application synthetically conforms to `AnalyticsEvent`. A query like "all `AnalyticsEvent` conformances" becomes a union of explicit conformances and macro-derived ones.

What the static contract does not capture is the macro's *behavior* — the snake_case conversion logic, the rule that an explicit `static let name` overrides the synthesized one, the property-iteration logic. Those live in the plugin implementation at [`Shared/AnalyticsMacros/Sources/AnalyticsMacrosPlugin/AnalyticsEventMacro.swift`](https://github.com/WXYC/wxyc-ios-64/blob/main/Shared/AnalyticsMacros/Sources/AnalyticsMacrosPlugin/AnalyticsEventMacro.swift) and are only recoverable by actually running the macro. This is the right division of labor for an extractor: contract statically, behavior dynamically (or not at all).

### File 3: a protocol with associated types

[`Shared/Core/Sources/Core/Observation/MainActorMessage.swift`](https://github.com/WXYC/wxyc-ios-64/blob/main/Shared/Core/Sources/Core/Observation/MainActorMessage.swift) (excerpted):

```swift
public protocol MainActorNotificationMessage: Sendable {
    associatedtype Subject

    nonisolated static var name: Notification.Name { get }
    static func makeMessage(_ notification: sending Notification) -> Self?
    @MainActor
    static func makeNotification(_ message: Self, object: Subject?) -> Notification
}

// ...

extension Notification: @unchecked @retroactive Sendable { }
```

The protocol declaration alone exercises associated types, multiple isolation annotations, `sending`, `Self`-typed returns, and inheritance from `Sendable`. The retroactive conformance at file end is a Swift 6 concurrency footgun worth surfacing in audits. The extractor might emit:

```jsonc
{
  "kind": "interface",
  "name": "MainActorNotificationMessage",
  "package": "Core",
  "file": "Sources/Core/Observation/MainActorMessage.swift",
  "line": 43,
  "language": "swift",
  "fields": [
    "name:Notification.Name",
    "makeMessage:(Notification)->Self?",
    "makeNotification:(Self,Subject?)->Notification"
  ],
  "shape_sig": "makemessage:(notification)->self?|makenotification:(self,subject?)->notification|name:notification.name",
  "language_data": {
    "swift": {
      "decl_kind": "protocol",
      "access": "public",
      "inherited_protocols": ["Sendable"],
      "associated_types": [{ "name": "Subject", "constraints": [] }],
      "member_isolation": {
        "name": "nonisolated",
        "makeNotification": "@MainActor"
      }
    }
  },
  "core_projection_complete": false,
  "omitted_features": [
    "sending_parameter_annotation",
    "self_type_resolution"
  ]
}
```

And the retroactive conformance as a first-class record:

```jsonc
{
  "kind": "conformance",
  "type_name": "Notification",
  "protocol_name": "Sendable",
  "file": "Sources/Core/Observation/MainActorMessage.swift",
  "line": 181,
  "language": "swift",
  "language_data": {
    "swift": {
      "is_retroactive": true,
      "is_unchecked": true,
      "context": "extension"
    }
  }
}
```

A query like "find all unchecked retroactive `Sendable` conformances" — a real concurrency-audit question — becomes a one-line filter.

What works in these records:

- Associated types live in `language_data.swift.associated_types` rather than being shoehorned into `fields`. Queries about PATs are first-class.
- Conformances are a separate kind, not a nested array inside the type record. Retroactive conformances become discoverable.
- Member isolation is preserved at the granularity the source declares it (one annotation per member).

What does not work:

- The `where M.Subject: AnyObject` constraint that appears later in the same file is captured as a string, not a structured expression. Queries that want to reason about constraints structurally have to parse the string.
- The `sending` parameter annotation is omitted entirely. Encoding it adds complexity that the structural queries in scope today do not need; the loss is admitted in `omitted_features`.
- `Self?` is captured as a literal type string. Its semantic meaning — "the conforming type, optional" — is not queryable without language-aware processing.

## Source AST vs expanded AST

The deterministic-extraction principle survives in a specific form for Swift, but the form requires being precise about what "the AST" means.

Swift macros produce AST nodes. A [`MemberMacro`](https://github.com/swiftlang/swift-syntax/blob/main/Sources/SwiftSyntaxMacros/MacroProtocols/MemberMacro.swift) returns `[DeclSyntax]`; an `ExtensionMacro` returns `[ExtensionDeclSyntax]`. The compiler splices those into the syntax tree before type-checking. In that sense the macro's output *is* AST, and the compiler's view of the program is the post-expansion tree.

The distinction the extractor must make is between the **source AST** and the **expanded AST**:

- The **source AST** is what `SwiftParser.parse(source:)` returns when handed a file's bytes. It contains the macro *application site* (the `@AnalyticsEvent` attribute and the struct it attaches to) but not the synthesized members, properties, or conformance extension.
- The **expanded AST** is what the compiler operates on after macros run. It contains the synthesized nodes. Producing it requires building the macro plugin into a dylib, loading it, invoking it with the right `AttributeSyntax` and `DeclGroupSyntax`, receiving synthesized nodes back, and splicing them in. This is what [`swiftc -dump-macro-expansions`](https://www.swift.org/documentation/articles/expansion-macros.html) does, what `sourcekit-lsp`'s Expand Macro command does, and what `SwiftSyntaxMacros`'s `MacroSystem` / `BasicMacroExpansionContext` makes available to other tools.

An extractor has three paths:

1. **Parse only.** Cheap, hermetic, deterministic over the bytes on disk. Misses macro-synthesized members and conformances entirely. This is the closest analog to ts-morph's posture in the TypeScript extractor: input is files, output is records, no toolchain involved.
2. **Parse + read macro contracts + join.** Still parse-only, but the extractor also extracts the `@attached(member, names: …)` and `@attached(extension, conformances: …)` from macro *declarations* and joins them against application sites. This recovers the macro's contract — names of injected members, names of synthesized conformances — but not the content of generated bodies. Good enough for "which types conform to `AnalyticsEvent`?" because the conformance is declared in the macro's attached-extension role. Not good enough for "what's inside the synthesized `properties` dictionary?" — that requires running the snake_case logic in the plugin.
3. **Parse + actually expand.** Invoke the macro plugins, get the real expanded AST, catalog from that. Most accurate. Requires the toolchain to be present, requires plugins to build, and the result varies with build context (some macros emit different code based on platform / availability).

Path 2 is the interesting middle ground and the one this study recommends. It buys most of the structural-query value without crossing into "run the toolchain" territory — which matters because path 3 breaks the byte-reproducible-from-source-files property that makes the catalog cheap to regenerate per [`future-directions.md`](future-directions.md) §1 (time as a first-class dimension).

The principle ["deterministic extraction, agentic synthesis"](../CLAUDE.md) survives in Swift via path 2, but only because the catalog admits the limit honestly: a `macro_application` record on its own says little; joined against a `macro_definition` record it says a lot; expanded-body content is admitted as `omitted_features`.

## Where the principle holds, bends, breaks

Across the three files surveyed:

**Holds cleanly.** struct/class/enum/protocol declarations with fields and direct conformances; function signatures (modulo `sending` / `borrowing` / `consuming` annotations); generic parameters with constraint lists; retroactive-conformance flagging; isolation attributes (`@MainActor`, `nonisolated`); macro application sites; file/line provenance. All of this lives in the source AST and the extractor captures it deterministically. The principle holds without qualification.

**Bends — survives via `language_data.<lang>.*` extensions or via new kinds.** Associated types need a structured slot rather than being shoehorned into `fields`. Macro definitions are statically extractable but need their own kind. Conformances work better as a separate kind than as a nested array inside type records, because retroactive and conditional cases are interesting in their own right. Where clauses are capturable as strings but lossy as structure.

**Breaks — requires honest fidelity-loss markers, or path-3 toolchain invocation.** Macro expansions (synthesized members and conformances invisible without running the macro); property-wrapper-generated storage (`@State var x: Int` injects `_x: State<Int>` and a projected `$x` that the source AST never names); result-builder-rewritten bodies (a `var body: some View { VStack { Text("hi"); Button(…) } }` is transformed before the compiler sees the structural composition); inferred opaque return types (`some View` resolves to a concrete enormous tuple that the compiler computes); dynamic member lookup; conditional conformances applied at use sites.

That third bucket is the honest limit. The extractor either marks these in `omitted_features` and accepts that "which types conform to `View`?" is undercounted across the entire SwiftUI surface, or shells out to the toolchain at the cost of build-context dependence.

## Implications for the extractor design

A few conclusions crystallize once the analysis is grounded in real code rather than abstract taxonomy.

**The catalog needs more kinds than `type`.** In a TypeScript monorepo, one kind plus implicit conformance via `extends`/`implements` listed inline is mostly enough. In Swift, at minimum: `type`, `interface`, `conformance` (extracted separately so retroactive and conditional cases are first-class), `macro_definition`, `macro_application`. The TS-flavored kinds in the current [`pipeline-contract.md`](pipeline-contract.md) do not fit Swift without expansion.

**The two-tier schema earns its keep for Swift, but cross-language joins barely materialize.** Pushing PATs, isolation, retroactive flags, where clauses, and sending into `language_data.swift.*` is correct — none of them have a meaningful cross-language analog. But almost every query that motivates the two-tier design ends up being *within* Swift's idiom (Swift-to-Swift queries on Swift-specific structure). The cross-language joins the design was meant to enable are mostly empty in practice. This deserves to be tested before being designed around.

**Macros need a registry-shaped join.** A `macro_application` record by itself is information-free. It only becomes useful when joined against a `macro_definition` that declares what the macro injects. The good news: macro definitions in this codebase *are* statically extractable — the `@attached(member, names: …)` and `@attached(extension, conformances: …)` attributes spell out the contract. The extractor builds the registry as a byproduct of cataloging. No external registry maintenance burden.

**Property wrappers and result builders are the deepest open question.** SwiftUI is built on result builders. Every `var body: some View { VStack { Text("hi"); Button(…) } }` is rewritten by the `@ViewBuilder` before reaching the compiler's type checker. A structural query like "which views compose a `VStack` of more than five children?" is meaningless from the raw source AST — the children are passed through a builder DSL, and the compiler reconstructs them. The extractor can record "this function body uses an `@ViewBuilder` parameter and has a top-level `VStack`," but cannot enumerate the rendered view structure without running the builder. This is a real limit, and should be admitted in `omitted_features` rather than papered over.

**Worktree exclusion matters here more than in TypeScript.** `wxyc-ios-64`'s `.claude/worktrees/` directory contains four or five partial clones of the whole repo. Running the extractor without exclusion would inflate the catalog roughly fivefold and produce thousands of false duplicates. The dotdir-skipping convention in [`pipeline-contract.md`](pipeline-contract.md#what-to-skip) is correctly load-bearing for Swift — perhaps more so than for TypeScript, where worktrees are typically under `.git/worktrees` and excluded by default.

**SwiftSyntax is the right substrate.** The `AnalyticsMacrosPlugin` already depends on [`swift-syntax`](https://github.com/swiftlang/swift-syntax). Reusing it for the extractor means the same parser the macros use, full Swift 6.2 coverage, and shared exposure to library churn the codebase already manages. The trade-off is dependency weight (multi-megabyte tree) and per-file parse cost (roughly 3–5× slower than ts-morph). For ~2,400 files, a single-threaded SwiftSyntax pass is roughly 30–60 seconds; parallelizing per file gets it under 10 seconds. Fine for an audit, would need attention for per-commit time-series (per [`future-directions.md`](future-directions.md) §1 and §3).

## Recommended order of operations

The order the previous adversarial review pointed to, restated with this study's evidence:

1. **Write the Swift extractor as a single file**, in the same shape as the TS one. Emit records to stdout. Cover `type`, `interface`, `function`, `conformance`, `macro_definition`, `macro_application`. Lose fidelity in the obvious places and record what was lost as informal `omitted_features` strings — do not formalize the schema extension yet.
2. **Run it against `wxyc-ios-64`**. See what the catalog looks like. Check whether the existing [jq queries](../pipeline/queries/) (exact duplicates, name collisions, near-duplicates) produce useful output. They probably will not, because Swift's duplication patterns differ from TS — there is no `Pick<>` analog, but protocol-default-implementation patterns and SwiftUI body composition look like duplication and are not.
3. **Write two new queries** specific to what surfaces. Plausible candidates: "untracked retroactive conformances" and "macro applications whose synthesized members shadow explicitly-declared ones." Run them. Look at output.
4. **With two languages and a handful of real queries, look for what the core projection should actually be.** Do not guess. The shape will be obvious by then.

This sequence treats the catalog schema as something to *derive from evidence*, not *impose ahead of evidence*. The previous instinct — write the JSON Schema, build the conformance suite, set up CI gates first — was the wrong order; it would have baked in a TS-shaped core and the wrong abstractions before the Swift extractor existed to disprove them.

## One prediction

The cross-language `core_projection` in any future contract revision will end up significantly thinner than per-language extensions. Probably just `kind`, `name`, `file`, `line`, `language`, `package`, `shape_sig`, and a `relations[]` array of typed edges. Everything else will live in `language_data.<lang>`. The "joins across languages" use case will turn out to be small — mostly name-collision checks across TS DTOs versus Swift codegen, which is a [`wxyc-shared`](https://github.com/WXYC/wxyc-shared)-style enforcement question and already partially covered by codegen identity.

That single observation is the most actionable take-away from this study. It is also the easiest to falsify by writing the extractor and seeing what queries are actually useful.

## See also

- [`CLAUDE.md`](../CLAUDE.md) — the principle, the layout, the extractor-adding instructions, the jq gotchas
- [`docs/pipeline-contract.md`](pipeline-contract.md) — the current schema, which this study implicitly proposes evolving
- [`docs/case-study.md`](case-study.md) — the TS origin story this study complements
- [`docs/future-directions.md`](future-directions.md) — particularly §2 (broader catalog kinds) and §5 (the case-study library)
- [`extractors/typescript/type-catalog.mjs`](../extractors/typescript/type-catalog.mjs) — the TS reference implementation

External references for the Swift constructs surveyed:

- [`swift-syntax`](https://github.com/swiftlang/swift-syntax) — the parsing and AST library, also the foundation for compiler macros
- [The Swift Programming Language](https://docs.swift.org/swift-book/) — authoritative language reference; chapters on [Macros](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/macros/), [Generics](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/generics/), [Protocols](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/), [Properties](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/properties/), and [Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
- [SE-0382 Expression Macros](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0382-expression-macros.md), [SE-0389 Attached Macros](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0389-attached-macros.md), [SE-0395 Observation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0395-observability.md) — the macros and observation framework that this codebase uses heavily
- [SE-0289 Result Builders](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0289-result-builders.md), [SE-0258 Property Wrappers](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0258-property-wrappers.md) — the two DSL-shaped features that are hardest for an AST-only extractor
- [SE-0244 Opaque Result Types](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0244-opaque-result-types.md), [SE-0335 Existential `any`](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0335-existential-any.md) — `some P` and `any P` distinctions
- [SE-0364 Retroactive Conformance Warning](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0364-warning-for-retroactive-conformances.md) — the source of the `@retroactive` attribute
