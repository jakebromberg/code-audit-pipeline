# Pipeline contract

Every extractor in `extractors/<language>/` emits the same JSON shape so cluster queries don't care which language they're operating on. This is the schema.

The substrate has four catalog kinds today, each in its own JSON file:

- `type-catalog.json` — type / interface / Zod / Drizzle declarations (shape-of-named-members).
- `function-catalog.json` — function / method / arrow-function declarations (body-of-named-callable).
- `file-hashes.json` — file-level content hashes (raw and whitespace-normalized).
- `package-graph.json` — inter-package dependency edges (V7 §6.5; see [Package graph](#package-graph-package-graphjson) below).

Each section below specifies one. Queries in `pipeline/queries/` consume one specific catalog kind and document which.

## Type catalog (`type-catalog.json`)

The type catalog is a single JSON array. Each entry describes one declared type-like construct.

```jsonc
[
  {
    "name": "FlowsheetEntry",            // identifier as declared
    "kind": "interface",                  // see "Kinds" below
    "package": "main",                    // which root this came from
    "file": "src/models/flowsheet.ts",   // path relative to that root
    "line": 42,                           // 1-indexed
    "exported": true,                     // true if exported from the file
    "generated": false,                   // true if .d.ts or under generated/

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
    "conforms_to": ["Codable", "Sendable"], // V7 §6.2: inheritance-clause names; [] for record types with no conformances; omitted on typealiases
    "resolved_from": "protocol-inheritance", // V7 §6.3 (interface kind only): set when parent fields were unioned in
    "inherited_from": ["ParentProtocol"],    // V7 §6.3: list of in-catalog protocol parents that contributed fields
    "shape_sig": "album_title:string | null|artist_name:string | null|id:number",  // fields.join("|").lower

    "touched_in_window": false,           // true if file is in --touched JSON list

    // Optional, kind-dependent:
    "generics": "T,U",                    // type-parameter names if generic
    "type_text": "Pick<X, 'a' | 'b'>",   // for non-object type aliases
    "type_sig": "pick<x, 'a' | 'b'>",    // normalized type_text for clustering
    "infer_ref": { "kind": "InferSelectModel", "table": "user" }, // ORM-derived types
    "db_table_name": "user_accounts"      // for ORM table declarations
  }
]
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

### V7 §6.2: `conforms_to`

Name-keyed list of every entry in the record's inheritance clause. For `struct Foo: Bar, Baz`, this is `["Bar", "Baz"]`. For `protocol B: A`, `["A"]`. For `enum Status: String, Codable`, `["String", "Codable"]` (the raw-value type takes the first position syntactically, indistinguishable from a leading protocol — see caveat below).

| Record kind | `conforms_to` shape |
|---|---|
| `interface` (Swift `protocol`) | `[]` if no parents; otherwise the inherited protocol names |
| `type-alias-object` (`struct` / `class` / `actor`) | `[]` if no inheritance clause; otherwise every inherited-types entry |
| `type-alias-union` (Swift `enum`) | `[]` if no inheritance clause; otherwise every inherited-types entry (raw-value type + protocols) |
| `extension` | `[]` unless the extension declares conformance; otherwise the new conformances added by the extension |
| `type-alias-other` (Swift `typealias`) | omitted from JSON (typealiases have no inheritance clause) |

**Class-vs-protocol caveat.** SwiftSyntax doesn't distinguish "class name" from "protocol name" at the syntax layer. For Swift `class Foo: Bar, Baz`, the first entry of `conforms_to` may be a parent class or a protocol — the substrate can't tell from syntax alone. Downstream consumers that need the class-inheritance edge specifically should treat the first entry of a class's `conforms_to[]` as ambiguous. The dedicated class-inheritance edge enrichment is V7 §6.3 round 2 scope.

**Same caveat applies to raw-value enums.** `enum Status: String, Codable` puts the raw-value type (`String`) in the first position; downstream consumers treating `conforms_to[0]` as a protocol will misclassify.

**Names are kept verbatim.** Qualified protocol names like `Combine.Cancellable` stay qualified. Composed protocols (rare in inheritance clauses but legal) stay as written. The downstream consumer decides what to do with non-bare names.

**Consumed by:** `pipeline/queries/default-impl-candidates.jq` joins a function-body cluster's distinct types against `conforms_to[]` and filters to clusters whose member types share at least one protocol (the substrate signal for "all conformers can default-impl this method via a common protocol extension"). The query loads the type catalog via `--slurpfile types` alongside the function catalog input — see the query's header comment. The join is name-keyed: same-name records (a struct and its extensions, for example) are grouped and their `conforms_to[]` lists are unioned, so the effective conformance set picks up conformances declared on extensions. Free functions, which have no enclosing type and thus no type-catalog record, are dropped from the cluster set by this filter (their effective `conforms_to[]` is `[]`).

### V7 §6.3: protocol-inheritance resolution

A second pass over the type catalog unions parent protocol's `fields[]` / `fields_structured[]` into child protocol records, so downstream shape queries see the *full* declared-plus-inherited surface rather than just the declared half. Mirrors V5's intersection-type resolution: fixed-point loop, up to 5 iterations to handle transitive chains (`protocol C: B`, `protocol B: A` — C ends up with A's fields after two iterations), bounded recursion as a safety net against cyclic graphs.

The pass writes two fields on resolved records:

- `resolved_from: "protocol-inheritance"` — marker. Same field as V5's intersection-type marker; the two markers share the field's namespace but never appear on the same record because their kinds are disjoint (intersections are `type-alias-intersection`, protocols are `interface`).
- `inherited_from: ["ParentA", "ParentB", ...]` — transitive list of in-catalog protocol parents whose declarations contributed at least one new field. Verbatim names (matches `conforms_to`'s convention). A parent whose declared fields are entirely shadowed by the child's same-named declarations does NOT appear here — consult `conforms_to[]` for the unfiltered direct-parent list. Ordering interleaves direct parents with their transitive ancestors in iteration order, so position is not load-bearing; consumers that need to distinguish direct from transitive should cross-reference `conforms_to[]`.

Protocol-only scope. The pass skips a `conforms_to[]` name when the named record isn't `kind == "interface"`, which handles the §6.2 class-vs-protocol caveat conservatively: a class with a parent class in `conforms_to[0]` doesn't get class fields unioned in (the class-inheritance resolution is round-2 scope).

External SDK protocols like `Codable` or `Sendable` that aren't in the scanned roots stay unresolved — they appear in `conforms_to` but don't contribute to `inherited_from`. The child protocol's `fields[]` reflects only what was unioned from in-catalog parents, plus its own declarations.

Field collisions resolve in favor of the child: if `protocol B: A` and both A and B declare a field named `name: String`, the child's declaration wins (the parent's same-name entry doesn't override).

After resolution, `fields[i]` and `fields_structured[i]` remain in lockstep (sorted by the flat `"name:type"` string) and `shape_sig` is recomputed from the unioned field set.

**Consumed by:** `pipeline/queries/protocol-inheritance-candidates.jq` and `pipeline/queries/subset-pairs.jq`. Both queries become more sensitive to inheritance relationships after the resolution pass — a child protocol with N declared members and M inherited members can now overlap with sibling protocols on member sets that previously appeared only on the parent. The methodology's Cat 2 plants (missing-parent protocol pattern) rely on this richer surface.

## Kinds

| Kind | Source construct (TypeScript) | Source construct (other languages) |
|---|---|---|
| `interface` | `interface X { … }` | Python: `Protocol`; Go: `type X interface { … }` |
| `type-alias-object` | `type X = { … }` | Python: `TypedDict`; Go: `type X struct { … }` |
| `type-alias-union` | `type X = A \| B \| C` | Python: `Union[…]`; Rust: enum variants |
| `type-alias-intersection` | `type X = A & B` | (rare elsewhere) |
| `type-alias-infer-model` | `type X = InferSelectModel<typeof T>` | SQLAlchemy: `Mapped[…]`; Django: model classes |
| `type-alias-other` | other utility types | mapped/conditional types |
| `zod-object` | `const X = z.object({ … })` | Python: Pydantic `BaseModel`; Go: validator tags |
| `drizzle-table` | `pgTable("…", { … })` or `wxyc_schema.table(…)` | Python: SQLAlchemy `Table(…)`; Go: GORM struct |

Languages without an exact analog can extend with their own kind values — keep prefix conventions (`type-alias-*`, etc.) so queries can pattern-match.

## Required fields

- `name`, `kind`, `package`, `file`, `line`

## Required-when-applicable

- `fields` + `shape_sig` for any "shape-of-named-members" construct (interface, struct, type literal, Pydantic model, etc.). Without these the cluster queries can't compare it.
- `type_text` + `type_sig` for non-object type aliases. Without these the InferModel-style derived-type clustering won't work.

## Optional but useful

- `exported`, `generated`, `touched_in_window`, `generics`, `infer_ref`, `db_table_name`, `fields_structured` (V7 §6.1), `conforms_to` (V7 §6.2), `resolved_from` + `inherited_from` (V7 §6.3 — set on resolved protocols)

### Intersection-type resolution

`type X = A & B & { c: number }` entries (kind `type-alias-intersection`) emit `fields` populated by unioning their operands' field sets, when all operands resolve. A second pass walks the catalog up to 5 iterations to handle transitive cases (`Y = X & C`). Resolved entries carry:

- `resolved_from: "intersection"` — marker so downstream queries can include or exclude these synthetically-resolved shapes.
- `operands: ["A", "B", "<literal>"]` — names of the type references and `"<literal>"` placeholders for inline literals. Diagnostic trace.

If at least one operand can't be resolved (utility types like `Pick<X, 'a'>`, conditional types, or references whose declaration was outside the scanned roots), the entry stays at `fields: null` and gains:

- `unresolved: true`
- `unresolved_operands: ["Pick<X, 'a'>", …]` — the operands that defeated resolution.

This is additive: intersection types that resolve get treated like normal shape-bearing constructs by `subset-pairs.jq`, `near-duplicates.jq`, `exact-duplicates.jq`, etc. Intersection entries that fail to resolve stay invisible to those queries, as before.

**Order-dependent conflict resolution.** When two operands declare the same field name with different types (`type X = { a: string } & { a: number }`), the extractor keeps the FIRST occurrence in declaration order. TypeScript's true semantics would intersect (`string & number = never`); the substrate flattens to the first binding so `shape_sig` stays deterministic. This is a clustering tool, not a type-checker — if you need conflict detection, compare operand field-type pairs separately, or wait for the dedicated check that will accompany #5 (substrate-emitted cluster_ids).

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

- `node_modules/`, `dist/`, `build/`, `coverage/`, `tests/`
- **Any directory beginning with `.`** — `.git/`, `.next/`, `.claude/`, `.cursor/`, `.idea/`, `.vscode/`. These typically hold IDE/agent state or git worktree clones; descending into them inflates the catalog with near-duplicate copies of the same repo.
- Files matching `*.test.*`, `*.spec.*`

Use `--include-tests` to keep test directories in scope when auditing test-fixture duplication.

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
    ],
    "body_hash_erased": "<sha256 of normalized body after type-id erasure>",  // V7 §6.4
    "body_lines_erased": [                       // V7 §6.4: same shape as body_lines, but on the erased body
      "let copy: _T1 = value",
      "let pair: [_T1] = [copy, value]",
      "return pair"
    ]
  }
]
```

**Method-name qualification.** For class methods, `name` is `ClassName.methodName`. For methods on anonymous classes, just the method name.

**Body normalization.** Comments (line `//` and block `/* */`) are stripped, internal whitespace runs collapsed to single spaces, each line trimmed, blank lines dropped. `body_hash` is sha256 of `body_lines.join('\n')`. `body_lines` is also de-duplicated and sorted, so it can serve as the input set for Jaccard pairwise comparison without further work.

**Type-identifier erasure (V7 §6.4).** `body_hash_erased` and `body_lines_erased` are the same normalization applied to a version of the body where every type-position identifier has been replaced with `_T1`, `_T2`, ... in order of first appearance in the body. Two function bodies that differ only at type-identifier slots produce identical `body_hash_erased` while their `body_hash` values stay distinct — a generic-parameterization-candidate signal that survives type substitutions. Scope: Swift extractor rewrites `IdentifierTypeSyntax` nodes only (so qualified types like `Foo.Bar` erase only the head, becoming `_T1.Bar`; expression-position references like `UIColor.red` are not erased). TypeScript extractor rewrites the leftmost identifier of each `TypeReferenceNode.typeName` with the same head-only convention for qualified names.

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

**Skip rules.** Same dir skip-list as the type extractor (`.dotdirs`, `node_modules`, `dist`, `build`, `coverage`, `tests` unless `--include-tests`). Extension filter is configurable via `--extensions` (default `ts,tsx,mts,cts`).

Used by `pipeline/queries/file-duplicates.jq`, which emits two sections: exact-byte clusters and whitespace-normalized-only clusters (files identical after normalization but not byte-equal).

## Package graph (`package-graph.json`)

V7 §6.5 enrichment. Cross-package dependency edges so an agent can name the *correct* extraction target package (one already upstream of both consumers) rather than recommending an arbitrary "common" package. The graph is a single JSON object, not an array, because two parallel collections (nodes and edges) are the natural representation and re-deriving one from the other on every query would be wasteful.

```jsonc
{
  "schema_version": "1",
  "nodes": [
    { "name": "Shared/Core",      "kind": "package",  "path": "Shared/Core/Package.swift" },
    { "name": "Shared/Caching",   "kind": "package",  "path": "Shared/Caching/Package.swift" },
    { "name": "iOS",              "kind": "app",      "path": "WXYC.xcodeproj/project.pbxproj" },
    { "name": "swift-syntax",     "kind": "external", "path": "https://github.com/swiftlang/swift-syntax.git" }
  ],
  "edges": [
    { "from": "Shared/Caching", "to": "Shared/Core",       "source": "Package.swift" },
    { "from": "iOS",            "to": "Shared/Core",       "source": "pbxproj" },
    { "from": "iOS",            "to": "Shared/Networking", "source": "pbxproj" },
    { "from": "Shared/Core",    "to": "swift-syntax",      "source": "Package.swift" }
  ]
}
```

### Nodes

Every node has `name`, `kind`, `path`. Names are stable identifiers used as both endpoints in `edges` and as join keys against the `package` field on type-catalog / function-catalog records (when the same convention applies — see "Package-name conventions" below).

| `kind` | Source | When emitted |
|---|---|---|
| `package` | A `Package.swift` SwiftPM manifest (Swift) or `package.json` (TypeScript, forward-looking). | One per manifest discovered under `--root`. |
| `app` | A target inside `*.xcodeproj/project.pbxproj`. | One per `PBXNativeTarget` whose `productType` includes `application` / `app-extension` / `watchapp`, or which has a non-empty `packageProductDependencies` list. |
| `external` | Out-of-tree dependency. Two sources: `.package(url: "...")` deps declared in any `Package.swift`, or pbxproj `XCSwiftPackageProductDependency` references whose product name doesn't match any in-tree `package` node. | One per unique external name (V7 §6.5 follow-up #54). |

**Why external nodes exist.** The graph is *closed under references* — every `edge.from` and `edge.to` resolves to a node. Before this enrichment landed, a pbxproj reference to (e.g.) `Sentry` would emit an edge with no corresponding node; downstream consumers querying the graph for "is X upstream of Y?" would silently get a false negative because X had no node to traverse to. The `external` kind makes the gap explicit: the agent can see "this dependency exists but isn't in-tree" rather than missing it entirely.

**External node naming.** For `.package(url: "...")` deps, the name follows SwiftPM's default rule: the URL's last path component minus `.git`. So `https://github.com/swiftlang/swift-syntax.git` → `swift-syntax`. A manifest's `.package(url:, name:)` form overrides the default. For dangling pbxproj references, the name is the raw `productName` from the pbxproj — the extractor has no other identifier to disambiguate.

**External node path.** For URL-derived externals, `path` is the declared URL (preserving the `.git` suffix if present). For pbxproj-only externals (no `.package(url:)` declaration found anywhere), `path` is the empty string — the extractor can't recover a URL from a bare product reference.

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

Git submodules (e.g., `Shared/Wallpaper` in wxyc-ios-64) have empty working directories until `git submodule update --init --recursive` runs. The extractor warns about uninitialized submodules via two complementary checks:

1. **`.gitmodules`-driven** (V7 §6.5 follow-up #54 S1). At startup, the extractor reads `<root>/.gitmodules` if present, parses each declared submodule's `path = X`, and warns about any path whose directory doesn't exist OR exists but is empty without a `Package.swift`. This catches the most common "fresh clone without `git submodule update`" workflow — the submodule directory may not even exist yet.
2. **In-package heuristic**. During the manifest walk, the extractor warns when it finds a `Package.swift` sitting next to a submodule-pointer `.git` *file* (not directory) with no other content. This catches the less-common "submodule was initialized but is now bare" state.

In both cases the warning goes to stderr; the JSON is still emitted so downstream consumers see what's there. Only the missing submodule's edges (which the extractor never saw) are absent.

### Cycle detection

V7 §6.5 follow-up #54 S2. After all nodes and edges are assembled, the extractor runs Kahn's algorithm to detect cycles. Any node still carrying a non-zero in-degree after peeling all zero-in-degree nodes is part of at least one cycle. The extractor emits a stderr warning naming the cycle members, comma-joined and sorted. Swift's compiler rejects cyclic module dependencies, so in well-formed real code the warning shouldn't fire — but synthetic fixtures or hand-edited manifests can introduce cycles, and a silent infinite-loop in a downstream consumer is the failure mode the check defends against.

The JSON is emitted regardless; the warning is informational.

### Schema-version contract

`schema_version: "1"` marks the schema this document describes. Increment on any breaking change to node/edge shape; consumers should refuse to operate on unrecognized versions.

### Invocation

```
swift-catalog package-graph --root <path> [--output <path>]
```

Walks `<root>` recursively for `Package.swift` files (skipping `.git`, `.build`, `.swiftpm`, `node_modules`, `build`, `dist`, `coverage`, `DerivedData`, `Pods`) and for any `*.xcodeproj/project.pbxproj`. Emits the JSON object above to stdout (or `--output <path>`). Summary stats (manifest count, pbxproj count, node/edge totals, parse errors, warnings) go to stderr.

Exit code: `0` if at least one `Package.swift` or `project.pbxproj` was discovered; `1` if neither was found.

## CLI contract

Every extractor:

```
extractor --root <path> [--shared <path>] [--touched <json-file>] [--output <path>] [--include-tests]
```

Defaults: `--output` writes to stdout. Summary stats (file counts, kind histogram, error count) go to stderr.

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
