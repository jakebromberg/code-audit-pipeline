# Pipeline contract

Every extractor in `extractors/<language>/` emits the same JSON shape so cluster queries don't care which language they're operating on. This is the schema.

The substrate has four catalog kinds today, each in its own JSON file:

- `type-catalog.json` — type / interface / Zod / Drizzle declarations (shape-of-named-members).
- `function-catalog.json` — function / method / arrow-function declarations (body-of-named-callable).
- `file-hashes.json` — file-level content hashes (raw and whitespace-normalized).
- `package-graph.json` — inter-package dependency edges (V7 §6.5; see [Package graph](#package-graph-package-graphjson) below).

Each section below specifies one. Queries in `pipeline/queries/` consume one specific catalog kind and document which.

## Type catalog (`type-catalog.json`)

The type catalog is a top-level **wrapper object** carrying the schema version, an `extractor` provenance block, and the entry array. (Pre-v1.1 catalogs were a bare array; see [Schema versioning and back-compat](#schema-versioning-and-back-compat) below.)

```jsonc
{
  "schema_version": "1.1",
  "extractor": {
    "language": "typescript",
    "name": "type-catalog",
    "version": "0.4.0"                   // extractor package version
  },
  "entries": [
    {
      "name": "FlowsheetEntry",            // identifier as declared
      "kind": "interface",                  // see "Kinds" below
      "package": "main",                    // which root this came from
      "file": "src/models/flowsheet.ts",   // path relative to that root
      "line": 42,                           // 1-indexed
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

      "extends": ["BaseEntry"],             // direct supertype names, sorted alpha
      "references": [                       // names referenced in body, sorted by name
        { "name": "FlowsheetMetadata", "kind": "type-ref" }
      ],
      "references_count": 1,                // == references | length

      // Optional, kind-dependent:
      "generics": "T,U",                    // type-parameter names if generic
      "type_text": "Pick<X, 'a' | 'b'>",   // for non-object type aliases
      "type_sig": "pick<x, 'a' | 'b'>",    // normalized type_text for clustering
      "infer_ref": { "kind": "InferSelectModel", "table": "user" }, // ORM-derived types
      "db_table_name": "user_accounts"      // for ORM table declarations
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

`is_optional` is the load-bearing flag — string-matching trailing `?` on `type` is unreliable across the spelling variants (`Int?` vs `Optional<Int>` differ on trailing-`?` but are semantically equal), but the structural flag is consistent. Carrying both `type` (verbatim) and `is_optional` (structural) is intentional redundancy: `type` is ergonomic for display, `is_optional` is reliable for structural matching.

**Enum cases.** Records of `kind: "type-alias-union"` derived from Swift enums emit one `fields_structured` entry per case:

| Case shape | `type` value |
|---|---|
| `case foo` (no associated value, no raw value) | `""` (empty string) |
| `case foo(Int, String)` (associated values) | `"(Int, String)"` (the parameter clause verbatim) |
| `case foo = 1` or `case foo = "x"` (raw value) | `"=1"` or `"=\"x\""` (leading `=` then raw-value text) |

Enum cases always emit `is_optional: false` and `is_static: false`.

**Status.** Populated by the Swift extractor (V7 §6.1). TypeScript extractor parity follows the same schema and is tracked separately.

The flat `fields[]` form is preserved unchanged for V6-era queries; new queries (`pat-candidates`, `generic-struct-candidates`, etc.) can consume either form.

#### Example (Swift)

```jsonc
"fields_structured": [
  { "name": "cacheLifespan", "type": "TimeInterval",       "is_optional": false, "is_static": true  },
  { "name": "cacheLoadTask", "type": "Task<Void, Never>?", "is_optional": true,  "is_static": false },
  { "name": "id",            "type": "String",             "is_optional": false, "is_static": false }
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
| `interface` | `interface X { … }` | Python: `Protocol`; Go: `type X interface { … }` |
| `type-alias-object` | `type X = { … }` | Python: `TypedDict`; Go: `type X struct { … }` |
| `type-alias-union` | `type X = A \| B \| C` | Python: `Union[…]`; Rust: enum variants |
| `type-alias-intersection` | `type X = A & B` | (rare elsewhere) |
| `type-alias-infer-model` | `type X = InferSelectModel<typeof T>` or `type X = typeof T.$inferSelect` | SQLAlchemy: `Mapped[…]`; Django: model classes |
| `type-alias-other` | other utility types | mapped/conditional types |
| `zod-object` | `const X = z.object({ … })` | Python: Pydantic `BaseModel`; Go: validator tags |
| `drizzle-table` | `pgTable("…", { … })` or `wxyc_schema.table(…)` | Python: SQLAlchemy `Table(…)`; Go: GORM struct |

Languages without an exact analog can extend with their own kind values — keep prefix conventions (`type-alias-*`, etc.) so queries can pattern-match.

## Required fields

- `name`, `kind`, `package`, `file`, `line`, `is_test`, `extends`, `references`, `references_count`

`extends` and `references` are arrays (possibly empty) on every entry — never `null`. Empty extends/references arrays still serialize so consumers can do `(entries[] | select(.references_count == 0))` without a `// 0` fallback. `references_count` is a derived field: `references | length`. It's emitted explicitly because jq queries that filter on it are noisier with the inline length call.

## Required-when-applicable

- `fields` + `shape_sig` for any "shape-of-named-members" construct (interface, struct, type literal, Pydantic model, etc.). Without these the cluster queries can't compare it.
- `type_text` + `type_sig` for non-object type aliases. Without these the InferModel-style derived-type clustering won't work.

## Optional but useful

- `exported`, `generated`, `touched_in_window`, `generics`, `infer_ref`, `db_table_name`, `fields_structured` (V7 §6.1)
- `reference_count` (grep-style identifier-occurrence count, populated by a second pass — coarse "name appears anywhere in scanned source" signal; distinct from `references_count` which is the structural count of typed references inside this declaration's body)

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

### `extends` and `references` semantics

Both fields are sorted (alphabetically), deduplicated, and never `null` (empty array on declarations with no heritage / no body refs).

**`extends`** is the supertype-edge axis. Populated for:

| Construct | `extends` content |
|---|---|
| `interface X extends A, B {}` | `["A", "B"]` |
| `type X = A & B & { … }` | `["A", "B"]` (intersection-named operands) |
| `type X = A & B` (pure intersection, no literal) | `["A", "B"]` |
| `type X = A` (simple alias to a name) | `["A"]` (resolves through the intersection mechanic when the alias is canonical) |
| `type X = A \| B` (union) | `[]` — union variants are *references*, not `extends`. Treating union variants as inheritance would over-claim. |
| `type X = Pick<Y, "a">` (utility alias) | `[]` — the utility itself isn't a supertype. |
| `zod-object`, `drizzle-table`, `type-alias-other` | `[]` in v1 (best-effort) |

**`references`** is the names-in-body axis. Populated for every declaration with a recognizable type body. Each entry is `{name: string, kind: "type-ref"}`. The `kind` slot is present from v1 so future kinds (`call-ref`, `import-ref`) extend without a schema break.

Type-parameter names declared by the enclosing declaration are excluded from `references` (so `interface Foo<T> { x: T }` produces `references: []`, not `[{name: "T"}]`). Mapped types (`{[K in keyof S]: …}`) and function types (`<T>(x: T) => T`) introduce their own scopes for the same reason — the walker threads a `Set<string>` of in-scope type-parameter names so nested generics shadow correctly.

A curated **deny-list of built-in / utility type names** (`Pick`, `Omit`, `Partial`, `Promise`, `Array`, `Map`, `Date`, etc., plus the Drizzle infer helpers `InferSelectModel` / `InferInsertModel` which are already first-class via `infer_ref`) excludes these from references. Without the filter, `Promise` and `Pick` would dominate every graph as the highest-degree nodes. The complete list lives in `extractors/typescript/type-catalog.mjs` as a single `BUILTIN_TYPE_DENYLIST` constant — adding new entries (e.g., a TS lib upgrade adds `NoInfer`) is a one-line change.

**v1 node coverage** for the references walker (TypeScript extractor):

- Full support: `TypeReferenceNode`, `TypeLiteralNode`, `UnionTypeNode`, `IntersectionTypeNode`, `ArrayTypeNode`, `TupleTypeNode`, `IndexedAccessTypeNode`, `MappedTypeNode`, `TypeQueryNode` (`typeof X` — emits `X`), `ImportTypeNode` (`import("x").Y` — emits `Y` via the qualifier), `ParenthesizedTypeNode`, `FunctionTypeNode`, `ConstructorTypeNode`.
- Deferred (walks children, may produce false positives): `ConditionalTypeNode`, `InferTypeNode`, `TemplateLiteralTypeNode`, `TypeOperatorNode`, `ThisTypeNode`, `LiteralTypeNode`. The walker descends via `ts.forEachChild`, so identifiers buried in these still surface via their `TypeReferenceNode` descendants — the *node form itself* isn't modeled (e.g., `infer R` doesn't produce a special `kind`).
- Best-effort (v1 ships empty references): `zod-object`, `drizzle-table`. Their builder DSLs are not walked. The `type-alias-infer-model` kind walks the inner type argument and surfaces the table identifier as a reference, e.g., `InferSelectModel<typeof users>` → `references: [{name: "users", kind: "type-ref"}]`.

**Self-references** are emitted: `interface Node { children?: Node[] }` produces `references: [{name: "Node", kind: "type-ref"}]`. The graph view consumer wants the self-loop edge; suppressing it would obscure recursive structure.

**Qualified-name extraction**: for `TypeReferenceNode` whose `typeName` is a `QualifiedName` (e.g., `Namespace.Inner.Type`), the **leftmost** identifier is emitted as the reference (`Namespace`). This matches the resolution rule used by the sibling `references.json` artifact's `(package, name)` lookup. Heritage clauses (`interface X extends Lib.Foo`) preserve the full dotted form — the diverging convention is documented and rare in practice.

### Sibling `references.json` artifact

When invoked with `--emit-references-graph <path>`, the extractor writes an inverted edge list to `<path>`:

```jsonc
{
  "schema_version": "1.1",
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

The artifact is the right home for inverted ("what depends on X?") queries:

```jq
.edges | map(select(.to.name == "FlowsheetEntry")) | group_by(.from.package)
```

The inline `references[]` field on each catalog entry is the right home for forward ("what does X depend on?") queries — including the graph-view consumer that needs per-node outgoing edges.

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

## Function catalog (`function-catalog.json`)

The function catalog is a single JSON array. Each entry describes one declared function-like construct (function declaration, class method, arrow function or function expression assigned to a named binding).

```jsonc
[
  {
    "name": "betterAuthSessionToAuthenticationData",
    "kind": "function",                          // function | method | arrow-function | function-expression
    "package": "main",
    "file": "lib/features/authentication/utilities.ts",
    "line": 89,
    "generated": false,
    "exported": true,
    "async": false,
    "param_count": 1,
    "param_names": ["session"],
    "body_line_count": 48,                       // after normalization (comments stripped, blank lines dropped)
    "body_length": 1500,                         // chars of normalized body
    "body_hash": "<sha256 of normalized body>",  // exact-equality clustering
    "body_lines": [                              // sorted-unique normalized non-empty lines
      "const authority = mapRoleToAuthorization(roleToMap);",
      "const token = session.session?.token;",
      "…"
    ]
  }
]
```

**Method-name qualification.** For class methods, `name` is `ClassName.methodName`. For methods on anonymous classes, just the method name.

**Body normalization.** Comments (line `//` and block `/* */`) are stripped, internal whitespace runs collapsed to single spaces, each line trimmed, blank lines dropped. `body_hash` is sha256 of `body_lines.join('\n')`. `body_lines` is also de-duplicated and sorted, so it can serve as the input set for Jaccard pairwise comparison without further work.

**Skip rules.** Functions with `< --min-body-lines` (default 3) normalized lines are not emitted — one-liners and trivial stubs aren't useful duplication signal. Generated files (`*.d.ts`, `generated/`) are marked `generated: true` like the type catalog.

Used by `pipeline/queries/function-duplicates.jq`, which emits two sections: exact body-hash clusters (size ≥ 2) and pairwise Jaccard near-duplicates on `body_lines` above a threshold (default 0.7).

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

Used by `pipeline/queries/file-duplicates.jq`, which emits two sections: exact-byte clusters and whitespace-normalized-only clusters (files identical after normalization but not byte-equal).

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

The catalog top level carries `schema_version: "1.1"`. The current TS extractor always emits the wrapper form (`{schema_version, extractor, entries}`); the bare-array form is a pre-v1.1 artifact.

**Query migration.** Queries consume entries via the `entries` helper in `pipeline/queries/_canonical.jq`, which accepts both forms for one deprecation cycle:

```jq
def entries:
  if type == "array" then .                            # v1.0 bare-array
  elif type == "object" and has("entries") then .entries  # v1.1 wrapper
  else error("expected catalog: top-level must be array (v1.0) or object with .entries (v1.1)")
  end;
```

Each query starts its top-level pipeline with `entries[]` (or `entries as $all`) instead of the bare `.[]`. To migrate a downstream-authored query: replace `.[]` (or `. as $all`) with `entries[]` (or `entries as $all`) at the top-level entry point, and `include "_canonical";` if not already included.

**End of deprecation:** the bare-array branch will be removed in the next breaking schema bump (forward-looking — no concrete schedule). Until then, both forms work uniformly.

The diff machinery (see #117) refuses to compare catalogs with different `schema_version` values — version coercion is intentionally not a transparent operation.

## CLI contract

Every extractor:

```
extractor --root <path> [--shared <path>] [--touched <json-file>] [--output <path>] [--emit-references-graph <path>]
```

Defaults: `--output` writes to stdout. `--emit-references-graph` is off by default. Summary stats (file counts, kind histogram, error count) go to stderr.

Exit code: `0` if at least one file was successfully indexed, `1` if no files could be parsed.

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

Query-specific fields (decls, members, jaccard, intersection, union, etc.) are emitted as the query computes them. Downstream consumers should treat the row as a structured snapshot rather than a fixed schema — Phase B of the V7 experiment runs a normalization pass that flattens these into the agent-prompt input shape; the raw schema captures everything the query knows.

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
| `function-duplicates` (exact section) | `function-duplicates-exact:Loc+Loc+...` | sorted location keys |
| `function-duplicates` (near section) | `function-duplicates-near:Loc+Loc` | sorted location keys |
| `file-duplicates` (exact section) | `file-duplicates-exact:pkg:path+pkg:path+...` | sorted package-qualified repo-relative paths |
| `file-duplicates` (norm section) | `file-duplicates-norm:pkg:path+pkg:path+...` | sorted package-qualified repo-relative paths |

**Why every pair-based query uses location keys instead of bare names:** Swift and TypeScript both allow the same `name` to appear on multiple records — `enum Foo` plus `extension Foo` adding computed properties is two records, both named `Foo`. The substrate emits one record per declaration, so pair-based queries that compare records can produce multiple pairs whose endpoints share names. A name-only id like `near-duplicates-any:PlayerState+PlaybackState` would collide whenever both `PlayerState` (enum + extension) and `PlaybackState` (enum + extension) participate in distinct pairs. Location keys (`package:file:line:name`, the same convention `function-duplicates` already used) make each endpoint unambiguous and the cluster_id unique. Real example surfaced on wxyc-ios-64: `PlayerState`/`PlaybackState` collisions on both `near-duplicates-any` (enum-pair plus extension-pair) and `subset-pairs`.

**Grouped queries (`exact-duplicates`, `name-collisions`, `cross-package-shadows*`) keep bare names** because the row IS the group keyed by name (or shape_sig), with all decls in `members[]` (or `decls[]`). Same-name records collapse into the same row by design, not into separate rows that would collide.

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
- `cluster_id_directed_pair(prefix; sub; sup)` — for directed pairs (subset-pairs); pass `loc_key(.sub)` and `loc_key(.sup)`.
- `cluster_id_sorted_paths(prefix; paths)` — for path-keyed clusters (file-duplicates).
- `loc_key(decl)` — `package:file:line:name` location key for record disambiguation. Also aliased as `fn_location_key` for backwards compatibility.
- `output_format` — `"text"` (default) or `"jsonl"`, read from `$ENV.OUTPUT_FORMAT`.

Unit tests covering each helper live in `pipeline/queries/_tests/test_canonical.sh`; integration tests covering each query in both modes live in `pipeline/queries/_tests/test_queries_integration.sh`. Both run with no dependencies beyond `jq` and `bash`.
