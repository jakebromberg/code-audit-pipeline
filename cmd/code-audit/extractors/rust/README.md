# Rust extractor

`syn`-based Rust AST extractor for the code-audit pipeline. Walks `.rs` source files under `--root` (and optionally `--shared`) and emits `type-catalog.json` matching the JSON shape in [`docs/pipeline-contract.md`](../../docs/pipeline-contract.md).

A standalone Cargo binary (`rust-catalog`) — **not** a member of any workspace, so an audited repo's own `Cargo.toml` never sees it. Like the Swift extractor it is compiled: the `code-audit` binary runs `[runtime].bootstrap` (`cargo build --release`) once per laid-down source tree, then `cargo run --release` finds the binary up to date. Requires a Rust toolchain (cargo) 1.93+.

## Usage

```bash
# Build once
cargo build --release

# Type catalog
cargo run --release -- type --root /path/to/repo --output type-catalog.json

# Cross-package shadow detection (main vs shared)
cargo run --release -- type --root /path/to/crate --shared /path/to/shared --output type-catalog.json

# Via the code-audit binary (auto-bootstraps on first run)
code-audit extract rust --root /path/to/repo
```

The extractor:
- Skips dotdirs (`.git`, `.cargo`, `.claude`, etc.) and `node_modules`, `dist`, `build`, `coverage`, and `target` (Rust build output — not a dotdir, so it is named explicitly).
- Tags every record with `is_test: bool` from path patterns (universal `tests/`, `spec/`, `__fixtures__/`, `e2e/` dir segments; `*.test.rs` / `*.spec.rs` / `*.fixture(s).rs` / `*.mock(s).rs` filenames) **plus** AST-based detection of declarations inside a `#[cfg(test)]` module.
- Tags `generated: true` for files under a `generated/` path segment.
- Emits byte-deterministic output (`entries[]` sorted by `package, file, line, name`); only the `generated_at` timestamp varies between runs.

## Kind mapping

How Rust source constructs map to the catalog `kind` field:

| Rust construct | Catalog `kind` | `fields` encoding |
|---|---|---|
| `struct S { f: T, … }` | `type-alias-object` | one `name:type` per named field |
| `struct S(T, U);` (tuple) | `type-alias-object` | positional `0:T`, `1:U` |
| `struct S;` (unit) | `type-alias-object` | `[]` |
| `union U { … }` | `type-alias-object` | like a named struct |
| `enum E { A, B(T), C { x: T } }` | `type-alias-union` | one entry per variant: `A:""`, `B:"(T)"`, `C:"{ x: T }"`, discriminant `D = 1` → `D:"=1"` |
| `trait T: Q { … }` | `interface` | `fields: null` — a trait's method set is not a struct shape |
| `type X<T> = Y;` | `type-alias-other` | `fields: null`; emits `type_text` + `type_sig` |
| `macro_rules!` | *(skipped in v1)* | — |

`is_optional` in `fields_structured` is set for `Option<…>` fields. `fields_structured` is omitted for non-shape kinds (traits, type aliases).

## Heritage: `conforms_to` and `extends`

Rust has no struct/enum inheritance, so **`extends` is always `[]`**. Conformance (the high-signal "already-abstracted" axis) is populated in `conforms_to` from three sources, deduped and sorted:

1. **`impl Trait for Type`** blocks — `Trait` added to `Type`'s `conforms_to`. Collected across every file in a package, then merged by type name (a second pass).
2. **Supertraits** — `trait T: Q + R` contributes `[Q, R]` (conformance-only; Rust forbids trait→concrete inheritance, mirroring the Swift `ProtocolDeclSyntax` rule).
3. **`#[derive(…)]`** — derived trait names, minus the `STD_DERIVE_DENYLIST`.

Trait/type names use the **last** path segment (`std::fmt::Display` → `Display`). This is the right choice for Rust, where qualified paths (`crate::module::Type`) are the norm — and it intentionally diverges from the TypeScript leftmost-segment convention.

## Denylists

- **`is_builtin_type`** — primitives (`u8…u128`, `i8…i128`, `f32/f64`, `bool`, `char`, `str`, `String`) and ubiquitous std containers/pointers (`Vec`, `Option`, `Result`, `Box`, `Rc`, `Arc`, `HashMap`, `PathBuf`, …) are filtered out of every `references[]` array so they don't dominate the graph. The Rust analog of the TS `BUILTIN_TYPE_DENYLIST`.
- **`is_std_derive`** — ubiquitous marker/derive traits (`Debug`, `Clone`, `Copy`, `Default`, `PartialEq`, `Eq`, `PartialOrd`, `Ord`, `Hash`, `Send`, `Sync`, `Sized`) are filtered out of `conforms_to` so they don't flood the abstraction axis. The Rust analog of Swift's `PROTOCOL_LIKE_INHERITED`. Meaningful derives (`Serialize`, domain traits) survive.

Both live as single functions in `src/util.rs` — extend them there.

## References

`references[]` collects the last identifier of each type path appearing in field types, enum-variant payloads, the aliased type of a `type` alias, and trait method signatures — minus in-scope generic parameters and the builtin denylist. Self-references are kept (per contract).

## Tests

```bash
cargo test
```

Unit tests cover the pure helpers (`shape_sig`, denylists, path classification, ISO-8601). The integration test (`tests/integration.rs`) runs the built binary against the `tests/fixtures/` `.rs` files and asserts the emitted catalog, including determinism (two runs produce identical `entries`).

## Known limitations (v0.1.0)

- **Type-catalog only.** `function-catalog` (body-hash clustering for duplicate function bodies) is a planned follow-up, mirroring the Swift `func` command.
- **`macro_rules!` skipped.** Macro-generated types are invisible until macro expansion is wired in. Rare in practice; documented rather than silently dropped.
- **Name-based `conforms_to` join.** `impl Trait for Type` edges are attached by the type's bare name within a package, with no path resolution — two distinct types sharing a name in one package would both receive the edge. Rare; matches the contract's name-based join philosophy.
- **Bare (unqualified) declaration names.** Items nested in modules are emitted under their bare identifier (not module-qualified), so two same-named types in one file share a `symbol_id`. The dominant top-level case is unaffected.
- **No fn-body items.** Structs/enums declared inside a function body are not extracted (only module-level items and items inside inline `mod` blocks). Cross-cutting analysis rarely needs locals.
- **Lifetimes dropped from `generics`.** `generics` lists type and const parameters only.
