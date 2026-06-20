# Rust extractor

`syn`-based Rust AST extractor for the code-audit pipeline. Walks `.rs` source files under `--root` (and optionally `--shared`) and emits `type-catalog.json` (the `type` subcommand) and `function-catalog.json` (the `func` subcommand), matching the JSON shapes in [`docs/pipeline-contract.md`](../../docs/pipeline-contract.md).

A standalone Cargo binary (`rust-catalog`) — **not** a member of any workspace, so an audited repo's own `Cargo.toml` never sees it. Like the Swift extractor it is compiled: the `code-audit` binary runs `[runtime].bootstrap` (`cargo build --release`) once per laid-down source tree, then `cargo run --release` finds the binary up to date. Requires a Rust toolchain (cargo) 1.93+.

## Usage

```bash
# Build once
cargo build --release

# Type catalog
cargo run --release -- type --root /path/to/repo --output type-catalog.json

# Function catalog (body-hash clustering + signature projection)
cargo run --release -- func --root /path/to/repo --output function-catalog.json

# Treat bodies under N normalized lines as null (default 3)
cargo run --release -- func --root /path/to/repo --min-body-lines 5 --output function-catalog.json

# Cross-package shadow detection (main vs shared)
cargo run --release -- type --root /path/to/crate --shared /path/to/shared --output type-catalog.json

# Via the code-audit binary (auto-bootstraps on first run; emits both catalogs)
code-audit extract rust --root /path/to/repo
```

The extractor:
- Skips dotdirs (`.git`, `.cargo`, `.claude`, etc.) and `node_modules`, `dist`, `build`, `coverage`, and `target` (Rust build output — not a dotdir, so it is named explicitly).
- Tags every record with `is_test: bool` from path patterns (universal `tests/`, `spec/`, `__fixtures__/`, `e2e/` dir segments; `*.test.rs` / `*.spec.rs` / `*.fixture(s).rs` / `*.mock(s).rs` filenames) **plus** AST-based detection of declarations annotated `#[cfg(test)]` directly or nested inside a `#[cfg(test)]` module (the predicate is walked, so `#[cfg(not(test))]` and features whose name merely contains `test` do not count).
- Tags `generated: true` for files under a `generated/` path segment.
- Emits byte-deterministic output (`entries[]` sorted by `package, file, line, name, kind`); only the `generated_at` timestamp varies between runs.

## Kind mapping

How Rust source constructs map to the catalog `kind` field:

| Rust construct | Catalog `kind` | `fields` encoding |
|---|---|---|
| `struct S { f: T, … }` | `type-alias-object` | one `name:type` per named field |
| `struct S(T, U);` (tuple) | `type-alias-object` | positional `0:T`, `1:U` |
| `struct S;` (unit) | `type-alias-object` | `[]` |
| `union U { … }` | `type-alias-object` | like a named struct |
| `enum E { A, B(T), C { x: T } }` | `type-alias-union` | one entry per variant: `A:""`, `B:"(T)"`, `C:"{ x: T }"`, discriminant `D = 1` → `D:"=1"` |
| `trait T: Q { … }` | `interface` | one field per requirement — method → `name:(recv, args) -> ret`, assoc const → `name:Type` (`is_static`), assoc type → `name:bounds` |
| `type X<T> = Y;` | `type-alias-other` | `fields: null`; emits `type_text` + `type_sig` |
| `macro_rules!` | *(skipped in v1)* | — |

`is_optional` in `fields_structured` is set for `Option<…>` fields. `fields_structured` is omitted only for the non-shape `type-alias-other` kind; structs, unions, enums, and traits all carry it.

A trait's requirement set is emitted as its shape (rather than `fields: null`) so the cluster queries' *already-abstracted* demote — which treats an `interface` target with `fields | length >= 2` as a non-trivial protocol — can fire on Rust catalogs. This mirrors the Swift extractor's `includeMethodSignatures: true`; without it the `conforms_to` axis below would have no working consumer.

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

`references[]` collects the last identifier of each type path appearing in field types, enum-variant payloads, the aliased type of a `type` alias, and trait method signatures — including trait names in `dyn Trait` / `impl Trait` / generic-bound positions (ubiquitous marker derives like `Send`/`Sync`/`Clone` are denylisted via `is_std_derive`, and structural std traits like `Fn`/`Iterator`/`Future`/`Into` via `is_builtin_type`) — minus in-scope generic parameters (each trait method's own type parameters form a child scope) and the builtin denylist. A `Self::Assoc` projection is dropped (it names the enclosing type's own associated type, not an external type); other self-references are kept (per contract). Trait bounds written in a `where` clause are not yet walked (see Known limitations).

## Function catalog (`func`)

The `func` subcommand emits `function-catalog.json`: one row per free function (`kind: function`), inherent / trait-impl method, and trait method (`kind: method`). Methods are name-qualified `SelfType.method` / `Trait.method`. Alongside the signature projection (typed `params`, `return_ref`, function-level `references` — same resolution rules as the type catalog), each row carries body-level data for duplication clustering.

- **Body normalization — token-stream per statement.** Each statement is rendered through `syn`'s token stream and normalized with the same `normalize_token_string` the type catalog uses, then the lines are blank-filtered, sorted, and deduped; `body_hash` is the sha256 of the joined lines. Token streams carry no comments and no formatting, so two copy-pasted bodies that were `rustfmt`'d differently still hash identically — the property that makes cross-crate copy-paste detection robust. The trade-off is real, not cosmetic: granularity is per-*statement*, so a body that is a single compound statement (one `match`, `for`, or builder chain spanning many source lines) renders as **one** `body_line`. See the body-granularity limitation below — such a body can fall under `--min-body-lines` and drop out of the duplication queries entirely.
- **Body gating (`--min-body-lines`, default 3).** A body whose count of *distinct* normalized lines is below the threshold — and every signature-only trait method — emits `body_hash` / `body_lines` / `body_line_count` / `body_length` as `null` (the row is still emitted so signature-level queries like `public-api-leaks` see it). Because the count is of distinct lines (the set is deduped for Jaccard, matching the Python reference), a body of repeated identical statements can also gate to `null`.
- **`references` include inline generic bounds.** Like the type catalog's trait-method handling, a callable's `references` cover its param/return types **and** the inline trait bounds on its own type parameters (`fn f<T: DomainTrait>` records `DomainTrait`). `where`-clause bounds are not yet walked (same limitation as the type catalog).
- **`exported` reflects declared visibility.** Free functions and inherent-impl methods use their own `pub`. Trait default / required methods inherit the enclosing trait's visibility (a method on a `pub trait` is exported). **Trait-impl methods** (`impl Trait for Type`) carry `Inherited` visibility in `syn` — Rust forbids `pub` on them — so they report `exported: false`; their reachability *through* a public trait is not modeled. No consumer depends on method export today (`public-api-leaks.jq` skips `kind == "method"` rows), so this stays honest rather than over-reporting `exported: true` for, e.g., a private-trait impl on a private type.
- **`signature_index` is always `0`.** Rust has no function overloading.
- **`symbol_id`** reuses the type catalog's 4-tuple `(package, file, name, kind)` sha1. (The Python function catalog hashes a 5-tuple including `signature_index`; since Rust's is always `0` the 4-tuple is collision-free here and matches `symbol-id-collisions.jq`'s grouping.)
- **Nested fns are not extracted** (mirrors the type catalog's no-fn-body-items limitation).

## Tests

```bash
cargo test
```

Unit tests cover the pure helpers (`shape_sig`, denylists, path classification, ISO-8601, `sha256_hex`). Two integration tests run the built binary against the `tests/fixtures/` `.rs` files and assert the emitted catalogs, including determinism (two runs produce identical `entries`): `tests/integration.rs` for the `type` catalog and `tests/func_integration.rs` for the `func` catalog.

## Known limitations (v0.1.0)

- **Function bodies cluster at statement granularity.** `body_lines` is one normalized line per statement (token-rendered), not per source line — see [Function catalog](#function-catalog-func). For multi-statement bodies (the common case) exact-clone detection is unaffected and near-duplicate Jaccard is only slightly coarser. The sharp edge is a body that is a **single compound statement** (a lone `match` / `for` / `if let` / builder chain): it renders as one `body_line`, so at the default `--min-body-lines 3` it gates to `null` and is omitted from `function-duplicates.jq` / `generic-function-candidates.jq` altogether — two copy-pasted single-`match` dispatchers would not cluster. The Python extractor (`ast.unparse` + split) keeps these multi-line, so the same code can yield different duplicate sets across languages. Lower `--min-body-lines` to surface such bodies, at the cost of more trivial-getter noise; a source-line renderer (deferred) would close the gap.
- **`macro_rules!` skipped.** Macro-generated types are invisible until macro expansion is wired in. Rare in practice; documented rather than silently dropped.
- **Name-based `conforms_to` join.** `impl Trait for Type` edges are attached by the type's bare name within a package, with no path resolution — two distinct types sharing a name in one package would both receive the edge. Rare; matches the contract's name-based join philosophy.
- **Bare (unqualified) declaration names.** Items nested in modules are emitted under their bare identifier (not module-qualified), so two same-named types in one file share a `symbol_id`. The dominant top-level case is unaffected.
- **No fn-body items.** Structs/enums declared inside a function body are not extracted (only module-level items and items inside inline `mod` blocks). Cross-cutting analysis rarely needs locals.
- **Lifetimes dropped from `generics`.** `generics` lists type and const parameters only.
- **`where`-clause bounds not walked.** Trait bounds in inline positions (`dyn Trait`, `impl Trait`, `fn f<T: Bound>`) feed `references`, but bounds moved into a `where` clause (`where T: Bound`) are not yet collected. Rare for cross-cutting analysis; the inline forms cover the common cases.
- **Raw identifiers keep the `r#` prefix.** A `r#type` struct/field is catalogued verbatim (`r#type`), so it won't cluster with a plainly-spelled `type` elsewhere. Raw idents are rare in type/field positions.
