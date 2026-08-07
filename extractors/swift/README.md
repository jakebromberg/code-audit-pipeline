# Swift extractor (`swift-catalog`)

SwiftSyntax-based extractor that emits substrate JSON conforming to [`../../docs/pipeline-contract.md`](../../docs/pipeline-contract.md). Mirrors the TypeScript extractors at [`../typescript`](../typescript) for shape compatibility — the same cluster queries in `pipeline/queries/` consume either output.

One executable, four subcommands:

```bash
swift build
./.build/debug/swift-catalog type --root <path> [--shared <path>] [--output <path>] [--include-tests]
./.build/debug/swift-catalog func --root <path> [--shared <path>] [--output <path>] [--include-tests] [--min-body-lines N]
./.build/debug/swift-catalog literal --root <path> [--shared <path>] [--output <path>] [--include-tests]
./.build/debug/swift-catalog package-graph --root <path> [--output <path>]
```

`swift build` runs once; the binary lands at `.build/debug/swift-catalog` (or `.build/release/swift-catalog` after `swift build -c release`).

`type` and `func` always walk test files and tag every row with `is_test` (per `docs/pipeline-contract.md`'s "Test path patterns"); `--include-tests` is a documented no-op for them. `literal` is the one subcommand `--include-tests` still affects — see its section below.

## Subcommands

### `type` — type-catalog

Emits one record per `struct`, `class`, `protocol`, `enum`, `extension`, `typealias`, `actor`. Output kinds map to `pipeline-contract.md` slots so existing cluster queries work unchanged:

| Swift construct | Kind emitted | `fields` source |
|---|---|---|
| `struct X`, `class X`, `actor X` | `type-alias-object` | stored & computed properties (`name:Type`) |
| `protocol X` | `interface` | property + method signatures |
| `enum X` (with or without associated values) | `type-alias-union` | case names (and associated-type tuples) |
| `extension Foo` | `extension` | properties added by the extension; `extending:"Foo"` |
| `typealias X = Y` | `type-alias-other` | n/a; `type_text:"Y"` + `type_sig` |

Nested types are qualified with `.`: a `struct Inner` inside `struct Outer` emits `name:"Outer.Inner"`. Extensions push their extended-type name onto the qualification stack too, so types nested under extensions are qualified.

Every row carries `is_test: bool`, derived from the file's path (see "Skip rules" below) — required on every row per `docs/pipeline-contract.md`.

### `func` — function-catalog

Emits one record per function-like construct that has a body: top-level `func`, methods, initializers, deinitializers, subscripts, computed-property getters/setters. Skipped: protocol-requirement signatures (no body) — that's it. `--min-body-lines` (default 3) no longer skips rows; functions whose normalized body has fewer lines than the threshold still emit a row, with `body_hash` / `body_lines` / `body_line_count` / `body_length` all `null` instead of being dropped, so signature-level queries (e.g. `public-api-leaks.jq`) still see one-liners and trivial accessors.

Method names are qualified by the nesting stack: a method `foo` on `class Bar` emits `name:"Bar.foo"`. Init names include parameter labels: `"Bar.init(name:age:)"`. Computed-property accessors emit as `"Bar.propName.get"` and `"Bar.propName.set"`.

Body normalization strips `/* */` and `//` comments, collapses whitespace, drops blank lines. `body_hash` is sha256 of the sorted-unique lines joined with `\n`. `body_lines` is the same sorted-unique set, so it can serve directly as Jaccard input.

`enclosing_type` is the dotted nesting-stack qualification of the row's enclosing declaration (`Outer.Inner`), the extended type's text for extension members (`Array<Concert>`), and `null` for free functions — the same join key `type`'s nested-type qualification produces, so function-catalog rows join onto type-catalog rows by `enclosing_type == name`.

Every row carries `is_test: bool`, same derivation and requirement as `type` above.

### `literal` — literal-catalog

Emits one record per literal in the v1 positions: numeric literals in `let`/`var` binding initializers (`static let cornerRadius: CGFloat = 6.0`) and function-call arguments (`RoundedRectangle(cornerRadius: 12)`), plus plain static string literals in binding initializers only (`static let stationCapFlagKey = "on_tour_for_you_station_cap"`). This is an *occurrence* catalog like `file-hashes.json` — rows have no `name`/`kind`; the discriminator is `form` (`"binding"` | `"argument"`), and each form carries its own context fields (`binding_name`/`is_static`/`access` vs `callee`/`arg_label`) plus `enclosing_type`/`enclosing_callable`.

`value` is the literal verbatim (numeric prefix minus folded in; strings keep their surrounding quotes); `value_kind` is `"int"` / `"float"` / `"string"`; `value_norm` is the join key — for numerics the cross-spelling normalization (underscores stripped, hex/octal/binary re-based to decimal, `6.0`/`1e3` collapsed to `6`/`1000`, `0.50` trimmed to `0.5`), for strings the segment content with quotes removed and no case-folding or escape decoding. Positions deliberately *not* emitted: enum raw values (already on the type catalog), `return` statements, tuple elements, attribute arguments, string *arguments* (the widening is binding-only), and interpolated / multiline / raw string literals. Consumed by the copied-literal query lane to surface "a copy that must track another value" drift (the motivating cases: a private `placeholderCornerRadius = 6.0` silently mirroring another type's private `cornerRadius: CGFloat = 6.0`, and a `stationCapFlagKey` string constant hand-copied into a second type).

Schema documented at [`../../docs/pipeline-contract.md`](../../docs/pipeline-contract.md) § "Literal catalog". Tested via [`tests/test_literal_catalog.sh`](tests/test_literal_catalog.sh) against [`tests/fixtures/literal-catalog/`](tests/fixtures/literal-catalog/).

### `package-graph` — inter-package dependency graph (V7 §6.5)

Emits a single JSON object describing package nodes and the dependency edges between them. Two input kinds:

- **`Package.swift`** SwiftPM manifests, parsed via SwiftSyntax. The visitor records `.package(path: "...")` entries (path-based local deps) and per-target `.product(name: ..., package: ...)` references. `.package(url: ...)` calls are currently skipped — V7 §6.5's wxyc-ios-64 use case is path-only inter-package deps.
- **`*.xcodeproj/project.pbxproj`** Xcode project files, parsed via a brace-counting text scan that recognizes nested `<uuid> = { ... }` blocks. App-target `packageProductDependencies` lists are resolved against the file's `XCSwiftPackageProductDependency` map to recover human-readable product names.

Output schema is documented at [`../../docs/pipeline-contract.md#package-graph-package-graphjson`](../../docs/pipeline-contract.md). Submodule pitfall: a `Package.swift` in an uninitialized submodule directory (signaled by a `.git` *file*, not directory, next to a bare manifest) produces a stderr warning but doesn't fail extraction.

Tested against synthetic fixtures under [`tests/fixtures/package-graph/`](tests/fixtures/package-graph/); run [`tests/test_package_graph.sh`](tests/test_package_graph.sh) to validate.

## Package field

Derived from the file's path relative to `--root` (or `--shared`):

| Path pattern | Resolved `package` |
|---|---|
| `Shared/<X>/...` | `<X>` (e.g., `Shared/Core/...` → `Core`) |
| `WXYC/<Target>/...` | `app:<Target>` (e.g., `app:iOS`, `app:WatchXYC`) |
| `Sources/<X>/...` | `<X>` (matches SwiftPM layout when `--root` is inside a package) |
| `Tests/<X>/...` | `<X>` (SwiftPM test-target convention, symmetric with `Sources/<X>/...` — `X` is the raw target directory name, e.g. `FooTests`, not normalized to the production package it doubles) |
| anything else | first path segment |

This intentionally encodes wxyc-ios-64's layout. For other projects, generalize via the path heuristics or accept the first-segment fallback.

## Skip rules

The walker unconditionally skips (there is no test-path exception — `--include-tests` does not affect these):

- Hidden directories (anything beginning with `.`) — covers `.build/`, `.swiftpm/`, `.git/`, IDE state.
- `node_modules/`, `build/`, `dist/`, `coverage/`, `DerivedData/`, `Pods/`, `scripts/`, `ci_scripts/`.

Test-path files (`docs/pipeline-contract.md` § "Test path patterns" — directory segments like `Tests/`, basename suffixes like `*Tests.swift` / `*.mock.swift`) are walked like any other file and tagged `is_test: true`; they are **not** skipped by `type` or `func`. `--include-tests` is a documented no-op for those two subcommands. `literal` is the exception: it filters test-path files out post-walk unless `--include-tests` is passed, plus the legacy basename substrings `.test.` / `.spec.` (see the "literal-catalog" section of `docs/pipeline-contract.md` for why the legacy carve-out exists).

## Known limitations

- **Macro expansion is invisible.** SwiftSyntax parses source pre-expansion, so members synthesized by `@Observable`, `@Codable`, or custom macros (`AnalyticsMacros`) are not in the catalog. The substrate sees what's in the source file, not what the compiler sees post-expansion.
- **`#if` directives are flattened.** All branches are parsed; conditionally-platform-specific declarations all appear in the catalog. The substrate is over-inclusive on platform-conditional code.
- **Extensions cannot add stored properties in Swift** (a language rule), so extension `fields` are computed-property + static-stored only. Real shape duplication via extensions is rarer than via base types — most extension records carry no `fields`, which makes them invisible to `subset-pairs.jq` etc. by design.
- **No first-class closure handling.** Named-binding closures (`let x: () -> Void = { ... }`) are not emitted as function records. Most have trivial bodies anyway; if substrate recall is low for closure-heavy code, add a `ClosureExprSyntax` visitor.
