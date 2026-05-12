# Swift extractor (`swift-catalog`)

SwiftSyntax-based extractor that emits substrate JSON conforming to [`../../docs/pipeline-contract.md`](../../docs/pipeline-contract.md). Mirrors the TypeScript extractors at [`../typescript`](../typescript) for shape compatibility — the same cluster queries in `pipeline/queries/` consume either output.

One executable, two subcommands:

```bash
swift build
./.build/debug/swift-catalog type --root <path> [--shared <path>] [--output <path>] [--include-tests]
./.build/debug/swift-catalog func --root <path> [--shared <path>] [--output <path>] [--include-tests] [--min-body-lines N]
```

`swift build` runs once; the binary lands at `.build/debug/swift-catalog` (or `.build/release/swift-catalog` after `swift build -c release`).

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

### `func` — function-catalog

Emits one record per function-like construct that has a body: top-level `func`, methods, initializers, deinitializers, subscripts, computed-property getters/setters. Skipped: protocol-requirement signatures (no body), functions whose normalized body has fewer than `--min-body-lines` (default 3) lines.

Method names are qualified by the nesting stack: a method `foo` on `class Bar` emits `name:"Bar.foo"`. Init names include parameter labels: `"Bar.init(name:age:)"`. Computed-property accessors emit as `"Bar.propName.get"` and `"Bar.propName.set"`.

Body normalization strips `/* */` and `//` comments, collapses whitespace, drops blank lines. `body_hash` is sha256 of the sorted-unique lines joined with `\n`. `body_lines` is the same sorted-unique set, so it can serve directly as Jaccard input.

## Package field

Derived from the file's path relative to `--root` (or `--shared`):

| Path pattern | Resolved `package` |
|---|---|
| `Shared/<X>/...` | `<X>` (e.g., `Shared/Core/...` → `Core`) |
| `WXYC/<Target>/...` | `app:<Target>` (e.g., `app:iOS`, `app:WatchXYC`) |
| `Sources/<X>/...` | `<X>` (matches SwiftPM layout when `--root` is inside a package) |
| anything else | first path segment |

This intentionally encodes wxyc-ios-64's layout. For other projects, generalize via the path heuristics or accept the first-segment fallback.

## Skip rules

The walker skips:

- Hidden directories (anything beginning with `.`) — covers `.build/`, `.swiftpm/`, `.git/`, IDE state.
- `node_modules/`, `build/`, `dist/`, `coverage/`, `DerivedData/`, `Pods/`, `scripts/`, `ci_scripts/`.
- `Tests/` directories (unless `--include-tests`).
- Files matching `*Tests.swift` (Swift convention; unless `--include-tests`).

## Known limitations

- **Macro expansion is invisible.** SwiftSyntax parses source pre-expansion, so members synthesized by `@Observable`, `@Codable`, or custom macros (`AnalyticsMacros`) are not in the catalog. The substrate sees what's in the source file, not what the compiler sees post-expansion.
- **`#if` directives are flattened.** All branches are parsed; conditionally-platform-specific declarations all appear in the catalog. The substrate is over-inclusive on platform-conditional code.
- **Extensions cannot add stored properties in Swift** (a language rule), so extension `fields` are computed-property + static-stored only. Real shape duplication via extensions is rarer than via base types — most extension records carry no `fields`, which makes them invisible to `subset-pairs.jq` etc. by design.
- **No first-class closure handling.** Named-binding closures (`let x: () -> Void = { ... }`) are not emitted as function records. Most have trivial bodies anyway; if substrate recall is low for closure-heavy code, add a `ClosureExprSyntax` visitor.
