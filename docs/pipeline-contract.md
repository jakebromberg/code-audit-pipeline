# Pipeline contract

Every extractor in `extractors/<language>/` emits the same JSON shape so cluster queries don't care which language they're operating on. This is the schema.

The substrate has five catalog kinds today, each in its own JSON file:

- `type-catalog.json` — type / interface / Zod / Drizzle declarations (shape-of-named-members).
- `function-catalog.json` — function / method / arrow-function declarations. Carries body-of-named-callable data (body_hash, body_lines for duplication clustering) **and** signature-of-named-callable data (typed params, return ref, outgoing references for cross-catalog type resolution).
- `file-hashes.json` — file-level content hashes (raw and whitespace-normalized).
- `files.json` — file-level import edges (sibling artifact emitted by `--emit-files`; see [Files artifact](#files-artifact-filesjson) below).
- `package-graph.json` — inter-package dependency edges (V7 §6.5; see [Package graph](#package-graph-package-graphjson) below).

Each section below specifies one. Queries in `pipeline/queries/` consume one specific catalog kind and document which.

## Type catalog (`type-catalog.json`)

The type catalog is a top-level **wrapper object** carrying the schema version, an `extractor` provenance block, identity/timing metadata, and the entry array. (Pre-v1.1 catalogs were a bare array; see [Schema versioning and back-compat](#schema-versioning-and-back-compat) below.)

```jsonc
{
  "schema_version": "2.0",
  "extractor": {
    "language": "typescript",
    "name": "type-catalog",
    "version": "0.4.0",                  // extractor package version
    "source_sha": "9e7ebb5b…"            // git SHA of extractor source tree, or "unknown"
  },
  "fingerprint_v": "shape_sig:1",        // algorithm tag for shape-clustering signatures
  "generated_at": "2026-06-04T19:00:00Z",// ISO-8601 timestamp; one value per extraction run
  "entries": [
    {
      "name": "FlowsheetEntry",            // identifier as declared
      "kind": "interface",                  // see "Kinds" below
      "package": "main",                    // which root this came from
      "file": "src/models/flowsheet.ts",   // path relative to that root
      "line": 42,                           // 1-indexed
      "language": "typescript",             // v2 core projection: language tag
      "symbol_id": "a3f5…",                // sha1 over (package, file, name, kind) joined by NUL bytes, hex lowercase; optional
      "exported": true,                     // true if exported from the file
      "generated": false,                   // true if .d.ts or under generated/
      "is_test": false,                     // true if file path matches test/fixture patterns; see Conventions

      "fields": [                           // sorted "name:type" list, or null
        "album_title:string | null",
        "artist_name:string | null",
        "id:number"
      ],
      "fields_structured": [                // V7 §6.1: parallel to `fields`, with split name/type + flags
        { "name": "album_title", "type": "string | null", "is_optional": true,  "is_static": false },
        { "name": "artist_name", "type": "string | null", "is_optional": true,  "is_static": false },
        { "name": "id",          "type": "number",        "is_optional": false, "is_static": false }
      ],
      "shape_sig": "album_title:string | null|artist_name:string | null|id:number",  // fields.join("|").lower

      "touched_in_window": false,           // true if file is in --touched JSON list

      "extends": ["BaseEntry"],             // class-like supertype names, sorted alpha
      "conforms_to": ["Codable", "Sendable"], // protocol/interface conformance names, sorted alpha
      "references": [                       // names referenced in body, sorted by name
        { "name": "FlowsheetMetadata", "kind": "type-ref" }
      ],
      "references_count": 1,                // == references | length

      // Optional, kind-dependent:
      "generics": "T,U",                    // type-parameter names if generic
      "type_text": "Pick<X, 'a' | 'b'>",   // for non-object type aliases
      "type_sig": "pick<x, 'a' | 'b'>",    // normalized type_text for clustering
      "infer_ref": { "kind": "InferSelectModel", "table": "user" }, // ORM-derived types
      "db_table_name": "user_accounts",     // for ORM table declarations
      "wraps_notification_name": "AVPlayer.rateDidChangeNotification" // Swift only; see Heritage split convention
    }
  ]
}
```

### V7 §6.1: `fields_structured`

Parallel to `fields`, with each member split into its components. Emitted on every record where `fields` is non-null; sorted in lockstep with `fields` (by the flat `"name:type"` string) so `fields[i]` and `fields_structured[i]` refer to the same member.

| Sub-field | Meaning |
|---|---|
| `name` | identifier (without trailing `?`) |
| `type` | verbatim type annotation as written in source. Swift preserves syntactic sugar (`Int?` stays `Int?`, `Optional<Int>` stays `Optional<Int>`); TypeScript preserves declared union form (`string \| null`). |
| `is_optional` | structural flag: `true` for Swift `T?` / `T!` / `Optional<T>` / `Swift.Optional<T>` and TS `T \| null` / `T \| undefined` / `T?` syntax |
| `is_static` | `true` for Swift `static` / `class` modifiers; TS `static` |
| `is_computed` | `true` when the member is a *computed* property — one whose accessor block declares a `get` / `set` (or `_read` / `_modify` / address) accessor — rather than stored state. Stored properties, including those carrying `willSet` / `didSet` observers, are `false`; so are enum cases and methods. **Additive, Swift extractor only for now.** Consumers must treat an absent key as `false` (`.is_computed // false`) so catalogs predating the flag, and extractors that do not yet emit it, keep working. Lets queries that reason about per-instance persisted state (e.g. `persistence-store-field-density`) exclude derived properties. |

`is_optional` is the load-bearing flag — string-matching trailing `?` on `type` is unreliable across the spelling variants (`Int?` vs `Optional<Int>` differ on trailing-`?` but are semantically equal), but the structural flag is consistent. Carrying both `type` (verbatim) and `is_optional` (structural) is intentional redundancy: `type` is ergonomic for display, `is_optional` is reliable for structural matching.

**Enum cases.** Records of `kind: "type-alias-union"` derived from Swift enums emit one `fields_structured` entry per case:

| Case shape | `type` value |
|---|---|
| `case foo` (no associated value, no raw value) | `""` (empty string) |
| `case foo(Int, String)` (associated values) | `"(Int, String)"` (the parameter clause verbatim) |
| `case foo = 1` or `case foo = "x"` (raw value) | `"=1"` or `"=\"x\""` (leading `=` then raw-value text) |

Enum cases always emit `is_optional: false`, `is_static: false`, and `is_computed: false`.

**Status.** Populated by the Swift extractor (V7 §6.1). TypeScript extractor parity follows the same schema and is tracked separately.

The flat `fields[]` form is preserved unchanged for V6-era queries; new queries (`pat-candidates`, `generic-struct-candidates`, etc.) can consume either form.

#### Example (Swift)

```jsonc
"fields_structured": [
  { "name": "cacheLifespan", "type": "TimeInterval",       "is_optional": false, "is_static": true,  "is_computed": false },
  { "name": "cacheLoadTask", "type": "Task<Void, Never>?", "is_optional": true,  "is_static": false, "is_computed": false },
  { "name": "displayName",   "type": "String",             "is_optional": false, "is_static": false, "is_computed": true  },
  { "name": "id",            "type": "String",             "is_optional": false, "is_static": false, "is_computed": false }
]
```

#### Example (TypeScript, forward-looking)

```jsonc
"fields_structured": [
  { "name": "album_title", "type": "string | null", "is_optional": true,  "is_static": false },
  { "name": "artist_name", "type": "string | null", "is_optional": true,  "is_static": false },
  { "name": "id",          "type": "number",        "is_optional": false, "is_static": false }
]
```

## Kinds

| Kind | Source construct (TypeScript) | Source construct (other languages) |
|---|---|---|
| `interface` | `interface X { … }` | Python: `Protocol`; Go: `type X interface { … }`; Rust: `trait` |
| `type-alias-object` | `type X = { … }` | Python: `TypedDict`; Go: `type X struct { … }`; Rust: `struct` / `union` |
| `type-alias-union` | `type X = A \| B \| C` | Python: `Union[…]`; Rust: `enum` variants |
| `type-alias-intersection` | `type X = A & B` | (rare elsewhere) |
| `type-alias-infer-model` | `type X = InferSelectModel<typeof T>` or `type X = typeof T.$inferSelect` | SQLAlchemy: `Mapped[…]`; Django: model classes |
| `type-alias-other` | other utility types | mapped/conditional types |
| `zod-object` | `const X = z.object({ … })` | Python: Pydantic `BaseModel`; Go: validator tags |
| `drizzle-table` | `pgTable("…", { … })` or `wxyc_schema.table(…)` | Python: SQLAlchemy `Table(…)`; Go: GORM struct |
| `import` | `import { X } from "pkg"` (consumer-edge row, see "Import rows" below) | Python: `ast.Import`/`ast.ImportFrom`; Swift: `ImportDeclSyntax` |

Languages without an exact analog can extend with their own kind values — keep prefix conventions (`type-alias-*`, etc.) so queries can pattern-match.

## Import rows (`kind: "import"`)

Opt-in via the `--include-imports` CLI flag. When enabled, the extractor emits one row per imported symbol (consumer-edge data: "this file consumes this name from that published package"). Off by default so legacy queries see byte-stable output; existing queries already filter on `.kind` and naturally exclude import rows, with two defensive guards added in the same PR (`name-collisions.jq`, `touched-window-debt-summary.jq` — positive-kind whitelist).

The data is intended for cross-repo queries (`consumers-of.jq` — #156; `renamed-consumers.jq` — #158) that need to map "exported symbol from package A" to "every file across every repo that imports it."

### Schema

```jsonc
{
  "name": "DiscogsTrack",              // origin-package side spelling (queryable against declarations)
  "kind": "import",
  "package": "main",                    // existing field — which root the FILE belongs to
  "file": "src/services/lookup.ts",
  "line": 3,                            // 1-indexed line of the import statement
  "exported": false,                    // always false; emitted for shape uniformity
  "generated": false,
  "is_test": false,
  "touched_in_window": false,

  "import_form": "named",               // see table below
  "imported_as": "DiscogsTrack",        // local alias (== name if no `as` clause); null for side-effect
  "origin_specifier": "@wxyc/shared",   // raw text as written in source
  "origin_package": "@wxyc/shared",     // bare-specifier strip; null for relative/computed
  "origin_resolution": "bare-specifier", // bare-specifier | relative | computed
  "type_only": false,                   // true for `import type {…}` or per-binding `{ type X }`

  "extends": [],                        // always; required-on-every-row
  "conforms_to": [],                    // always; required-on-every-row (import rows never declare conformance)
  "references": [],                     // always; required-on-every-row
  "references_count": 0                 // always; required-on-every-row
}
```

### `import_form` mapping

| Source statement | Rows emitted |
|---|---|
| `import { A, B as C } from "pkg"` | 2 rows: `{name: "A", imported_as: "A"}`, `{name: "B", imported_as: "C"}`, both `import_form: "named"` |
| `import { type T } from "pkg"` | 1 row, `import_form: "named"`, `type_only: true` |
| `import type { T } from "pkg"` | 1 row, `import_form: "named"`, `type_only: true` (declaration-level) |
| `import D from "pkg"` | 1 row, `name: "default"`, `imported_as: "D"`, `import_form: "default"` |
| `import * as ns from "pkg"` | 1 row, `name: "*"`, `imported_as: "ns"`, `import_form: "namespace"` |
| `import "pkg/polyfills"` | 1 row, `name: null`, `imported_as: null`, `import_form: "side-effect"` |
| `export { A } from "pkg"` | 1 row, `import_form: "re-export"` |
| `export * from "pkg"` | 1 row, `name: "*"`, `imported_as: "*"`, `import_form: "re-export"` |
| `export * as ns from "pkg"` | 1 row, `name: "*"`, `imported_as: "ns"`, `import_form: "re-export"` |
| `await import("pkg")` (string-literal arg) | 1 row, `name: "*"`, `imported_as: null`, `import_form: "dynamic"` |
| `import(\`./x/${y}\`)` (templated arg) | 1 row, `origin_specifier: "<computed>"`, `origin_resolution: "computed"`, `origin_package: null` |
| `const x = require("pkg")` | 1 row, `name: "*"`, `imported_as: "x"`, `import_form: "require"` |
| `const { a, b: c } = require("pkg")` | 2 rows, `import_form: "require"`, `name: "a"`/`"b"`, `imported_as: "a"`/`"c"` |
| `require("pkg")` (call-statement) | 1 row, `name: "*"`, `imported_as: null`, `import_form: "require"` |

`name: null` for side-effect imports is the one exception to the otherwise-invariant non-null `name` field. Queries that group by `.name` need a `select(.name != null)` guard. The defensive kind filter on `name-collisions.jq` already excludes these.

### `origin_package` resolution (v1: bare-specifier only)

Pure text rule, no filesystem reads:

- Specifier starts with `.` or `/` → `origin_package: null`, `origin_resolution: "relative"`.
- Bare specifier starts with `@` → take the first two `/`-separated segments (e.g., `@wxyc/shared/dtos/lookup` → `@wxyc/shared`).
- Bare unscoped specifier → take the first segment (e.g., `lodash/fp` → `lodash`).
- Computed/templated `import()` argument → `origin_specifier: "<computed>"`, `origin_resolution: "computed"`, `origin_package: null`.

Tier 2 (parse `tsconfig.json` `compilerOptions.paths`; walk `package.json` `name` from the resolved target) is intentionally deferred until a real query demands it. The bare-specifier rule already covers the cross-repo case `consumers-of.jq` targets (30 sibling repos importing from `@wxyc/shared` all have bare specifiers).

### v1 limitations (documented)

- Non-trivial `require()` patterns (computed arguments, conditional/nested requires, non-`VariableDeclaration` parents besides bare call-statements) are skipped silently. Recall on real TS codebases is unaffected.
- Templated dynamic-import specifiers are emitted with the `<computed>` marker — missing-data is worse than partial-data for audit reports, but the row's `origin_package` is `null` so it won't join against any declaration.
- File-level (not per-specifier) `type_only` is recorded on `import type { X, Y }` — both bindings record `type_only: true`. The per-binding form `import { type X, Y }` correctly records `type_only` per-binding.

### Effect on existing queries

Every cluster query in `pipeline/queries/*.jq` either: (a) filters on `.kind` against a positive whitelist (most queries — `cross-package-shadows.jq:16`, `exact-duplicates.jq`, `near-duplicates.jq`, etc., do this already); (b) filters on `.shape_sig` or `.fields` which import rows don't carry; or (c) is `name-collisions.jq` / `touched-window-debt-summary.jq`'s name-collision section, both of which gain a positive kind whitelist in the same PR. Net effect: enabling `--include-imports` does not change the output of any existing query.

## Required fields

- `name`, `kind`, `package`, `file`, `line`, `is_test`, `extends`, `conforms_to`, `references`, `references_count`

`extends`, `conforms_to`, and `references` are arrays (possibly empty) on every entry — never `null`. Empty arrays still serialize so consumers can do `(entries[] | select(.references_count == 0))` or `(entries[] | select((.conforms_to // []) | any))` without surprising-null guards. `references_count` is a derived field: `references | length`. It's emitted explicitly because jq queries that filter on it are noisier with the inline length call.

The kinds that admit no inheritance clause syntactically (currently: `type-alias-other`) may omit `extends` and `conforms_to` entirely rather than emit empty arrays — the queries treat absent and `[]` identically via `.extends // []`.

## Required-when-applicable

- `fields` + `shape_sig` for any "shape-of-named-members" construct (interface, struct, type literal, Pydantic model, etc.). Without these the cluster queries can't compare it.
- `type_text` + `type_sig` for non-object type aliases. Without these the InferModel-style derived-type clustering won't work.

## Optional but useful

- `exported`, `generated`, `touched_in_window`, `generics`, `infer_ref`, `db_table_name`, `fields_structured` (V7 §6.1)
- `reference_count` (grep-style identifier-occurrence count, populated by a second pass — coarse "name appears anywhere in scanned source" signal; distinct from `references_count` which is the structural count of typed references inside this declaration's body)
- `wraps_notification_name` (string | absent) — the verbatim body-expression text of a Swift type's `static var name: Notification.Name { … }` member, when the type also conforms to a `*NotificationMessage` protocol (or Foundation's iOS 26 `NotificationCenter.MainActorMessage` / `NotificationCenter.AsyncMessage`). Populated only by the Swift extractor. Consumed by `notification-wrapper-grouping.jq` to find cross-module notification cross-fire. The query joins by exact string equality — convention: both wrappers spell the name the same way (`AVPlayer.rateDidChangeNotification` verbatim at both sites, not one as `.rateDidChangeNotification`). Singular today; the schema can grow to an array additively if a multi-name case appears.

### `infer_ref` shape

For `type-alias-infer-model` records, `infer_ref` carries:

- `kind` — one of four legal values: `InferSelectModel`, `InferInsertModel` (legacy `drizzle-orm` API) or `$inferSelect`, `$inferInsert` (modern Drizzle API). Both APIs are semantically equivalent; the extractor recognizes them in the same `infer_ref` shape so a single join can match either spelling.
- `table` — the TypeScript identifier (not the SQL string). `InferSelectModel<typeof flowsheet>` and `typeof flowsheet.$inferSelect` both record `table: "flowsheet"`. Cross-package joins against `drizzle-table.name` (the variable name, not `db_table_name`) work uniformly.

### Intersection-type resolution

`type X = A & B & { c: number }` entries (kind `type-alias-intersection`) emit `fields` populated by unioning their operands' field sets, when all operands resolve. A second pass walks the catalog up to 5 iterations to handle transitive cases (`Y = X & C`). Resolved entries carry:

- `resolved_from: "intersection"` — marker so downstream queries can include or exclude these synthetically-resolved shapes.
- `operands: ["A", "B", "<literal>"]` — names of the type references and `"<literal>"` placeholders for inline literals. Diagnostic trace.

If at least one operand can't be resolved (utility types like `Pick<X, 'a'>`, conditional types, or references whose declaration was outside the scanned roots), the entry stays at `fields: null` and gains:

- `unresolved: true`
- `unresolved_operands: ["Pick<X, 'a'>", …]` — the operands that defeated resolution.

This is additive: intersection types that resolve get treated like normal shape-bearing constructs by `subset-pairs.jq`, `near-duplicates.jq`, `exact-duplicates.jq`, etc. Intersection entries that fail to resolve stay invisible to those queries, as before.

**Order-dependent conflict resolution.** When two operands declare the same field name with different types (`type X = { a: string } & { a: number }`), the extractor keeps the FIRST occurrence in declaration order. TypeScript's true semantics would intersect (`string & number = never`); the substrate flattens to the first binding so `shape_sig` stays deterministic. This is a clustering tool, not a type-checker — if you need conflict detection, compare operand field-type pairs separately, or wait for the dedicated check that will accompany #5 (substrate-emitted cluster_ids).

### `extends`, `conforms_to`, and `references` semantics

All three fields are sorted (alphabetically), deduplicated, and never `null` (empty array on declarations with no heritage / no body refs).

**`extends`** is the supertype-edge axis (class-like inheritance). Populated for:

| Construct | `extends` content |
|---|---|
| `interface X extends A, B {}` | `["A", "B"]` |
| `type X = A & B & { … }` | `["A", "B"]` (intersection-named operands) |
| `type X = A & B` (pure intersection, no literal) | `["A", "B"]` |
| `type X = A` (simple alias to a name) | `["A"]` (resolves through the intersection mechanic when the alias is canonical) |
| `type X = A \| B` (union) | `[]` — union variants are *references*, not `extends`. Treating union variants as inheritance would over-claim. |
| `type X = Pick<Y, "a">` (utility alias) | `[]` — the utility itself isn't a supertype. |
| `zod-object`, `drizzle-table`, `type-alias-other` | `[]` in v1 (best-effort) |
| Swift `class Foo: BaseClass` | `["BaseClass"]` |
| Swift `extension Foo` (`extension Foo: Bar`) | `["Foo"]` (the extended type — the extension IS-A extension-of Foo) |
| Swift enum raw-value `enum E: String` | `["String"]` (raw-value position is syntactically indistinguishable from a leading protocol — see Heritage split convention) |

**`conforms_to`** is the protocol/interface-implementation axis (issue #217). Populated for:

| Construct | `conforms_to` content |
|---|---|
| Swift `class Foo: BaseClass, ProtoA, ProtoB` | `["BaseClass", "ProtoA", "ProtoB"]` (see default-both rule below) |
| Swift `struct S: Sendable, Hashable` | `["Hashable", "Sendable"]` |
| Swift `protocol P: Q, R` | `["Q", "R"]` (protocol heritage is conformance-only; Swift forbids protocol↔class inheritance) |
| Swift `extension Foo: Codable` | `["Codable"]` |
| TS `class X implements I, J` | `["I", "J"]` (slot reserved; TS class emission deferred — see below) |
| TS `interface`, `type-alias-*`, `zod-object`, `drizzle-table` | `[]` (interfaces use `extends`, not `implements`) |

### Heritage split convention

Issue #217 separated class-like inheritance (`extends`) from protocol/interface conformance (`conforms_to`) because cluster queries want to distinguish "all members share a real superclass" (rare and unrevealing) from "all members conform to a non-trivial protocol" (the high-signal *already-abstracted* case).

**Swift's default-both rule.** Swift's surface syntax does not distinguish a class supertype from a protocol conformance:

```swift
class Foo: BaseClass, ProtoA { … }
//        ↑ class       ↑ protocol — both look the same syntactically
```

Without a type resolver, the extractor cannot disambiguate at extraction time. So it consults two curated sets in `extractors/swift/Sources/swift-catalog/Common.swift`:

- `CLASS_LIKE_INHERITED` — well-known Apple-framework classes that only appear as superclasses (`NSObject`, `UIView`, `UIViewController`, etc.).
- `PROTOCOL_LIKE_INHERITED` — well-known stdlib / SwiftUI / Foundation protocols that only appear as conformances (`Equatable`, `Hashable`, `Codable`, `Sendable`, SwiftUI's `View`, `App`, `ViewModifier`, etc.).

For identifiers in neither set, the **default-both** rule applies: the identifier is appended to BOTH `extends` and `conforms_to`. Cluster queries disambiguate at query time by joining against the target's `kind` in the catalog (a `kind: "interface"` target is a protocol; everything else is class-like). This trades up-front extraction precision for downstream recoverability via deterministic catalog joins — the same pattern V7 §6.5's package-graph uses for cross-package resolution.

`ProtocolDeclSyntax` is the one exception: Swift forbids protocols inheriting from concrete types, so every identifier in a protocol's heritage clause is unambiguously a conformance. The extractor short-circuits the partition and routes the whole list to `conforms_to`.

**Extensions** record their *extended type* in `extends` (the extension IS-A extension-of that type, structurally), with any explicit conformance clause contributing only to `conforms_to`. So `extension Foo: Hashable {}` emits `extends: ["Foo"]`, `conforms_to: ["Hashable"]`.

**TypeScript asymmetry (v1).** The TS extractor doesn't currently emit class declarations as type records, so `class X implements I` has no row to attach `conforms_to: ["I"]` to. Every emitted TS row carries `conforms_to: []` for shape uniformity. Cluster queries that consume `conforms_to` (the *already-abstracted* downrank — see `pipeline/queries/_canonical.jq` `is_already_abstracted_cluster`) will never fire on TS-only catalogs in v1. The schema slot is reserved; wiring TS class emission is a forward-compatible follow-up.

**The wxyc-ios-64 use-case** that motivated the split: a 5-member `exact-duplicates` cluster of types all conforming to `MusicService` (a non-trivial protocol) shouldn't surface as a missing-abstraction candidate — the abstraction already exists. With `conforms_to` populated and a `kind`-aware lookup against the catalog's protocol records, cluster queries can demote these clusters (move them to a separate section) without losing the signal entirely. See `notification-wrapper-grouping.jq` and the `is_already_abstracted_cluster` helper for the consumer side.

**`references`** is the names-in-body axis. Populated for every declaration with a recognizable type body. Each entry is `{name: string, kind: "type-ref"}`. The `kind` slot is present from v1 so future kinds (`call-ref`, `import-ref`) extend without a schema break.

Type-parameter names declared by the enclosing declaration are excluded from `references` (so `interface Foo<T> { x: T }` produces `references: []`, not `[{name: "T"}]`). Mapped types (`{[K in keyof S]: …}`) and function types (`<T>(x: T) => T`) introduce their own scopes for the same reason — the walker threads a `Set<string>` of in-scope type-parameter names so nested generics shadow correctly.

A curated **deny-list of built-in / utility type names** (`Pick`, `Omit`, `Partial`, `Promise`, `Array`, `Map`, `Date`, etc., plus the Drizzle infer helpers `InferSelectModel` / `InferInsertModel` which are already first-class via `infer_ref`) excludes these from references. Without the filter, `Promise` and `Pick` would dominate every graph as the highest-degree nodes. The complete list lives in `extractors/typescript/type-catalog.mjs` as a single `BUILTIN_TYPE_DENYLIST` constant — adding new entries (e.g., a TS lib upgrade adds `NoInfer`) is a one-line change.

**v1 node coverage** for the references walker (TypeScript extractor):

- Explicitly modeled (dedicated walker branch): `TypeReferenceNode`, `TypeQueryNode` (`typeof X` — emits `X`), `ImportTypeNode` (`import("x").Y` — emits `Y` via the qualifier), `FunctionTypeNode`, `ConstructorTypeNode` (both introduce a child scope for their type parameters), `MappedTypeNode` (the key `[K in …]` enters a child scope; `keyof …` constraint and the `as` rename clause are walked).
- Container nodes (recurse via `ts.forEachChild`, full coverage of identifier descendants): `TypeLiteralNode`, `UnionTypeNode`, `IntersectionTypeNode`, `ArrayTypeNode`, `TupleTypeNode`, `IndexedAccessTypeNode`, `ParenthesizedTypeNode`. These have no identifier of their own to emit — they wrap inner types whose own walker branches do the extraction.
- Deferred node forms (walked via `ts.forEachChild`, may produce false positives because the node *form* embeds extra semantics this walker doesn't model): `ConditionalTypeNode`, `InferTypeNode`, `TemplateLiteralTypeNode`, `TypeOperatorNode`, `ThisTypeNode`, `LiteralTypeNode`. Identifiers buried in these still surface via their `TypeReferenceNode` descendants. Example: `T extends U ? X : Y` emits all three names because the walker doesn't track which branch is "live."
- Best-effort (v1 ships empty references): `zod-object`, `drizzle-table`. Their builder DSLs are not walked. The `type-alias-infer-model` kind walks the inner type argument and surfaces the table identifier as a reference, e.g., `InferSelectModel<typeof users>` → `references: [{name: "users", kind: "type-ref"}]`.

**Self-references** are emitted: `interface Node { children?: Node[] }` produces `references: [{name: "Node", kind: "type-ref"}]`. The graph view consumer wants the self-loop edge; suppressing it would obscure recursive structure.

**Qualified-name extraction**: for `TypeReferenceNode` whose `typeName` is a `QualifiedName` (e.g., `Namespace.Inner.Type`), the **leftmost** identifier is emitted as the reference (`Namespace`). This matches the resolution rule used by the sibling `references.json` artifact's `(package, name)` lookup. Heritage clauses (`interface X extends Lib.Foo`) and intersection operands (`type X = Lib.Foo & B`) both preserve the **full dotted form** in `extends` — the supertype identity is what a graph-view consumer wants to display, not its namespace prefix. The diverging convention between `extends` (full) and `references` (leftmost) is rare in practice and is the v1 trade-off documented here. The downstream resolution pass (when ambiguity hits) handles the `(package, name)` lookup uniformly via the leftmost identifier.

### Sibling `references.json` artifact

When invoked with `--emit-references-graph <path>`, the extractor writes an inverted edge list to `<path>`:

```jsonc
{
  "schema_version": "2.0",
  "extractor": { "language": "typescript", "name": "type-catalog", "version": "0.5.0", "source_sha": "9e7ebb5b…" },
  "fingerprint_v": "shape_sig:1",
  "generated_at": "2026-06-04T19:00:00Z",
  "edges": [
    {
      "from": { "package": "main", "name": "FlowsheetView" },
      "to":   { "package": "main", "name": "FlowsheetEntry" },
      "kind": "type-ref",
      "resolved": true
    },
    {
      "from": { "package": "main", "name": "RemoteShape" },
      "to":   { "package": "main", "name": "Unknown" },
      "kind": "type-ref",
      "resolved": false
    }
  ]
}
```

Each `references[]` entry on a declaration produces one edge. Resolution prefers a same-package target; failing that, a `shared`-package target; failing that, marks the edge `resolved: false` with `to.package == from.package` (fallback for unresolved external names). Edges are deduplicated by `(from.package, from.name, to.package, to.name)` and sorted by the same key, so two runs over the same input produce byte-identical files.

The `extractor` block matches the wrapper used by every other sibling artifact (catalog, files); consumers that already read `.edges` keep working unchanged.

The artifact is the right home for inverted ("what depends on X?") queries:

```jq
.edges | map(select(.to.name == "FlowsheetEntry")) | group_by(.from.package)
```

The inline `references[]` field on each catalog entry is the right home for forward ("what does X depend on?") queries — including the graph-view consumer that needs per-node outgoing edges.

#### Consumer: `dead-code.jq`

The first consumer of this artifact is `pipeline/queries/dead-code.jq`, which surfaces exported, non-generated declarations with zero resolved incoming references. Invocation:

```bash
jq -L pipeline/queries -r --slurpfile refs references.json \
  -f pipeline/queries/dead-code.jq catalog.json
```

The query keeps only `resolved: true` edges (per the resolution rule above) and drops self-references (`type Tree = { children: Tree[] }` emits a `Tree → Tree` edge that the recursive-type author didn't intend as a live consumer), then projects each surviving entry whose incoming count is zero. Known v1 false-positive class: types kept alive only through barrel re-exports (`export { Foo } from './x'`) — the walker doesn't currently emit a synthetic edge for re-exports.

## Conventions

### Field encoding

Each field in `fields` is `"name:type"`, where:

- `name` includes `?` if optional (e.g., `email?:string`).
- `type` is the raw type text, **normalized** (whitespace collapsed to single spaces, trimmed).
- The array is sorted alphabetically by full string. This makes `shape_sig` deterministic regardless of declaration order.

### `shape_sig` computation

```
shape_sig = fields.sorted().join("|").lower()
```

Lowercasing means `Foo` and `foo` collide. That's intentional — case differences are usually not semantic.

### Path-relative-to-which-root?

`file` is relative to the root that produced it. The `package` field tells you which root. For example, with `--root /a/b/main --shared /a/b/shared`:

- A file at `/a/b/main/src/foo.ts` → `package: "main"`, `file: "src/foo.ts"`
- A file at `/a/b/shared/src/bar.ts` → `package: "shared"`, `file: "src/bar.ts"`

Cluster queries that compare across packages always include the `package` field in their grouping or output.

### What to skip

Default skip-list (extractors may extend):

- `node_modules/`, `dist/`, `build/`, `coverage/`
- **Any directory beginning with `.`** — `.git/`, `.next/`, `.claude/`, `.cursor/`, `.idea/`, `.vscode/`. These typically hold IDE/agent state or git worktree clones; descending into them inflates the catalog with near-duplicate copies of the same repo.

Test files are always extracted; every row carries an `is_test: bool` flag derived from the file path. To exclude tests post-hoc from a catalog, pipe through `jq 'map(select(.is_test | not))'`.

### Test path patterns

`is_test` is true if **any** of the following match a row's `file` path. The patterns below are normative — other-language extractors must implement the same set so cluster queries don't have to special-case per language. Language-specific extensions are MUST-when-applicable and are listed below.

**Universal directory patterns** (any path segment, any depth):

- `tests`, `test`, `__tests__`, `__test__`
- `spec`
- `__mocks__`
- `__fixtures__`, `fixtures`
- `e2e`

**Universal filename patterns** (basename only):

- `*.test.<ext>` / `*.spec.<ext>` — for whichever source extensions the extractor reads
- `*.fixture.<ext>` / `*.fixtures.<ext>`
- `*.mock.<ext>` / `*.mocks.<ext>`

**Language-specific extensions:**

| Language | Additional patterns |
|---|---|
| TypeScript | `<ext>` ∈ `{ts, tsx, mts, cts}` for the universal filename patterns |
| Python | `test_*.py`, `*_test.py`, `conftest.py` |
| Go | `*_test.go` |
| Swift | `Tests/` (capital T, SwiftPM convention). Extractors may extend with AST-based `XCTestCase`-subclass detection. |
| Rust | `tests/` (integration-test convention, already covered universally). Extractors may extend with AST-based `#[cfg(test)]`-module detection. |

The AST-based extensions noted above (Swift `XCTestCase`, Rust `#[cfg(test)]`) fall under the "extractor may extend" clause — they're permitted and encouraged, but not required for v1 parity.

## Files artifact (`files.json`)

Sibling artifact emitted by `type-catalog.mjs --emit-files <path>` (opt-in). One row per source file, carrying the resolved import / re-export / dynamic-import edges leaving that file. Consumed by `pipeline/queries/cross-package-backward-imports.jq` (the first consumer; layering check that flags `shared/*` files importing from `main/*`) and forecast consumers include cycle-detection, unused-imports, dependency-mass-per-file, and the graph-view import-edge layer (#147, sub-issue of #119).

The artifact is opt-in to keep existing extractor invocations byte-stable for users who aren't running the new queries yet — same pattern as `--emit-references-graph`.

```jsonc
{
  "schema_version": "2.0",
  "extractor": {
    "language": "typescript",
    "name": "type-catalog",
    "version": "0.4.0",
    "source_sha": "9e7ebb5b…"
  },
  "fingerprint_v": "shape_sig:1",
  "generated_at": "2026-06-04T19:00:00Z",
  "entries": [
    {
      "path": "src/services/flowsheet.service.ts",
      "package": "main",
      "is_test": false,
      "imports": [
        { "package": "main",   "path": "src/models/flowsheet.ts", "type_only": false, "kind": "import",         "line": 3 },
        { "package": "shared", "path": "src/dtos/discogs.ts",     "type_only": true,  "kind": "import",         "line": 5 },
        { "package": "extern", "path": "drizzle-orm",             "type_only": false, "kind": "import",         "line": 1 },
        { "package": "main",   "path": "src/lib/lazy.ts",         "type_only": false, "kind": "dynamic-import", "line": 12 },
        { "package": "main",   "path": "src/models/index.ts",     "type_only": false, "kind": "re-export",      "line": 1 }
      ]
    }
  ]
}
```

### Row fields

| Field | Meaning |
|---|---|
| `path` | File path relative to its package root. Mirrors `file` on type-catalog rows. Field renamed to `path` because `file` reads awkwardly as a top-level key on a file-shaped row. |
| `package` | `"main"` or `"shared"`. Externals never appear at the row level — every `entries[]` row is a real file. |
| `is_test` | File-path-derived flag, same patterns as the type-catalog (`### Test path patterns` above). |
| `imports[]` | Every import / re-export / dynamic-import edge from this file. |

### Import-row fields

| Field | Meaning |
|---|---|
| `package` | Resolved target package: `"main"`, `"shared"`, or `"extern"`. |
| `path` | For `main`/`shared`, the resolved path relative to that package's root (joins on `entries[].path` for any same-row target). For `extern`, the verbatim `moduleSpecifier` text. |
| `type_only` | Declaration-level `isTypeOnly` flag (`import type … from`, `export type { … } from`). `false` for `dynamic-import`. |
| `kind` | `"import"` \| `"re-export"` \| `"dynamic-import"`. |
| `line` | 1-indexed source line of the statement. |

### Resolver

- Relative specifiers (`./y`, `../foo/bar`) are resolved against the importing file's directory. Probe order: exact path, then `.ts`, `.tsx`, `.mts`, `.cts`, then the same set inside `<spec>/index.<ext>`. First hit wins.
- Targets resolving under `--root` are tagged `package: "main"`; under `--shared`, tagged `package: "shared"`.
- Targets resolving outside both, or non-relative specifiers (bare `'drizzle-orm'`, scoped `'@org/pkg'`, absolute `/abs/path`), are tagged `package: "extern"`. For unresolved or non-relative specs, `path` is the raw `moduleSpecifier` text — for `extern` targets that resolved to a concrete absolute path outside `ROOT`/`SHARED`, `path` is that absolute path.
- No de-duplication per file: two imports of the same module produce two rows.

### v1 limitations (known, documented)

- **No `tsconfig.json` `paths` aliases.** An alias-based import (`import { X } from '@app/foo'`) is tagged `extern` with the raw alias text — a backward-imports check across aliases won't fire until the resolver learns aliases. Deferred to v2 because alias resolution adds nontrivial code (parse `tsconfig.json`, walk `extends`, apply `paths` regex) and most cycles don't cross alias boundaries.
- **No CommonJS `require('./x')`.** The TS extractor is ESM-flavored. Mirrors the same gap in `eslint-plugin-import/no-cycle`.
- **No per-specifier type-only annotation.** `import { type X, Y } from './y'` records `type_only: false` at the declaration level even though `X` itself is type-only. The layering check doesn't care, so v1 records only the declaration-level flag.
- **Templated dynamic-import specifiers skipped.** `import(\`./${name}\`)` is silently dropped because the spec text isn't statically known.

### Determinism

- `entries[]` sorted by `(package, path)`.
- `imports[]` within each entry sorted by `(package, path, kind, line)`.
- Two runs over the same input produce byte-identical files.

### Stats

Stderr summary: `Wrote files (<N> files, <M> edges) to <path>`.

## Function catalog (`function-catalog.json`)

The function catalog is a top-level **wrapper object** (schema v2.0) carrying schema version, extractor provenance, identity/timing metadata, and the entry array. Pre-v1.1 catalogs were a bare array; queries consume via the `entries` helper in `_canonical.jq` which accepts both forms.

```jsonc
{
  "schema_version": "2.0",
  "extractor": {
    "language": "typescript",
    "name": "function-catalog",
    "version": "0.5.0",
    "source_sha": "9e7ebb5b…"
  },
  "fingerprint_v": "shape_sig:1",
  "generated_at": "2026-06-04T19:00:00Z",
  "entries": [
    {
      "name": "betterAuthSessionToAuthenticationData",
      "kind": "function",                          // function | method | arrow-function | function-expression
      "package": "main",
      "file": "lib/features/authentication/utilities.ts",
      "line": 89,
      "language": "typescript",
      "generated": false,
      "exported": true,
      "async": false,
      "is_test": false,                            // file-path derived, same patterns as type-catalog
      "touched_in_window": false,                  // from --touched JSON list
      "synthetic": false,                          // always false; reserved for future

      "param_count": 1,
      "param_names": ["session"],

      // Body-level data (duplication clustering). NULL when normalized body
      // has fewer than --min-body-lines lines (default 3). The row is still
      // emitted so signature-level data is available for one-liner functions.
      "body_hash": "<sha256 of normalized body>",  // null for short bodies
      "body_line_count": 48,                       // null for short bodies
      "body_length": 1500,                         // null for short bodies
      "body_lines": ["..."],                       // null for short bodies

      // Signature-level data (cross-catalog type resolution).
      "generics": "T,U",                           // comma-joined; empty string if none
      "params": [
        {
          "name": "session",
          "type_ref": "BetterAuthSession",         // single ident or null for primitives / inline shapes
          "type_refs": [                           // full deduped set; same shape as type-catalog .references[]
            { "name": "BetterAuthSession", "kind": "type-ref" }
          ]
        }
      ],
      "return_ref": "AuthenticationData",          // single ident or null
      "references": [                              // sorted union of params[].type_refs + return_ref + own generic-bound trait names
        { "name": "AuthenticationData", "kind": "type-ref" },
        { "name": "BetterAuthSession",  "kind": "type-ref" }
      ],
      "references_count": 2,                       // == references | length

      "signature_index": 0                         // 0 for non-overloaded; >0 for additional overload heads
    }
  ]
}
```

**Method-name qualification.** For class methods, `name` is `ClassName.methodName`. For methods on anonymous classes, just the method name.

**Body normalization.** Comments (line `//` and block `/* */`) are stripped, internal whitespace runs collapsed to single spaces, each line trimmed, blank lines dropped. `body_hash` is sha256 of `body_lines.join('\n')`. `body_lines` is also de-duplicated and sorted, so it can serve as the input set for Jaccard pairwise comparison without further work.

**Body-fields gating.** Functions whose normalized body has fewer than `--min-body-lines` (default 3) lines emit a row with `body_hash` / `body_lines` / `body_line_count` / `body_length` all `null`. Body-level cluster queries (`function-duplicates.jq`, `generic-function-candidates.jq`, `default-impl-candidates.jq`) early-filter with `select(.body_hash != null)`. Signature-level queries (`public-api-leaks.jq`) consume rows regardless of body presence — exported one-liner functions still need leak detection.

**Signature-level fields.** `type_ref` is the single-identifier form of a `TypeReferenceNode`; `null` for primitives, unions, anonymous inline shapes. `type_refs` is the full deduped set of references inside the param's type (handles `Foo | Bar`, generics expansion). The function-level `references` is the sorted-deduped union of all `params[].type_refs`, the `return_ref` identifier (when non-null), **and** the trait names named in the callable's own generic-parameter bounds (`<T: Encoder>` → `Encoder`; TypeScript constraints and Rust inline bounds alike) — with the generic *parameter* names themselves filtered out. So `function f<T>(x: T): T` records zero refs, but `function f<T: Encoder>(x: T): T` records `Encoder`. Because bound trait names need not appear in any `params[].type_refs`, `references` is a *superset* of `union(params[].type_refs) ∪ {return_ref}`, not exactly that union. Resolution semantics match the type-catalog's `references[]`: name-only, unqualified, resolved by downstream queries against the type-catalog index.

**Overloaded signatures.** TypeScript allows multiple declaration heads sharing one implementation body. Each head emits its own row with `signature_index` 0..N (0 = first declared head). The implementation head is the one with non-null `body_hash`. Overload-naive queries can ignore `signature_index`; overload-aware queries can dedupe by `(name, package, file)`.

**Skip rules.** Generated files (`*.d.ts`, `generated/`) are marked `generated: true` like the type catalog. Tests are always extracted; `is_test` flag derived from the same file-path patterns the type catalog uses.

Used by `pipeline/queries/function-duplicates.jq` (body clustering), `pipeline/queries/public-api-leaks.jq` (signature-level type leak detection — joins via `--slurpfile types type-catalog.json`), `pipeline/queries/generic-function-candidates.jq`, `pipeline/queries/default-impl-candidates.jq`.

## File-hash catalog (`file-hashes.json`)

The file-hash catalog is a single JSON array. Each entry describes one source file:

```jsonc
[
  {
    "package": "main",
    "file": "lib/features/playlist-search/utils.ts",
    "generated": false,
    "size_bytes": 994,                                  // raw size
    "size_normalized": 994,                             // after CRLF→LF, trailing-whitespace strip, trailing blank lines dropped
    "sha256": "<raw bytes sha256>",
    "sha256_normalized": "<normalized sha256>"
  }
]
```

**Normalization.** `CRLF` → `LF`, trailing whitespace stripped per line, trailing blank lines dropped. `sha256_normalized` catches "same file, editor / line-ending drift" pairs that raw `sha256` would miss.

**Skip rules.** Skips `.dotdirs`, `node_modules`, `dist`, `build`, `coverage` (shared with the type extractor) plus `tests/` and `*.test.*` / `*.spec.*` files unless `--include-tests` is passed. Extension filter is configurable via `--extensions` (default `ts,tsx,mts,cts`). (Forward-looking: the type extractor has dropped `--include-tests` and tags every row with `is_test` instead — see `## Type catalog` → `### Test path patterns`. Aligning file-hashes with that model is pending.)

### Optional `header_match` field (extractor v0.6.0+)

When the extractor is invoked with `--scan-header`, every record additionally carries:

```jsonc
{
  // ...standard file-hashes fields above...
  "header_match": {                                    // null when no phrase matched
    "line": 1,                                          // 1-indexed line of the match
    "phrase": "copied from",                           // lowercased phrase that triggered the match
    "text": "// Copied from DebugPanel for shader testing."  // raw source line, trailing whitespace stripped
  }
}
```

The extractor reads the first 30 lines of each file and matches against a fixed phrase list (`copied from`, `fork of`, `based on`, `duplicate of`, `ported from` — case-insensitive substring). When `--scan-header` is **not** set, the field is **omitted entirely**, preserving byte-stable output for legacy readers. Consumed by `pipeline/queries/copied-from-header.jq` (#220).

Used by `pipeline/queries/file-duplicates.jq` (two sections: exact-byte and whitespace-normalized-only clusters) and `pipeline/queries/copied-from-header.jq` (files whose top comment self-confesses as a fork, when `--scan-header` is set).

### Optional `mark_count` / `line_count` / `mark_labels` fields (extractor v0.6.0+)

When `file-hashes.mjs` is invoked with `--scan-marks` (a Swift-calibrated convenience flag), every record carries three additional top-level fields:

```jsonc
{
  "package": "app:iOS",
  "file": "Sources/Audio/AudioPlayerController.swift",
  "generated": false,
  "size_bytes": 36000,
  "size_normalized": 35990,
  "sha256": "...",
  "sha256_normalized": "...",
  "mark_count": 13,                          // count of `// MARK:` lines in the file
  "line_count": 812,                         // total source-line count (see "Line counting" below)
  "mark_labels": [                           // 1-indexed line numbers + captured labels
    { "line": 12,  "label": "Singleton" },
    { "line": 67,  "label": "Player Factory" },
    { "line": 134, "label": "State" }
  ]
}
```

`mark_count` and `mark_labels[].label` are populated by the regex `/^[ \t]*\/\/\s*MARK:\s*-*\s*(.*?)\s*$/` — Swift's `// MARK: <title>` (with or without an optional visual `-` separator of any length). Triple-quoted multi-line strings can contain MARK-shaped lines and will be counted; this is documented and accepted.

**Line counting.** `line_count` is the count of source lines after `split('\n')` with a trailing empty entry trimmed. For files terminated by `\n` this matches POSIX `wc -l`; for files without a trailing `\n` the implementation counts the final partial line while `wc -l` does not (the file `"abc"` reports `line_count = 1` here, `0` from `wc -l`). CRLF and bare CR line endings are both normalized to LF before splitting, and a leading UTF-8 BOM is stripped so the first line's `// MARK:` is matched.

**Omitted entirely when flag unset.** Records produced without `--scan-marks` carry zero of the three fields — not `null`, not `0`. Downstream queries gate on `select((.mark_count // null) != null)` to stay back-compatible. This matches the convention used for other optional file-hashes fields.

Used by `pipeline/queries/mark-section-density.jq`, which surfaces long files with high MARK density as maintainer-pre-labeled refactor candidates.

## Literal catalog (`literal-catalog.json`)

The literal catalog records where numeric and static-string literals appear, to surface "a copy that must track another value" drift — two declarations independently spelling the same constant (the motivating audit cases: a view's private `placeholderCornerRadius = 6.0` silently mirroring another type's private `cornerRadius: CGFloat = 6.0`, and a `static let stationCapFlagKey = "on_tour_for_you_station_cap"` hand-copied into a second type; when one changes, the other doesn't). Currently emitted by the Swift extractor (`swift-catalog literal`).

Like `file-hashes.json`, this is an **occurrence catalog**, not a declaration catalog: a single JSON array whose rows deliberately omit `name` / `kind` / `is_test` / `language`. A literal occurrence has no declaration identity — the discriminator is `form`, and each form carries its own context fields.

```jsonc
[
  {
    // Core projection (shared with every catalog).
    "package": "RowKit",
    "file": "Sources/RowKit/SongRowContent.swift",
    "line": 14,                          // the LITERAL's line, not the enclosing declaration's
    "generated": false,

    // Value triple.
    "value": "6.0",                      // verbatim as written; prefix minus folded in ("-4", not "4"); string values keep their quotes ("\"on_tour_for_you_station_cap\"")
    "value_norm": "6",                   // cross-spelling join key — see Normalization
    "value_kind": "float",               // "int" | "float" | "string"

    // Position discriminator.
    "form": "binding",                   // "binding" | "argument"

    // binding-form fields (omitted on argument rows).
    "binding_name": "cornerRadius",
    "is_static": true,
    // "access": "private",              // access modifier as written; omitted when none

    // argument-form fields (omitted on binding rows).
    // "callee": "RoundedRectangle",     // base name of the called expression
    // "arg_label": "cornerRadius",      // omitted for unlabeled arguments

    // Enclosing context (either form; omitted when absent).
    "enclosing_type": "ArtworkStyle"     // dotted nesting-stack qualification, extensions push the extended type
    // "enclosing_callable": "body"      // innermost func/init/deinit/subscript/computed-property name
  }
]
```

**Emission positions.** Numeric literals emit in two positions: (1) `let` / `var` binding initializers whose initializer expression is a bare numeric literal (optionally wrapped in one prefix `-`), and (2) numeric literals passed directly as function-call arguments. Static **string** literals emit in the **binding position only** (position 1): a plain, single-line, non-raw, non-interpolated string initializer. This is a deliberate asymmetry — string *arguments* are **not** emitted, because doing so would flood the catalog with localization keys, log messages, and URLs; arg-strings are a possible later widening gated on their own noise analysis. Positions deliberately **not** emitted: enum raw values (already carried by the type catalog's enum-case `fields`), `return` statements, tuple elements, attribute/macro arguments, string *arguments*, interpolated / multiline (`"""…"""`) / raw (`#"…"#`) string literals, and literals nested inside arithmetic expressions (`6.0 * 2` emits nothing). Widening the position set is a version-bump *signal*, not a silent change — cluster thresholds are calibrated against this scope. The literal catalog is a bare JSON array with **no `schema_version` field**, so the bump is a prose signal only: there is no version field to increment and none should be added.

**Callee resolution.** `callee` is the base name of the called expression: `Spacer(minLength: 8)` → `"Spacer"`; `.padding(.horizontal, 16)` / `view.padding(16)` → `"padding"`; `Cache<Int>(capacity: 8)` → `"Cache"`. Calls whose callee has no base name (closures, subscripts) are not cataloged — a row without a callee has no cluster label. Non-literal arguments in an otherwise-matching call emit nothing (`.padding(.horizontal, 16)` produces exactly one row, for `16`).

**Normalization (`value_norm`).** The join key that makes `6`, `6.0`, and `0x6` cluster: underscore separators stripped (`1_000` → `1000`); hex / octal / binary integers re-based to decimal (`0xFF` → `255`); floats parsed and re-serialized — integral floats collapse to the integer spelling (`6.0` → `6`, `1e3` → `1000`), trailing zeros trimmed (`0.50` → `0.5`). `value_kind` still records the source-level type family, so queries can require like-for-like kinds when clustering. Unparseable input (e.g. an integer literal overflowing 64 bits) falls back to the stripped, lowercased text.

**String values (`value_kind: "string"`).** For a string binding, `value` is the literal's source text *including* its surrounding quotes (`"on_tour_for_you_station_cap"`); `value_norm` is the concatenated content of the string's segments with the quotes removed — verbatim, with **no case-folding and no escape decoding**. Escapes stay literal: `"a\tb"` normalizes to the four characters `a\tb` (backslash-`t`), not a tab. Determinism is all the join key needs — two identically-written literals produce the same `value_norm` — and case is preserved so `"Foo"` and `"foo"` do not collide. Because the numeric normalizations above (radix, float collapse) are meaningless for strings, a string `value_norm` is never cross-spelling-folded; queries must not unify a string with a numeric of the same text (`"2"` ≠ `2`), which the copied-literal query enforces with a kind-class bucket.

**Skip rules.** The Swift walker's standard skips (dotdirs, `node_modules` / `build` / `dist` / `coverage` / `DerivedData` / `Pods`, `Tests/` directories and `*Tests.swift` unless `--include-tests`). Note the polarity: tests are *excluded by default* here — this catalog predates per-row `is_test` tagging, matching file-hashes' documented pending alignment.

Consumed by the copied-literal query lane (`pipeline/queries/copied-literal-candidates.jq`).

## Package graph (`package-graph.json`)

V7 §6.5 enrichment. Cross-package dependency edges so an agent can name the *correct* extraction target package (one already upstream of both consumers) rather than recommending an arbitrary "common" package. The graph is a single JSON object, not an array, because two parallel collections (nodes and edges) are the natural representation and re-deriving one from the other on every query would be wasteful.

```jsonc
{
  "schema_version": "1",
  "nodes": [
    { "name": "Shared/Core",      "kind": "package", "path": "Shared/Core/Package.swift" },
    { "name": "Shared/Caching",   "kind": "package", "path": "Shared/Caching/Package.swift" },
    { "name": "iOS",              "kind": "app",     "path": "WXYC.xcodeproj/project.pbxproj" }
  ],
  "edges": [
    { "from": "Shared/Caching", "to": "Shared/Core",      "source": "Package.swift" },
    { "from": "iOS",            "to": "Shared/Core",      "source": "pbxproj" },
    { "from": "iOS",            "to": "Shared/Networking","source": "pbxproj" }
  ]
}
```

### Nodes

Every node has `name`, `kind`, `path`. Names are stable identifiers used as both endpoints in `edges` and as join keys against the `package` field on type-catalog / function-catalog records (when the same convention applies — see "Package-name conventions" below).

| `kind` | Source | When emitted |
|---|---|---|
| `package` | A `Package.swift` SwiftPM manifest (Swift) or `package.json` (TypeScript, forward-looking). | One per manifest discovered under `--root`. |
| `app` | A target inside `*.xcodeproj/project.pbxproj`. | One per `PBXNativeTarget` whose `productType` includes `application` / `app-extension` / `watchapp`, or which has a non-empty `packageProductDependencies` list. |

Nodes are sorted by `name` (ASCII-ordered, capital letters before lowercase) so output is byte-deterministic.

### Edges

Every edge has `from`, `to`, `source`. Edges are directed: `from` depends on `to` (i.e., `to` is upstream). The `source` field records which substrate input declared the edge:

| `source` | Origin |
|---|---|
| `Package.swift` | `.package(path: "...")` or `.product(name: ..., package: ...)` calls inside a SwiftPM manifest. Parsed via SwiftSyntax. |
| `pbxproj` | `XCSwiftPackageProductDependency` entries referenced by a `PBXNativeTarget`'s `packageProductDependencies` list. Parsed via brace-counting text scan (the [xcodeproj Ruby gem](https://github.com/CocoaPods/Xcodeproj) and the Python [pbxproj](https://github.com/kronenthaler/mod-pbxproj) library fail on complex projects, per the [wxyc-ios-64 CLAUDE.md](https://github.com/wxyc/wxyc-ios-64). The methodology doc's [§6.5](refactor-recommendation-experiment-methodology.md#enrichment-package-graph) prescribes line-by-line text processing as the fallback.). |

Edges are sorted by `(from, to, source)` so output is byte-deterministic. Edges are deduplicated by the same triple — a target that imports `.product(name: "Core")` from a `.package(path: "../Core")` produces a single edge, not two.

### Package-name conventions

For SwiftPM manifests, a node's `name` is the path of the manifest's containing directory relative to `--root` (e.g., `Shared/Core/Package.swift` → `name: "Shared/Core"`). This intentionally diverges from the type-catalog's `package` field (which uses just the last path segment, `"Core"`); the package-graph keeps the disambiguating prefix because two parallel layouts (`Shared/Core` and `Vendor/Core`) need distinct nodes. Downstream joiners that need to bridge the two conventions should match against the trailing path segment.

For Xcode `app` nodes, the `name` is the verbatim `PBXNativeTarget.name` (e.g., `iOS`, `watchOS`, `widget`). These don't go through the path-prefix transform; an app target isn't path-rooted in the SwiftPM sense.

### Submodule note

Git submodules (e.g., `Shared/Wallpaper` in wxyc-ios-64) have empty working directories until `git submodule update --init --recursive` runs. The extractor emits a stderr warning when it finds a `Package.swift` sitting next to a submodule-pointer `.git` *file* (not directory) with no other content — that's the signature of an uninitialized submodule. The node is still emitted so downstream consumers see the gap; only its outbound edges may be missing.

### Schema-version contract

`schema_version: "1"` marks the schema this document describes. Increment on any breaking change to node/edge shape; consumers should refuse to operate on unrecognized versions.

### Invocation

```
swift-catalog package-graph --root <path> [--output <path>]
```

Walks `<root>` recursively for `Package.swift` files (skipping `.git`, `.build`, `.swiftpm`, `node_modules`, `build`, `dist`, `coverage`, `DerivedData`, `Pods`) and for any `*.xcodeproj/project.pbxproj`. Emits the JSON object above to stdout (or `--output <path>`). Summary stats (manifest count, pbxproj count, node/edge totals, parse errors, warnings) go to stderr.

Exit code: `0` if at least one `Package.swift` or `project.pbxproj` was discovered; `1` if neither was found.

## Schema versioning and back-compat

The catalog top level carries `schema_version: "2.0"` (current). The current TS extractor always emits the wrapper form (`{schema_version, extractor, fingerprint_v, generated_at, entries}`); the bare-array form is a pre-v1.1 artifact.

**Format.** Every `schema_version` is a `"MAJOR.MINOR"` string. Patch versions are not represented (doc-only clarifications do not change the schema string).

### Version-bump rules

| Bump | Trigger | Consumer impact |
|---|---|---|
| **Patch** (1.x.y → 1.x.(y+1); not represented in `schema_version`) | Documentation clarification only. No schema change. | None. Consumers see no observable difference. |
| **Minor** (1.x → 1.(x+1)) | Additive change. A new optional per-entry field; a new optional top-level key; a new permitted `kind` value. | Existing consumers continue to work unchanged. New consumers can read the new field. |
| **Major** (1.x → 2.0) | Either (a) redefines or removes existing semantics — renaming a kind, changing `shape_sig` normalization, removing a field — or (b) signals an intentional architectural reorganization even when byte-level changes are additive (e.g., v2.0's two-tier core-projection ratification). The bump itself is the signal; consumers should re-read the contract. | The diff machinery (#117) refuses to compare across major bumps; warns across minor. Additive-major bumps are themselves comparable as additive, but the diff tool defaults to refusal until an operator passes `--allow-additive-major` (see #117). |

**1.1** was a minor bump from 1.0: the bare array became a wrapper object with `schema_version` + `extractor` + `entries`. **1.2** is a minor bump from 1.1: `symbol_id`, `fingerprint_v`, `generated_at`, and `extractor.source_sha` are all additive and optional from a consumer's perspective. Existing queries continue to work against 1.2 catalogs unchanged. **2.0** is the v2 two-tier ratification (see "Schema v2 — two-tier ratification" below): the byte-level changes are additive (`language` field, optional `language_data.<lang>.*`, optional `relations[]`, optional honesty markers), but the contract reorganizes around a cross-language core projection. Existing v1 catalogs continue to validate; existing v1 queries continue to run.

### Identity and provenance (v1.2)

**`symbol_id`** — sha1 over the 4-tuple `(package, file, name, kind)` joined by NUL bytes (`\x00`), lowercase hex. Hex string. Optional per entry; consumers synthesize the same value on read when absent. Extractors should emit when they can. The audit query [`pipeline/queries/symbol-id-collisions.jq`](../pipeline/queries/symbol-id-collisions.jq) flags any catalog where two entries share the 4-tuple. The 595-entry case-study corpus surfaces zero collisions; this is the regression guard. **Why NUL and not `/`** — package values legitimately contain forward slashes (`Shared/Generated`, `Shared/Analytics`; first-class throughout the fixtures and `_canonical.jq`), and file paths obviously do. A `/`-joined formula is not injective: `(package="Shared", file="Generated/X.ts", name="X", kind="interface")` and `(package="Shared/Generated", file="X.ts", name="X", kind="interface")` flatten to the same string and hash to the same sha1, silently merging unrelated entries when cross-repo joins use `symbol_id` as the key. NUL cannot appear in identifiers or POSIX path components, so the formula is structurally collision-safe.

**`fingerprint_v`** — algorithm tag for shape-clustering signatures. Current value `"shape_sig:1"` corresponds to the existing `sorted | join("|") | lower` definition. Bumping the algorithm bumps the tag. Cross-catalog cluster queries that join on `shape_sig` first check this tag matches between catalogs. Convention: `"<algorithm>:<version>"`. Future variants (`"body_hash:1"` for function-catalog body clustering, `"field_names_sig:1"` for shape-of-named-members independent of types — per #118) follow the same convention. No formal enum; the registry grows lazily.

**`generated_at`** — ISO-8601 timestamp recorded once at extraction time and reused across every sibling artifact (`type-catalog.json`, `references.json`, `files.json`, `function-catalog.json`) emitted by the same extractor invocation. Downstream diff and snapshot tooling consume it; queries do not depend on it.

**`extractor.source_sha`** — git SHA of the extractor's own source tree, captured by shelling out to `git rev-parse HEAD` inside the extractor's source directory. For extractors run outside a git checkout (vendored binary, `code-audit init`-extracted sources without `.git`, missing `git` on PATH), records the literal string `"unknown"` and emits exactly this stderr warning at extraction start:

```
warning: extractor source not in a git checkout; source_sha recorded as "unknown"
```

This is the load-bearing field for "did the extractor itself change between two catalogs?" The diff machinery (#117) treats `source_sha` mismatch as a reason to warn (extractor output may have changed semantics despite identical `extractor.version`).

### Schema v2 — two-tier ratification

v2.0 (`schema_version: "2.0"`) is the ratification of the two-tier shape the Python and Swift extractor design notes converged on. It is technically additive at the consumer level (every existing field continues to mean what it meant in v1.2) but conceptually reorganizes the contract around a small **core projection** of cross-language fields, with language-specific extensions cordoned into `language_data.<lang>.*`. That reorganization warrants the major-version label even though the byte-level diff is small.

`schema_version: "2.0"` validates under the same `MAJOR.MINOR` string convention as v1.1 / v1.2; the regex `/^[12]\.\d+$/` (or, more generally, `/^\d+\.\d+$/`) is the accepted check.

#### Core projection (v2)

Required on every record, regardless of language:

- `name` (string) — identifier as declared in source.
- `kind` (string) — from the cross-language vocabulary (`migration`, `sql-query`, `sql-external-reference`, `external-import`) or a language-specific extension (`interface`, `type-alias-*`, `zod-object`, `drizzle-table`, `import`, `type`, `conformance`, `macro_definition`, `macro_application`, `pydantic-model`, `fastapi-route`, `fastapi-dependency`, `dataclass`, `enum`, `pyo3-function`, …). The vocabulary is open; extractors document their kinds in their own notes.
- `package` (string) — extraction root identifier.
- `file` (string) — path relative to that root.
- `line` (number, 1-indexed).
- `language` (string) — `"typescript"`, `"swift"`, `"python"`, `"rust"`, `"go"`, `"sql"`, etc.

Required-when-applicable (carried forward from v1, semantics unchanged):

- `shape_sig` and `fields[]` for shape-of-named-members constructs.
- `type_text` and `type_sig` for non-object type aliases.

Optional carry-overs from v1: `exported`, `generated`, `touched_in_window`, `generics`, `infer_ref`, `db_table_name`, `fields_structured`, `extends`, `references`, `references_count`, `symbol_id`, `is_test`.

Optional v2 additions:

- `language_data` (object; keys are language names, values are language-specific extension namespaces).
- `relations` (array of typed-edge objects; see "Relations slot" below).
- `core_projection_complete` (boolean; absence implies `true`).
- `omitted_features` (array of strings; absence implies `[]`).

#### `language_data.<lang>.*` namespace

The `language_data` object is keyed by language name. Each value is the language-specific extension namespace — fields whose meaning is only legible inside that language's idiom. A single record can carry multiple language sub-namespaces (e.g., a Python `sql-query` record carries both `language_data.python.*` for composition info and `language_data.sql.*` for dialect info).

Fields under `language_data.<lang>.*` are NOT part of the cross-language core projection. Queries that operate cross-language work against the core projection; queries that operate on language-specific structure pin to a language and read its sub-namespace.

Every field name below traces to a specific illustrative record in [`docs/pipeline-contract-v2-fixtures.jsonl`](./pipeline-contract-v2-fixtures.jsonl). New fields require a corresponding illustrative record before they enter the table — the "speculation gate" enforces evidence-driven schema growth.

| Language | Field | Where seen (fixture record) |
|---|---|---|
| `swift` | `decl_kind`, `access`, `conformances[]`, `macro_applications[]`, `associated_types[]`, `inherited_protocols[]`, `member_isolation`, `is_retroactive`, `is_unchecked`, `context`, `roles[]`, `synthesized_member_names[]`, `synthesized_conformances[]`, `implementation_module`, `implementation_type` | Swift File 1 (`FetchPlaylistEvent`), Swift File 2 (`AnalyticsEvent` macro), Swift File 3 (`MainActorNotificationMessage`, `Notification → Sendable`) |
| `python` | `bases[]`, `base_alias`, `future_annotations`, `field_metadata`, `method`, `path`, `router_name`, `router_decl_file`, `router_decl_line`, `mount_file`, `mount_line`, `mount_prefix`, `router_prefix`, `decorator_path`, `request_model`, `response_model`, `dependencies[]`, `mount_dependencies[]`, `query_params[]`, `tags[]`, `composition`, `static_prefix`, `fragment_alternatives[]`, `execute_sites[]`, `loaded_from[]`, `transformations[]`, `execute_via`, `returns`, `depends_on[]`, `is_async`, `singleton`, `singleton_state_name`, `lifecycle_close`, `errors_raised[]`, `base`, `members[]`, `decorator`, `field_defaults`, `qualified_name`, `implementation_language`, `implementation_package`, `resolution`, `imported_as`, `migration_framework`, `revision`, `down_revision`, `upgrade_ops[]`, `guards[]` | Python Files 1–7 |
| `sql` | `dialect`, `tables_read[]`, `tables_written[]`, `columns_selected[]`, `where_predicates[]`, `order_by[]`, `placeholder_count`, `placeholder_style` | Python File 3 Form A (`_FLOWSHEET_SQL`) and Form B (`_search_uncached:filtered-branch`) |
| `rust` | `fn_signature`, `pyo3_attribute`, `registered_in` | Python File 6 Path 2 (`to_match_form` PyO3 view) |

Worked example (Python File 3 Form A):

```jsonc
{
  "kind": "sql-query", "name": "_FLOWSHEET_SQL", "language": "python",
  "package": "semantic-index", "file": "semantic_index/pg_source.py", "line": 57,
  "language_data": {
    "python": { "composition": "static-literal", "execute_sites": [{"function": "load_flowsheet_entries"}] },
    "sql":    { "dialect": "postgresql", "tables_read": ["wxyc_schema.flowsheet"], "where_predicates": [{"left":"entry_type","op":"=","right":"'track'"}] }
  }
}
```

`language: "python"` is the *host* language (the SQL is composed by Python); `language_data.sql.*` carries the dialect-specific shape. The two-tier schema doing its work.

#### Relations slot

`relations` is a flat array of typed-edge objects. Each edge has at minimum:

- `kind` (string) — relation type.
- `target` (string) — the related symbol's name, fully qualified when possible.

Edges may carry additional kind-specific fields (e.g., `retroactive: true`, `unchecked: true` for conformances; `via_macro: "AnalyticsEvent"` for synthetic conformances derived from macro joins).

Open vocabulary; example `kind` values used in the v2 fixtures:

| `kind` | Where seen |
|---|---|
| `extends` | Python File 2 (`LookupRequest extends _GeneratedLookupRequest`) |
| `conforms_to` | Swift File 3 (`Notification → Sendable` retroactive); v2 generalization of Lane A's per-record `conforms_to: string[]` |
| `applies_macro` | Swift File 1 (`FetchPlaylistEvent applies_macro AnalyticsEvent`) |
| `mounts_router` | Python File 1 (`main.py mounts_router lookup_router with_prefix /api/v1`) |
| `loads_sql_from` | Python File 3 Form C (Alembic migration loads external `.sql` files) |

Existing `extends: string[]` on type records remains as a v1 shorthand. v2 introduces `relations[]` as the canonical form. Queries can adopt either: `extends[]?` continues to work for the shorthand; `relations[] | select(.kind == "extends") | .target` for the canonical form. The cluster-query refits (#116) decide which form each query consumes.

#### Honesty markers

`core_projection_complete: false` and `omitted_features[]` mark records where the extractor knows it has lost fidelity vs. the source.

Default `core_projection_complete: true` and `omitted_features: []` (both may be absent — absence implies completeness).

Examples drawn from the v2 fixtures:

- `["macro_expansion"]` — Swift File 1: a macro-applied struct whose synthesized members and conformances are not in the source AST.
- `["inherited_fields"]` — Python File 2: a Pydantic subclass that declares only the additions; base-class fields live in another record reachable via `relations[] | select(.kind == "extends")`.
- `["runtime_branch_choice", "dynamic_column_list"]` — Python File 3 Form B: an f-string SQL with conditional branches the AST cannot statically resolve.
- `["sending_parameter_annotation", "self_type_resolution"]` — Swift File 3: a protocol whose member signatures carry Swift 6 isolation annotations the v2 schema does not yet model.

Vocabulary is freeform strings. v2 does not impose a closed enum. If a future audit query demands controlled vocabulary, that's a v2.1 conversation.

Existing cluster queries do not consult these fields; they are for downstream filters ("show me only rows where the catalog is honest about its losses") and for documentation/communication.

#### Cross-language kinds (v2)

Cross-language `kind` values — the same `kind` appears in records from multiple languages, with language-specific payload under `language_data.<lang>.*`:

- `migration` — schema migration (Alembic for Python, Drizzle for TypeScript, Flyway/Liquibase elsewhere). `language_data.<lang>.{migration_framework, revision, down_revision, upgrade_ops, guards, …}`.
- `sql-query` — a SQL statement composed inside a host language. `language: "<host>"`; `language_data.sql.{dialect, tables_read, tables_written, columns_selected, where_predicates, order_by, placeholder_count, placeholder_style}`; `language_data.<host>.{composition, execute_sites, static_prefix, fragment_alternatives, …}`.
- `sql-external-reference` — host-language code that loads a SQL file at runtime. `language_data.<host>.{loaded_from, transformations, execute_via}`.
- `external-import` — host-language code that imports a symbol whose implementation lives in a different language (PyO3, FFI, native extensions). `language_data.<host>.{imported_as, implementation_language, implementation_package, resolution}`. The host-side of the PyO3 cross-language pair; the implementation-side row is `pyo3-function` (under Rust in the language-specific kinds below) — together they form the join key for cross-language consumption queries.

Language-specific kinds (within a single language ecosystem; documented for clarity):

- TypeScript: `interface`, `type-alias-object`, `type-alias-union`, `type-alias-intersection`, `type-alias-infer-model`, `type-alias-other`, `zod-object`, `drizzle-table`, `inline-object`, `import`.
- Swift: `type` (struct/class/enum), `interface` (protocol), `conformance`, `macro_definition`, `macro_application`.
- Python: `pydantic-model`, `fastapi-route`, `fastapi-dependency`, `dataclass`, `enum`.
- Rust: `pyo3-function` — a Rust function exported across the PyO3 FFI boundary. `language: "rust"`; `language_data.rust.{fn_signature, pyo3_attribute, registered_in}`; `language_data.python.qualified_name` carries the Python-side import path so a cross-language query can join on it. See the `pyo3-function` row in [`docs/pipeline-contract-v2-fixtures.jsonl`](pipeline-contract-v2-fixtures.jsonl) for the canonical record shape, and the per-language field-namespace table under "Schema v2 — two-tier ratification" → "`language_data.<lang>.*` namespace" (the `rust` row in that table) for the authoritative per-language field map. Paired with the host-side `external-import` row above to form the cross-language join.

#### v2 deliberate scope

v2 does NOT redefine `shape_sig`, change the normalization rule for any field, or remove any v1 field. It is structurally additive. The major-version label is a signal that the *contract has reorganized*: cross-language extractors and consumers should target v2's core projection, not v1's TS-shaped one. Existing v1 catalogs continue to validate; existing v1 queries continue to run.

### Query migration

Queries consume entries via the `entries` helper in `pipeline/queries/_canonical.jq`, which accepts both forms for one deprecation cycle:

```jq
def entries:
  if type == "array" then .                            # v1.0 bare-array
  elif type == "object" and has("entries") then .entries  # v1.1+ wrapper
  else error("expected catalog: top-level must be array (v1.0) or object with .entries (v1.1+)")
  end;
```

Each query starts its top-level pipeline with `entries[]` (or `entries as $all`) instead of the bare `.[]`. To migrate a downstream-authored query: replace `.[]` (or `. as $all`) with `entries[]` (or `entries as $all`) at the top-level entry point, and `include "_canonical";` if not already included.

**End of deprecation:** the bare-array branch will be removed in the next breaking schema bump (forward-looking — no concrete schedule). Until then, both forms work uniformly.

The diff machinery (see #117) refuses to compare catalogs with different `schema_version` values — version coercion is intentionally not a transparent operation.

## CLI contract

Every extractor:

```
extractor --root <path> [--shared <path>] [--touched <json-file>] [--output <path>] [--emit-references-graph <path>] [--emit-files <path>] [--include-imports]
extractor --list-relevant [--include-tests] [--null|-0]      # predicate-only query mode; reads paths from stdin
```

Defaults: `--output` writes to stdout. `--emit-references-graph`, `--emit-files`, and `--include-imports` are off by default. Summary stats (file counts, kind histogram, error count) go to stderr.

Exit code: `0` if at least one file was successfully indexed, `1` if no files could be parsed.

### `--list-relevant` mode

A pure-query mode that exposes the extractor's walk predicate without parsing or indexing. Reads candidate paths from stdin (one per line by default; NUL-separated with `--null`/`-0`), evaluates each against the same predicate the walker uses (extension match, skip-dir, dotdir, test/spec filtering), and writes the kept subset to stdout in input order. `--include-tests` keeps test/spec/fixture/mock paths; without it they're dropped on the query side (the extraction walker continues to index test files and tag each row with `is_test=true`).

Consumed by the PR-comment Action ([#123](https://github.com/jakebromberg/code-audit-pipeline/issues/123)) and the pre-commit hook ([#124](https://github.com/jakebromberg/code-audit-pipeline/issues/124)) to filter `gh pr view --json files` or `git diff --name-only` output to the subset worth feeding to `--touched`. The flag is per-language: each language's extractor exposes its own `--list-relevant` reflecting its own walk semantics. The TypeScript reference is `extractors/typescript/type-catalog.mjs`; other languages adopt the flag with their own predicate definitions per [#159](https://github.com/jakebromberg/code-audit-pipeline/issues/159).

### `code-audit report --mode pr-comment`

The `report` subcommand has two modes:

```
code-audit report --root <path>                                          # default text mode
code-audit report --root <path> --mode pr-comment --touched <touched.json> [pr-comment flags]
```

**Text mode (default).** Iterates every runnable query, runs each in JSONL mode, dispatches each row through the shape renderer (`internal/render/{cluster,pair,metric}.go`), and writes a markdown document to `.audit/reports/findings-YYYY-MM-DD.md` (or `--output <path>`). Errors during any query are listed in a trailing `## Skipped queries` section; engine errors fail the run (exit 1). This mode is the long-form report; behavior is unchanged from pre-#123.

**`pr-comment` mode.** Renders a GitHub PR-comment body keyed by a sticky-comment marker on line 1, with rows filtered (per-row by `shape`) through `--touched`. Differences from text mode:

| Flag | Default | Purpose |
|---|---|---|
| `--touched <path>` | unset | JSON array of repo-relative file paths. Per-row shape dispatch: cluster rows kept iff any member has `touched_in_window: true` OR member's `.file` / `.path` matches the set; pair rows kept iff either endpoint has `touched_in_window: true` OR `.file` / `.path` matches; metric rows are always kept (queries self-filter their nested payload). Envelope-level `touched_in_window: true` short-circuits regardless of shape. Both `file` and `path` member keys are accepted because `cross-package-backward-imports.jq` (sourced from `files.json`) uses `.path`; queries should pick one and stick with it. Path comparison uses `diffmatch.NormalizePath` (trim, CRLF strip, `\` → `/`, leading `./` collapse). |
| `--marker <string>` | `code-audit-pipeline-v1` | Sticky-comment marker emitted as `<!-- <marker> -->` on the first line. Validated against `^[A-Za-z0-9][A-Za-z0-9_.:/-]*$` — must start with an alphanumeric (rejecting leading `-` / `_` / `.` / `/`, which trigger HTML5 bogus-comment paths in strict parsers), no embedded `--` substring (HTML5 forbids it inside `<!-- … -->`), maximum 128 bytes. Characters that would corrupt the HTML comment (`<`, `>`, `&`, whitespace, control characters) are rejected at flag-parse time. Empty markers are rejected — to opt out of sticky behavior, the consumer must use a different posting action. |
| `--size-cap-bytes <N>` | `60000` | Hard cap on rendered body length. Minimum 1024 bytes (rejected at flag-parse below that — the fallback paths can't honor the cap contract with smaller budgets). Sections render in alphabetical name order; when the next section would exceed the cap, that section AND every later section are dropped (preserving an alphabetical prefix) and a footer naming the dropped sections is appended. The cap math reserves a fixed footer envelope so the final body never exceeds `N` bytes — including the footer itself. Default leaves ~4KB headroom under GitHub's 65,536-character PR comment cap. |
| `--on-extraction-failure <loud\|quiet>` | `quiet` for pr-comment, `loud` for text | In `quiet`, per-section errors are logged to stderr and the failing sections are excluded from the rendered body; successful sections still render normally. Only when EVERY non-skipped section failed does the body collapse to the single-line `report unavailable` notice (wording neutral about whether extraction, query execution, or rendering was the failure surface). In `loud` with partial errors, surviving successful sections render in the body and the exit code is 1. In `loud` with all sections failed, the body is the same `report unavailable` notice but exit code is 1. Per-section errors always log to stderr regardless of mode. |
| `--detected-languages <csv>` | empty | Comma-separated language list interpolated into the fail-quiet body. Composite-action consumers forward audit-core's `languages-detected` output here so the fail-quiet body reads `report unavailable for typescript, swift` instead of `<unknown>`. |
| `--output <path>` | stdout | Where to write the comment body. On write failure, the body falls back to stdout so a transient filesystem error doesn't discard the run. |

All five flags above are pr-comment-mode-only — passing any of them without `--mode pr-comment` exits 2 with a usage error rather than silently filtering the text-mode report or ignoring the value.

**Diagnostic stream convention.** Stdout carries the artifact (text-mode the "wrote …" pointer it has always emitted; pr-comment mode the body when `--output` is unset). All diagnostic chatter — caller-input errors, pipeline-internal errors, and the pr-comment-mode "wrote …" pointer — goes to stderr so a workflow that pipes stdout into the PR comment never injects a `code-audit: …` line.

**Error boundary (caller-input vs pipeline-internal).** Bad `--touched` input (missing file, malformed JSON, JSON `null`, non-string array element) and invalid `--marker` exit 2 with a usage error — these are workflow-author bugs that the comment surface must not silently mask. Pipeline-internal errors (catalog missing/corrupt, jq engine failure, renderer dispatch error) flow through the `--on-extraction-failure` switch.

**Empty-results path.** When `--touched` is set but no row survives filtering (or `touched.json` is `[]`), the body is the sticky marker line plus a "no structural impact" notice. The sticky comment still updates so the consumer can see the audit ran.

**Path normalization parity.** The Go normalizer (`internal/diffmatch/pathnormalize.go` `NormalizePath`) is a byte-equal port of the TypeScript `extractors/typescript/_lib/walk-predicate.mjs:34` `normalizePath` function. Parity is gated by `internal/diffmatch/pathnormalize_test.go`'s case table, which mirrors the TypeScript-side `extractors/typescript/test/walk-predicate.test.mjs` regression suite.

Consumed by the PR-comment Action ([#123](https://github.com/jakebromberg/code-audit-pipeline/issues/123)). A composite action at `.github/actions/audit-pr-comment/` and a reusable workflow at `.github/workflows/pr-comment-reusable.yml` will be the canonical consumers — both ship in a follow-up PR; the binary surface documented here stands alone in this release.

## Cluster-query output contract

Every query in `pipeline/queries/*.jq` (excluding the `_canonical.jq` helper library) emits cluster rows in one of two modes, controlled by the `OUTPUT_FORMAT` environment variable.

### Invocation

```bash
# Default (text): human-readable output with `cid=<cluster_id>` annotated on each cluster header.
jq -L pipeline/queries -rf pipeline/queries/<query>.jq <input.json>

# JSONL: one cluster object per line, consumed by the V7 trial harness and the auto-scorer.
OUTPUT_FORMAT=jsonl jq -L pipeline/queries -rf pipeline/queries/<query>.jq <input.json>
```

The `-L pipeline/queries` flag tells jq where to find `_canonical.jq` (the shared library each query includes). Both modes require `-r` — text mode renders multi-line cluster output, JSONL mode emits the `@json`-encoded cluster as a raw line.

### JSONL row schema

Every JSONL row is one self-contained cluster as a JSON object, with at minimum:

- `cluster_id` — stable content-addressed identifier, unique within a single query's output (see formats below).
- `query` — the query that emitted the row.

**On the `query` field:** for most queries the value matches the .jq file name (`"exact-duplicates"`, `"name-collisions"`, `"subset-pairs"`, etc.). For the two dual-section queries (`function-duplicates.jq` and `file-duplicates.jq`) the value carries the section suffix so downstream consumers can filter by section: `"function-duplicates-exact"` vs `"function-duplicates-near"`, and `"file-duplicates-exact"` vs `"file-duplicates-norm"`. A consumer filtering `select(.query == "function-duplicates")` will find no rows; filter by prefix (`startswith("function-duplicates")`) or by exact section name instead.

**On `cluster_id` uniqueness:** within a single query's run, every emitted row has a unique `cluster_id`. This invariant is what lets the V7 trial harness join agent recommendations back to clusters without canonicalization heuristics. The integration tests in `pipeline/queries/_tests/test_queries_integration.sh` assert it per-query; downstream tooling can assume it.

**On the `shape` field:** every row also carries `shape: "cluster"|"pair"|"metric"` per [ADR-0003](adr/0003-canonical-cluster-envelope.md). The shape names which envelope the row conforms to; the code-audit binary's renderer dispatches purely on `shape` (no per-query lookup table). The shape mirrors the `#! shape:` front-matter line at the top of each `.jq` file (single-shape queries) or one of its comma-separated values (dual-section queries like `function-duplicates.jq`). See "Cluster envelope" below.

Query-specific payload fields (`jaccard`, `intersection`, `union`, `shape_sig`, `field_count`, `body_hash`, `swap_tokens`, `slot_diff_count`, etc.) are emitted as the query computes them. Envelope-level fields (`members`, `left`, `right`) are reserved per the shape contract below. Downstream consumers should treat the row as a structured snapshot — query-specific payload is appended to the envelope, never overrides it.

### Cluster envelope (post-PR-1, [ADR-0003](adr/0003-canonical-cluster-envelope.md))

Every JSONL row conforms to one of three shape envelopes. The `shape:` field on the row picks which envelope applies; the binary's renderer is shape-aware, not query-aware.

| Shape | Required envelope fields | Notes |
|---|---|---|
| `cluster` | `cluster_id`, `query`, `shape`, `members[]` | N members grouped by a common key. `members[]` is a JSON array of decl objects. Includes single-member rows (e.g., `orphan-infer-model`, `generic-convention-bound`) — the envelope wraps the decl as `members: [{...}]` of length 1 so the renderer stays shape-aware, not arity-aware. |
| `pair` | `cluster_id`, `query`, `shape`, `left`, `right` | Two endpoints. Field-set variants follow the prefix convention: `left_fields`/`right_fields`, `left_only`/`right_only`, `left_slots`/`right_slots`, `left_swap_tokens`/`right_swap_tokens`. |
| `metric` | `cluster_id`, `query`, `shape` (+ arbitrary payload) | Single-value or summary row. No structural envelope fields beyond the trio; payload depends on the query. |

**Pair direction.** The envelope is direction-free. Directed pairs (`subset-pairs`: `left ⊂ right`) and asymmetric pairs (`test-prod-drift`: `left=prod`/`right=test`; `cross-package-shape-near-duplicates`: `left=main`/`right=shared`) document their convention in the query header and preserve the role labels in text-mode output. JSONL always uses `left`/`right`. The renderer treats every pair uniformly; query-specific role labels appear only in text mode.

**Front-matter declaration.** Each query's header carries a `#! shape: <value>` line ([ADR-0002](adr/0002-hybrid-registration.md) front-matter convention). Single-shape: `#! shape: cluster`. Dual-section: `#! shape: cluster, pair` (e.g., `function-duplicates.jq` emits cluster rows for the exact section and pair rows for the near section). The front-matter is informational/declarative; the renderer dispatches on each row's `shape` field, not on the front-matter.

**Field-name reservation.** Within an envelope, the reserved field names are: `cluster_id`, `query`, `shape`, `members`, `left`, `right`, plus the `left_*`/`right_*` paired variants. Queries must not emit unrelated payload under these names. The reserved set may grow in future schema bumps (`catalog_format` version); back-compat removals follow the same deprecation cycle as catalog schema changes.

### Front-matter grammar (post-PR-2, [ADR-0002](adr/0002-hybrid-registration.md))

Each `.jq` query under `pipeline/queries/` carries a header block of single-line `#! key: value` directives that the future `code-audit` binary parses to register the query. The lines are jq comments — naked `jq` invocations are unaffected. `_canonical.jq` (library, never run standalone) does not carry front-matter.

Recognized keys (PR 2 set; future versions may extend):

| Key | Cardinality | Purpose |
|---|---|---|
| `query` | 1 | Stable identifier matching the `query:` field emitted on JSONL rows. Used as the `code-audit query <name>` selector. Must be unique across files. |
| `shape` | 1 or 2 (comma-sep) | Cluster envelope shape — `cluster`, `pair`, or `metric`. Dual-section queries (`function-duplicates`) list both. The shape mirrors what each emitted row's `shape:` field carries. |
| `catalog` | 1 or N (comma-sep) | Catalog kind(s) the query consumes. First entry is the positional input (jq sees it via `.entries[]`); trailing entries are `--slurpfile` mounts. |
| `arg` | 0..N | `--argjson` / `--arg` flags the query requires. Triplet form: `arg: <name> <type> <default-or-required>`. `<type>` ∈ `number`/`string`/`json`. |
| `env` | 0..N | Environment-variable knobs. Triplet form: `env: <NAME> <type> <default-or-empty>`. |
| `formats` | 1 | Comma-separated `OUTPUT_FORMAT` values supported. Always `text, jsonl` for queries that emit JSONL; `text` only for ones that don't. |
| `desc` | 1 | One-line description (≤ 100 chars). Surfaces in `code-audit query --help`. |
| `version` | 0..1 | Front-matter grammar version (default 1 when absent). |

**Worked example** — `exact-duplicates.jq`:

```jq
# exact-duplicates.jq — find type clusters with the same shape_sig
# ...
#! query: exact-duplicates
#! shape: cluster
#! catalog: type-catalog
#! formats: text, jsonl
#! desc: Cluster types whose shape_sig is identical (byte-equal field+type set).

include "_canonical";
...
```

The PR-2 integration suite ([`pipeline/queries/_tests/test_queries_integration.sh`](../pipeline/queries/_tests/test_queries_integration.sh)) validates: every required key present, `query:` values unique, `shape:` values from the reserved set, every `arg:` paired with `--argjson`/`--arg` use in the file, every `env: <NAME>` paired with `$ENV.NAME` use. PR 3's binary parser will run the same checks at registration time.

### Extractor `manifest.toml` (post-PR-2, [ADR-0002](adr/0002-hybrid-registration.md))

Each extractor directory (`extractors/typescript/`, `extractors/swift/`, `extractors/file-hashes/`) carries a `manifest.toml` declaring extractor identity, runtime prerequisites, and per-catalog invocation contract. Read by the future `code-audit` binary; the extractor scripts themselves are unchanged.

Schema (versioned via `schema_version`):

- `[extractor]` — `name`, `language`, `version`, `description`.
- `[[command]]` (one or more) — per catalog kind the extractor produces. Fields: `catalog`, `output_file`, `invocation` (token list with `{root}`, `{output}`, `{shared}`, `{touched}`, … placeholders), `optional_args` (inline tables with activation conditions), `sibling_outputs` (artifacts emitted under additional catalog kinds when activated).
- `[runtime]` — `requires` (prereq list the binary checks before invoking) and `setup_hint` (one-line install pointer surfaced on failure).

See [`extractors/typescript/manifest.toml`](../extractors/typescript/manifest.toml) for the canonical example (TypeScript produces both `type-catalog` and `function-catalog`, with `references-graph` as a sibling output activated by the `--emit-references-graph` flag).

### `cluster_id` formats (substrate-emitted, stable)

Each query precomputes its cluster_id via helpers in `pipeline/queries/_canonical.jq`. The format is content-addressed: the same set of declarations always produces the same cluster_id, regardless of which trial or invocation surfaces them.

| Query | `cluster_id` format | Sorting / direction |
|---|---|---|
| `exact-duplicates` | `exact-duplicates:NameA+NameB+...` | sorted member names, `+` separator |
| `name-collisions` | `name-collisions:Name` | the colliding name |
| `cross-package-shadows` | `cross-package-shadows:Name` | asymmetric (main↔shared); just the shadowed name |
| `cross-package-shadows-any` | `cross-package-shadows-any:Name` | symmetric N-package; just the shadowed name |
| `cross-package-shape-near-duplicates` | `cross-package-shape-near-duplicates:LocA+LocB` | sorted location keys (`package:file:line:name`) |
| `cross-package-shape-near-duplicates-any` | `cross-package-shape-near-duplicates-any:LocA+LocB` | sorted location keys |
| `near-duplicates` | `near-duplicates:LocA+LocB` | sorted location keys |
| `near-duplicates-any` | `near-duplicates-any:LocA+LocB` | sorted location keys |
| `subset-pairs` | `subset-pairs:LocSub__LocSup` | directed (sub then sup); swap changes the id |
| `shared-interface-candidates` | `shared-interface-candidates:LocA+LocB` | sorted location keys |
| `function-duplicates` (exact section) | `function-duplicates-exact:Loc+Loc+...` | sorted location keys |
| `function-duplicates` (near section) | `function-duplicates-near:Loc+Loc` | sorted location keys |
| `file-duplicates` (exact section) | `file-duplicates-exact:pkg:path+pkg:path+...` | sorted package-qualified repo-relative paths |
| `file-duplicates` (norm section) | `file-duplicates-norm:pkg:path+pkg:path+...` | sorted package-qualified repo-relative paths |
| `versioned-type-pairs` | `versioned-type-pairs:Pkg__BaseName` | directed (package then base); uses `__` because the package field can carry `/` (e.g. `Shared/Generated`) so `/` is unsafe as an in-slot separator |

**Why every pair-based query uses location keys instead of bare names:** Swift and TypeScript both allow the same `name` to appear on multiple records — `enum Foo` plus `extension Foo` adding computed properties is two records, both named `Foo`. The substrate emits one record per declaration, so pair-based queries that compare records can produce multiple pairs whose endpoints share names. A name-only id like `near-duplicates-any:PlayerState+PlaybackState` would collide whenever both `PlayerState` (enum + extension) and `PlaybackState` (enum + extension) participate in distinct pairs. Location keys (`package:file:line:name`, the same convention `function-duplicates` already used) make each endpoint unambiguous and the cluster_id unique. Real example surfaced on wxyc-ios-64: `PlayerState`/`PlaybackState` collisions on both `near-duplicates-any` (enum-pair plus extension-pair) and `subset-pairs`.

**Grouped queries (`exact-duplicates`, `name-collisions`, `cross-package-shadows*`) keep bare names** because the row IS the group keyed by name (or shape_sig), with all decls in `members[]`. Same-name records collapse into the same row by design, not into separate rows that would collide.

**Why cross-package-shadows is one-row-per-name, not one-row-per-decl:** the original V2 emission was one row per shadowed *decl*, which meant multiple main-package decls shadowing the same shared name would all carry the same cluster_id `cross-package-shadows:Name`. That breaks the within-query uniqueness invariant. V7 changes the asymmetric query to mirror the -any variant: one row per shadowed name, with all main-package occurrences listed in `members`. The cluster_id remains `cross-package-shadows:Name`, now unambiguously identifying a single row.

**Known limitation on `exact-duplicates`:** the id discriminator is the sorted member-name set. Two distinct shape_sig clusters whose member names happen to be identical (different shapes, same names across the cluster) would collide. Practically rare in real codebases — names usually correlate with shapes — but worth knowing if a downstream join surfaces a duplicate. If observed, qualify the id with `shape_sig` at the cost of a longer identifier.

**Why subset-pairs is directed:** the pair (A, B) where A ⊂ B is fundamentally different from (B, A) where B ⊂ A. Most clusters are symmetric; subset-pairs is the one exception, and the directed `Sub__Sup` form preserves that distinction.

**Why file paths are package-qualified:** two packages can have files at the same relative path (`Sources/Utils.swift`). The `package:path` key disambiguates.

### Why substrate-emitted, not agent-derived

V4 measured the cost of agent-derived cluster ids: 2 of 5 trials emitted batched grouped findings instead of one-per-cluster, dropping plant 5–8 detection from 5/5 to 3/5 and dragging C3 intra-trial Jaccard from 1.00 down to 0.85. V5/V6 didn't surface the same variance with their plant sets but the structural exposure stayed. The substrate-emitted `cluster_id` closes the exposure: the agent reads it verbatim and the scorer joins on it without canonicalization heuristics. This is the V7 prerequisite ([issue #5](https://github.com/jakebromberg/code-audit-pipeline/issues/5)).

### Helper library (`_canonical.jq`)

Cluster-id construction lives in `pipeline/queries/_canonical.jq` so the rules are DRY and unit-testable. Helpers:

- `cluster_id_sorted_names(prefix; names)` — for N-member clusters keyed by sorted names.
- `cluster_id_single_name(prefix; name)` — for single-name clusters.
- `cluster_id_sorted_pair(prefix; a; b)` — for unordered pairs; pass `loc_key($x)` rather than bare names.
- `cluster_id_directed_pair(prefix; sub; sup)` — for directed pairs (subset-pairs); pass `loc_key(.left)` and `loc_key(.right)`. The `sub`/`sup` parameter names are kept on the helper signature for historical clarity (sub-then-sup direction); the caller passes the row's `left`/`right` fields.
- `cluster_id_sorted_paths(prefix; paths)` — for path-keyed clusters (file-duplicates).
- `loc_key(decl)` — `package:file:line:name` location key for record disambiguation. Also aliased as `fn_location_key` for backwards compatibility.
- `output_format` — `"text"` (default) or `"jsonl"`, read from `$ENV.OUTPUT_FORMAT`.
- `is_published` — true when a row's `origin_package` field is a non-empty string. Filters cross-repo collisions down to the published-only subset. Only `kind: "import"` rows currently carry `origin_package` (per PR #196); on type/function rows the predicate returns false.
- `is_repo_local` — logical complement of `is_published`. True when a row has no `origin_package`, or it's null/empty.
- `stale_threshold_days` — staleness cutoff in days, sourced from `$ENV.CROSS_REPO_STALE_DAYS` (default 7). Tolerant of bad input: empty string, non-numeric values (`"7d"`, `"abc"`), and non-positive values (`"0"`, `"-1"`) all fall back to the default rather than crashing the query or marking every repo as divergent. The same env is read by `refresh-index.mjs` at publish-time when computing each repo's `latest.status`.

Unit tests covering each helper live in `pipeline/queries/_tests/test_canonical.sh`; integration tests covering each query in both modes live in `pipeline/queries/_tests/test_queries_integration.sh`. Both run with no dependencies beyond `jq` and `bash`.

## Cross-repo substrate guardrails (`coverage.jq`, `preflight-versions.jq`, `run-cross-repo-query.sh`)

Cross-repo queries — those that merge catalogs across N repos via the substrate (`docs/substrate.md`) — go through a wrapper that enforces two guardrails before the query runs. The contract: a cross-repo report's consumer can always read its scope and trust its merge-safety without inspecting the wrapper output by eye.

### `pipeline/queries/coverage.jq`

Consumes the substrate's `index.json` directly (single positional argument). Emits a multi-line header in text mode or a structured JSON object in JSONL mode, surfacing:

- `scope: {covered, expected}` — how many repos out of the expected set produced an `ok`-status catalog. When `CROSS_REPO_CATALOG_KIND` is set in the env (the wrapper sets it from its `--catalog-kind` flag), `covered` counts only repos whose `latest.catalogs[]` actually publishes that kind — so a header reading `2/3` accurately reflects how many repos contributed to the merge, not "how many are ok status overall."
- `catalog_kind` — the value of the kind filter (`null` if unfiltered).
- `covered[]` — per-repo metadata for the merge set: `{repo, commit_sha, short_sha, published_at, age_hours, age_days}`.
- `irrelevant[]` — `ok`-status repos that didn't publish `CROSS_REPO_CATALOG_KIND` (so they don't contribute to the merge). Lists each repo and the kinds it does publish. Always empty when no kind filter is set.
- `missing[]` — repos in `index.json` whose status is `missing` (in `--known-repos` but absent from the bucket).
- `stale[]` — repos in `index.json` whose status is `stale` (catalog older than `CROSS_REPO_STALE_DAYS`).
- `divergent_stale[]` — `ok`-status repos whose freshly-recomputed age vs. the *query-time* threshold value would mark them stale. Surfaces drift between the publish-time and query-time reads of the env var.
- `errored[]` — currently always empty; reserved for when extractors emit a top-level error count on their catalogs (open in the brief; not yet implemented).
- `threshold_days`, `comparison_at`, `median_age_hours`, `max_age_hours` — context for the age summary.

Exit is always 0; coverage is informational, not a gate. Defensive against publisher quirks: `parse_iso` returns `null` (instead of crashing) on non-string timestamps, fractional seconds, or non-UTC offsets; `.repos` defaults to `[]` when absent; `.latest` is treated as null when it's a non-object placeholder string.

### `pipeline/queries/preflight-versions.jq`

Also consumes `index.json` (single positional argument). Groups every `ok`-status catalog's `extractor` block by `(language, name)`. Within each group:

- If majors differ across repos: refuse (exit 1).
- If minors differ but majors match: pass with a `WARNING: minor version skew` line.
- If any catalog has a missing or unparseable `extractor.version`: refuse (exit 1).

The refusal model is "fail closed on data unsafety" — version skew within a single extractor type would produce silently wrong cross-repo joins (different `shape_sig` normalization rules, different field names). Multi-language merges are fine; only same-extractor skew refuses. When `CROSS_REPO_CATALOG_KIND` is set, preflight only scopes catalogs of that kind, so a function-catalog skew doesn't block a type-catalog query.

JSONL mode emits `{status: "ok"|"minor-skew"|"refused", reason, extractors[], refusal_details}`. Text mode emits a per-extractor versions table followed by a `STATUS: <verdict>` line. The jq query terminates with `halt_error(1)` on refusal so callers can rely on the exit code.

### `pipeline/run-cross-repo-query.sh`

The wrapper that runs `fetch-catalogs.sh` → `preflight-versions.jq` → `coverage.jq` → the user's query. Coverage's stdout is prepended to the query's stdout as `#~ `-prefixed lines (unique enough that a user query emitting `#FFFFFF`, `# of refs: 5`, or any other `#`-leading content survives the documented strip recipe `grep -v '^#~ '`). The legacy `grep -v '^#'` also works for consumers that don't emit `#`-leading content themselves. When `OUTPUT_FORMAT=jsonl` is set, coverage emits a single-line JSON object, so the prepended header becomes one `#~ {...}` line that a JSONL consumer can strip cleanly.

Preflight's exit code propagates as the wrapper's exit code: `halt_error(1)` from the query → wrapper exit 1 (refused). Other non-zero exits from preflight (jq syntax error, malformed input, OOM) → wrapper exit 3 (crash), distinct from refusal so the operator doesn't misread one for the other. The user's query never runs on either refusal or crash.

Every entry in the merged catalog is augmented with `origin_repo: "<owner>/<name>"`. Cross-repo collision queries can use this to tell "same symbol in 2 repos" apart from "two intra-repo duplicates" — without the annotation, the rows would be byte-identical after merge and `unique` would collapse them. Single-repo queries that don't read `origin_repo` are unaffected.

```bash
# Standard cross-repo invocation
AUDIT_BUCKET_URL=https://catalogs.wxyc.org \
  pipeline/run-cross-repo-query.sh pipeline/queries/<your-query>.jq

# Override catalog kind (default: type-catalog). Threads through to both
# preflight (so unrelated extractor skew doesn't refuse) and coverage
# (so scope reflects repos that actually publish the kind).
pipeline/run-cross-repo-query.sh --catalog-kind function-catalog \
  pipeline/queries/<func-query>.jq

# Subset of repos. Strips the substrate's `.coverage` block from the
# filtered view so the header reads e.g. `1/1` instead of `1/3`.
# Unknown repo names abort with a stderr diagnostic — typos are not
# silently dropped.
pipeline/run-cross-repo-query.sh --repos wxyc/dj-site,wxyc/shared \
  <query>.jq

# JSONL caller — coverage line becomes `#~ {...}`, strippable with grep:
OUTPUT_FORMAT=jsonl pipeline/run-cross-repo-query.sh <query>.jq \
  | grep -v '^#~ ' | jq -c .
```

The wrapper is the standard cross-repo entry point. Direct invocation of `jq ... | jq ... | jq ...` against the cache is supported for one-off debugging but bypasses the safety net — F1/F2/F3 cross-repo queries should always be wrapped.
