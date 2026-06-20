//! Per-file AST extraction: maps `syn` items to canonical catalog entries.
//!
//! Kind mapping (docs/pipeline-contract.md):
//!   struct / tuple-struct / unit-struct / union  -> type-alias-object
//!   enum                                          -> type-alias-union
//!   trait                                         -> interface
//!   type X = Y                                    -> type-alias-other
//!   macro_rules!                                  -> skipped (v1)
//!
//! `conforms_to` is populated from three sources: `#[derive(...)]` (minus the
//! std-derive denylist), supertraits, and — in a package-level second pass —
//! `impl Trait for Type` blocks (see `ImplMap`). `references` and `conforms_to`
//! use the LAST path segment (the type/trait identifier), which is the right
//! choice for Rust where qualified paths (`crate::module::Type`) are the norm;
//! this diverges from the TypeScript leftmost-segment convention by design.

use std::collections::{BTreeSet, HashMap, HashSet};

use quote::ToTokens;
use syn::visit::Visit;

use crate::model::{Entry, FieldStruct, Reference};
use crate::util;

/// Type name -> set of trait names it conforms to via `impl Trait for Type`.
/// Accumulated across every file in a package, then merged in the finalize pass.
pub type ImplMap = HashMap<String, BTreeSet<String>>;

/// Immutable per-file context threaded through the walk.
pub struct FileCtx<'a> {
    pub package: &'a str,
    pub rel: &'a str,
    pub touched: bool,
    pub generated: bool,
    pub path_is_test: bool,
}

/// Parse one file and append its entries; record `impl Trait for Type` edges
/// into `impl_map`. Parse errors are reported to stderr and the file skipped.
pub fn extract_file(text: &str, ctx: &FileCtx, entries: &mut Vec<Entry>, impl_map: &mut ImplMap) {
    let file = match syn::parse_file(text) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("  parse error {}: {e}", ctx.rel);
            return;
        }
    };
    process_items(&file.items, ctx, false, entries, impl_map);
}

fn process_items(
    items: &[syn::Item],
    ctx: &FileCtx,
    in_cfg_test: bool,
    entries: &mut Vec<Entry>,
    impl_map: &mut ImplMap,
) {
    for item in items {
        // `#[cfg(test)]` on the item itself counts the same as nesting it inside
        // a `#[cfg(test)] mod` — a test-only declaration written beside
        // production code (`#[cfg(test)] struct Fixture`) must still be tagged.
        let item_test = |attrs: &[syn::Attribute]| in_cfg_test || attrs_have_cfg_test(attrs);
        match item {
            syn::Item::Struct(s) => entries.push(struct_entry(s, ctx, item_test(&s.attrs))),
            syn::Item::Union(u) => entries.push(union_entry(u, ctx, item_test(&u.attrs))),
            syn::Item::Enum(e) => entries.push(enum_entry(e, ctx, item_test(&e.attrs))),
            syn::Item::Trait(t) => entries.push(trait_entry(t, ctx, item_test(&t.attrs))),
            syn::Item::Type(t) => entries.push(type_alias_entry(t, ctx, item_test(&t.attrs))),
            // A `#[cfg(test)]` impl (annotated directly or nested in a
            // `#[cfg(test)] mod`) is a test-only conformance — recording it
            // would leak the trait into the production type's `conforms_to`,
            // since the package impl-map is merged by name onto every entry.
            syn::Item::Impl(i) if !item_test(&i.attrs) => record_impl(i, impl_map),
            syn::Item::Impl(_) => {}
            syn::Item::Mod(m) => {
                if let Some((_, inner)) = &m.content {
                    let nested_test = in_cfg_test || attrs_have_cfg_test(&m.attrs);
                    process_items(inner, ctx, nested_test, entries, impl_map);
                }
            }
            _ => {} // fns, consts, uses, macro_rules! (skipped in v1), etc.
        }
    }
}

// ---- impl Trait for Type ----------------------------------------------------

fn record_impl(item: &syn::ItemImpl, impl_map: &mut ImplMap) {
    let Some((_, trait_path, _)) = &item.trait_ else {
        return; // inherent impl — no conformance edge
    };
    let Some(trait_name) = last_segment(trait_path) else {
        return;
    };
    if util::is_std_derive(&trait_name) {
        return;
    }
    // Skip blanket impls over a bare type parameter (`impl<T> Trait for T`):
    // the self type is then the parameter itself, and recording it would attach
    // the trait to any concrete type sharing that name. The check requires a
    // single-segment unqualified path so a qualified concrete target whose last
    // segment merely matches a generic name (`impl<Renderer> Bar for
    // crate::Renderer`) is NOT mistaken for a blanket impl.
    if is_bare_generic_self(&item.self_ty, &item.generics) {
        return;
    }
    if let Some(type_name) = type_base_name(&item.self_ty) {
        impl_map.entry(type_name).or_default().insert(trait_name);
    }
}

/// True when `ty` is a bare, single-segment, unqualified path naming one of
/// `generics`' type parameters — i.e. the `T` in `impl<T> Trait for T` — looking
/// through references so reference-target blankets (`impl<T> Trait for &T`) are
/// also caught. This mirrors `type_base_name`'s reference unwrapping, so the two
/// agree on what the self type's base name is.
fn is_bare_generic_self(ty: &syn::Type, generics: &syn::Generics) -> bool {
    match ty {
        syn::Type::Reference(r) => is_bare_generic_self(&r.elem, generics),
        syn::Type::Path(tp) => {
            tp.qself.is_none()
                && tp.path.leading_colon.is_none()
                && tp.path.segments.len() == 1
                && generic_set(generics).contains(&tp.path.segments[0].ident.to_string())
        }
        _ => false,
    }
}

// ---- struct / union ---------------------------------------------------------

fn struct_entry(s: &syn::ItemStruct, ctx: &FileCtx, in_cfg_test: bool) -> Entry {
    let exclude = generic_set(&s.generics);
    let (fields, structured, refs) = encode_fields(&s.fields, &exclude);
    make_entry(EntryParts {
        ctx,
        in_cfg_test,
        name: s.ident.to_string(),
        kind: "type-alias-object",
        line: s.ident.span().start().line,
        exported: is_pub(&s.vis),
        fields: Some(fields),
        structured: Some(structured),
        type_text: None,
        generics: generic_string(&s.generics),
        conforms_to: derive_traits(&s.attrs),
        references: refs,
    })
}

fn union_entry(u: &syn::ItemUnion, ctx: &FileCtx, in_cfg_test: bool) -> Entry {
    let exclude = generic_set(&u.generics);
    let named = syn::Fields::Named(u.fields.clone());
    let (fields, structured, refs) = encode_fields(&named, &exclude);
    make_entry(EntryParts {
        ctx,
        in_cfg_test,
        name: u.ident.to_string(),
        kind: "type-alias-object",
        line: u.ident.span().start().line,
        exported: is_pub(&u.vis),
        fields: Some(fields),
        structured: Some(structured),
        type_text: None,
        generics: generic_string(&u.generics),
        conforms_to: derive_traits(&u.attrs),
        references: refs,
    })
}

/// Encode a `Fields` into (flat, structured, references), sorted in lockstep.
fn encode_fields(
    fields: &syn::Fields,
    exclude: &HashSet<String>,
) -> (Vec<String>, Vec<FieldStruct>, Vec<Reference>) {
    let mut pairs: Vec<(String, FieldStruct)> = Vec::new();
    let mut types: Vec<&syn::Type> = Vec::new();
    match fields {
        syn::Fields::Named(named) => {
            for f in &named.named {
                let name = f.ident.as_ref().map(|i| i.to_string()).unwrap_or_default();
                push_field(&mut pairs, &name, &f.ty);
                types.push(&f.ty);
            }
        }
        syn::Fields::Unnamed(unnamed) => {
            for (i, f) in unnamed.unnamed.iter().enumerate() {
                push_field(&mut pairs, &i.to_string(), &f.ty);
                types.push(&f.ty);
            }
        }
        syn::Fields::Unit => {}
    }
    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    let flat = pairs.iter().map(|p| p.0.clone()).collect();
    let structured = pairs.into_iter().map(|p| p.1).collect();
    let refs = collect_refs(&types, exclude);
    (flat, structured, refs)
}

fn push_field(pairs: &mut Vec<(String, FieldStruct)>, name: &str, ty: &syn::Type) {
    let ty_text = util::normalize_type(ty);
    let is_optional = is_option(ty);
    pairs.push((
        format!("{name}:{ty_text}"),
        FieldStruct {
            name: name.to_string(),
            ty: ty_text,
            is_optional,
            is_static: false,
        },
    ));
}

// ---- enum -------------------------------------------------------------------

fn enum_entry(e: &syn::ItemEnum, ctx: &FileCtx, in_cfg_test: bool) -> Entry {
    let exclude = generic_set(&e.generics);
    let mut pairs: Vec<(String, FieldStruct)> = Vec::new();
    let mut types: Vec<&syn::Type> = Vec::new();
    for v in &e.variants {
        let name = v.ident.to_string();
        // Reconstruct the payload from field *types* only — rendering the whole
        // `Fields` token stream would fold per-field attributes and doc comments
        // (`#[arg(...)]`, `#[doc = "..."]`) into the shape signature.
        let payload = match &v.fields {
            syn::Fields::Unit => match &v.discriminant {
                Some((_, expr)) => format!(
                    "={}",
                    util::normalize_token_string(&expr.to_token_stream().to_string())
                ),
                None => String::new(),
            },
            syn::Fields::Unnamed(unnamed) => {
                let types: Vec<String> = unnamed
                    .unnamed
                    .iter()
                    .map(|f| util::normalize_type(&f.ty))
                    .collect();
                format!("({})", types.join(", "))
            }
            syn::Fields::Named(named) => {
                let parts: Vec<String> = named
                    .named
                    .iter()
                    .map(|f| {
                        let n = f.ident.as_ref().map(|i| i.to_string()).unwrap_or_default();
                        format!("{}: {}", n, util::normalize_type(&f.ty))
                    })
                    .collect();
                format!("{{ {} }}", parts.join(", "))
            }
        };
        for ft in v.fields.iter() {
            types.push(&ft.ty);
        }
        pairs.push((
            format!("{name}:{payload}"),
            FieldStruct {
                name,
                ty: payload,
                is_optional: false,
                is_static: false,
            },
        ));
    }
    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    let flat: Vec<String> = pairs.iter().map(|p| p.0.clone()).collect();
    let structured: Vec<FieldStruct> = pairs.into_iter().map(|p| p.1).collect();
    let refs = collect_refs(&types, &exclude);
    make_entry(EntryParts {
        ctx,
        in_cfg_test,
        name: e.ident.to_string(),
        kind: "type-alias-union",
        line: e.ident.span().start().line,
        exported: is_pub(&e.vis),
        fields: Some(flat),
        structured: Some(structured),
        type_text: None,
        generics: generic_string(&e.generics),
        conforms_to: derive_traits(&e.attrs),
        references: refs,
    })
}

// ---- trait ------------------------------------------------------------------

fn trait_entry(t: &syn::ItemTrait, ctx: &FileCtx, in_cfg_test: bool) -> Entry {
    let exclude = generic_set(&t.generics);
    // Supertraits are conformance-only (Rust forbids trait->concrete inheritance).
    let mut conforms: Vec<String> = t
        .supertraits
        .iter()
        .filter_map(|b| match b {
            syn::TypeParamBound::Trait(tb) => last_segment(&tb.path),
            _ => None,
        })
        .filter(|n| !util::is_std_derive(n))
        .collect();
    conforms.extend(derive_traits(&t.attrs));

    // A trait's requirement set IS its shape: each method / associated const /
    // associated type becomes a `fields[]` entry so the interface record carries
    // a non-empty shape. The `is_already_abstracted_cluster` demote treats an
    // interface with >= 2 fields as a non-trivial protocol; without this every
    // Rust trait resolves to zero fields and the demote (the sole consumer of
    // `conforms_to`) can never fire. Mirrors the Swift extractor's
    // `includeMethodSignatures: true`.
    //
    // references: types named in method signatures, minus in-scope generics.
    // Each method's own type parameters form a child scope (contract
    // §references: "function types introduce their own scopes ... so nested
    // generics shadow correctly"), so they're excluded per method. Associated
    // types are not excluded by name (that would also drop an unrelated
    // external type of the same name); the `Self::Assoc` projection is dropped
    // structurally in `RefVisitor` instead.
    let mut pairs: Vec<(String, FieldStruct)> = Vec::new();
    let mut ref_names: BTreeSet<String> = BTreeSet::new();
    for it in &t.items {
        match it {
            syn::TraitItem::Fn(m) => {
                let name = m.sig.ident.to_string();
                let sig = method_sig_text(&m.sig);
                // A method with no `self` receiver is an associated (static,
                // type-level) function — tag it `is_static`, like an associated
                // const, rather than as an instance member.
                let is_static = !m
                    .sig
                    .inputs
                    .iter()
                    .any(|a| matches!(a, syn::FnArg::Receiver(_)));
                pairs.push((
                    format!("{name}:{sig}"),
                    FieldStruct {
                        name,
                        ty: sig,
                        is_optional: false,
                        is_static,
                    },
                ));

                let mut method_exclude = exclude.clone();
                method_exclude.extend(generic_names(&m.sig.generics));
                let mut v = RefVisitor {
                    exclude: &method_exclude,
                    found: BTreeSet::new(),
                };
                for input in &m.sig.inputs {
                    if let syn::FnArg::Typed(pt) = input {
                        v.visit_type(&pt.ty);
                    }
                }
                if let syn::ReturnType::Type(_, ty) = &m.sig.output {
                    v.visit_type(ty);
                }
                // Inline generic-parameter bounds (`fn run<H: Handler>`) are
                // usage edges `visit_type` never sees — feed them to the same
                // visitor so they land in `references` too.
                visit_generic_bounds(&mut v, &m.sig.generics);
                ref_names.extend(v.found);
            }
            // An associated const is a type-level requirement (`is_static`).
            syn::TraitItem::Const(c) => {
                let name = c.ident.to_string();
                let ty = util::normalize_type(&c.ty);
                pairs.push((
                    format!("{name}:{ty}"),
                    FieldStruct {
                        name,
                        ty,
                        is_optional: false,
                        is_static: true,
                    },
                ));
            }
            // An associated type is a requirement too; encode its trait bounds
            // (minus the std-derive denylist) so two traits requiring
            // differently-bounded assoc types don't collapse to one shape.
            syn::TraitItem::Type(at) => {
                let name = at.ident.to_string();
                let bounds = at
                    .bounds
                    .iter()
                    .filter_map(|b| match b {
                        syn::TypeParamBound::Trait(tb) => last_segment(&tb.path),
                        _ => None,
                    })
                    .filter(|n| !util::is_std_derive(n))
                    .collect::<Vec<_>>()
                    .join("+");
                pairs.push((
                    format!("{name}:{bounds}"),
                    FieldStruct {
                        name,
                        ty: bounds,
                        is_optional: false,
                        is_static: false,
                    },
                ));
            }
            _ => {}
        }
    }
    pairs.sort_by(|a, b| a.0.cmp(&b.0));
    let flat: Vec<String> = pairs.iter().map(|p| p.0.clone()).collect();
    let structured: Vec<FieldStruct> = pairs.into_iter().map(|p| p.1).collect();
    let refs: Vec<Reference> = ref_names.into_iter().map(Reference::type_ref).collect();

    make_entry(EntryParts {
        ctx,
        in_cfg_test,
        name: t.ident.to_string(),
        kind: "interface",
        line: t.ident.span().start().line,
        exported: is_pub(&t.vis),
        fields: Some(flat),
        structured: Some(structured),
        type_text: None,
        generics: generic_string(&t.generics),
        conforms_to: conforms,
        references: refs,
    })
}

// ---- type alias -------------------------------------------------------------

fn type_alias_entry(t: &syn::ItemType, ctx: &FileCtx, in_cfg_test: bool) -> Entry {
    let exclude = generic_set(&t.generics);
    let type_text = util::normalize_type(&t.ty);
    let refs = collect_refs(&[&t.ty], &exclude);
    make_entry(EntryParts {
        ctx,
        in_cfg_test,
        name: t.ident.to_string(),
        kind: "type-alias-other",
        line: t.ident.span().start().line,
        exported: is_pub(&t.vis),
        fields: None,
        structured: None,
        type_text: Some(type_text),
        generics: generic_string(&t.generics),
        conforms_to: Vec::new(),
        references: refs,
    })
}

// ---- shared entry construction ----------------------------------------------

struct EntryParts<'a> {
    ctx: &'a FileCtx<'a>,
    in_cfg_test: bool,
    name: String,
    kind: &'static str,
    line: usize,
    exported: bool,
    fields: Option<Vec<String>>,
    structured: Option<Vec<FieldStruct>>,
    type_text: Option<String>,
    generics: Option<String>,
    conforms_to: Vec<String>,
    references: Vec<Reference>,
}

fn make_entry(p: EntryParts) -> Entry {
    let shape_sig = p.fields.as_ref().map(|f| util::shape_sig(f));
    let type_sig = p.type_text.as_ref().map(|t| t.to_lowercase());
    let mut conforms_to = p.conforms_to;
    conforms_to.sort();
    conforms_to.dedup();
    let references_count = p.references.len();
    Entry {
        symbol_id: util::symbol_id(p.ctx.package, p.ctx.rel, &p.name, p.kind),
        name: p.name,
        kind: p.kind.to_string(),
        package: p.ctx.package.to_string(),
        file: p.ctx.rel.to_string(),
        line: p.line,
        language: util::LANGUAGE,
        exported: p.exported,
        generated: p.ctx.generated,
        is_test: p.ctx.path_is_test || p.in_cfg_test,
        touched_in_window: p.ctx.touched,
        fields: p.fields,
        fields_structured: p.structured,
        shape_sig,
        type_text: p.type_text,
        type_sig,
        generics: p.generics,
        extends: Vec::new(), // Rust has no struct/enum inheritance
        conforms_to,
        references: p.references,
        references_count,
    }
}

// ---- helpers ----------------------------------------------------------------

struct RefVisitor<'a> {
    exclude: &'a HashSet<String>,
    found: BTreeSet<String>,
}

impl RefVisitor<'_> {
    /// Record `name` as a reference unless it is a builtin or an in-scope
    /// (generic/Self) name.
    fn record(&mut self, name: String) {
        if !util::is_builtin_type(&name) && !self.exclude.contains(&name) {
            self.found.insert(name);
        }
    }
}

impl<'ast> Visit<'ast> for RefVisitor<'_> {
    fn visit_type_path(&mut self, node: &'ast syn::TypePath) {
        // `Self::Assoc` projections name the enclosing type's own associated
        // type, not an external type — skip the leaf (but still recurse for any
        // generic arguments). See `is_self_projection_path`.
        if !is_self_projection_path(node) {
            if let Some(seg) = node.path.segments.last() {
                self.record(seg.ident.to_string());
            }
        }
        // Recurse so generic arguments (Vec<Classification>) are visited.
        syn::visit::visit_type_path(self, node);
    }

    fn visit_trait_bound(&mut self, node: &'ast syn::TraitBound) {
        // Trait names in bound positions — `dyn Handler`, `impl Encoder`,
        // `T: DomainTrait` — are real usage edges that `visit_type_path` never
        // sees. Ubiquitous marker traits (Send, Sync, …) are denylisted the
        // same way they are in `conforms_to` so they don't flood the graph.
        if let Some(name) = last_segment(&node.path) {
            if !util::is_std_derive(&name) {
                self.record(name);
            }
        }
        syn::visit::visit_trait_bound(self, node);
    }
}

/// True when `tp` is a `Self::Assoc` projection — onto the enclosing type's own
/// associated type, not an external type. Both spellings are covered: the
/// unqualified `Self::Assoc` (a path of at least 2 segments headed by a literal
/// `Self`) and the disambiguated `<Self as Trait>::Assoc` (a `qself` rooted at
/// `Self`). The single home for this rule, shared by `RefVisitor` (which drops
/// it from `references`) and the function catalog's `single_type_ref` (which
/// drops it from `type_ref`/`return_ref`) so the two can't disagree.
///
/// The check is deliberately limited to a literal `Self` root: a generic
/// projection like `T::Output` / `<T as Trait>::Output` is rare, whereas
/// widening the guard to "root is any in-scope generic" would false-drop a real
/// external path whose head merely shares a name with a generic param
/// (`serde::Value` under `trait X<serde>`). A qualified external path
/// (`crate::Type`) is kept by its last segment.
pub(crate) fn is_self_projection_path(tp: &syn::TypePath) -> bool {
    match &tp.qself {
        // `<Self as Trait>::Assoc` — a projection rooted at the `qself` type.
        Some(qself) => type_is_bare_self(&qself.ty),
        // `Self::Assoc` — unqualified, at least 2 segments headed by `Self`.
        None => {
            tp.path.segments.len() >= 2
                && tp.path.segments.first().is_some_and(|s| s.ident == "Self")
        }
    }
}

/// True when `ty` is exactly the bare `Self` type (no qself, single unqualified
/// `Self` segment) — the root of a `<Self as Trait>::Assoc` projection.
fn type_is_bare_self(ty: &syn::Type) -> bool {
    matches!(ty, syn::Type::Path(tp)
        if tp.qself.is_none()
            && tp.path.segments.len() == 1
            && tp.path.segments[0].ident == "Self")
}

pub(crate) fn collect_refs(types: &[&syn::Type], exclude: &HashSet<String>) -> Vec<Reference> {
    // No generics to walk -> identical to a bounds walk over an empty set.
    collect_refs_with_bounds(types, &syn::Generics::default(), exclude)
}

/// Like [`collect_refs`], but also walks the inline trait bounds on `generics`'
/// type parameters (`<T: Bound>` -> `Bound`). The function catalog uses this so
/// a callable constrained by a domain trait via an inline bound records it, the
/// same way `trait_entry` does for trait-method signatures.
pub(crate) fn collect_refs_with_bounds(
    types: &[&syn::Type],
    generics: &syn::Generics,
    exclude: &HashSet<String>,
) -> Vec<Reference> {
    let mut v = RefVisitor {
        exclude,
        found: BTreeSet::new(),
    };
    for t in types {
        v.visit_type(t);
    }
    visit_generic_bounds(&mut v, generics);
    v.found.into_iter().map(Reference::type_ref).collect()
}

/// Drive `v` over the trait-bound paths on `generics`' type parameters so
/// `<T: Bound>` inline bounds become references (the same usage edges that
/// `dyn Bound` / `impl Bound` in type positions already produce). `where`-clause
/// bounds and item-header (struct/enum/trait) generics are not walked — see the
/// README's "Known limitations".
fn visit_generic_bounds(v: &mut RefVisitor<'_>, generics: &syn::Generics) {
    for param in &generics.params {
        if let syn::GenericParam::Type(tp) = param {
            for bound in &tp.bounds {
                if let syn::TypeParamBound::Trait(tb) = bound {
                    v.visit_trait_bound(tb);
                }
            }
        }
    }
}

pub(crate) fn attrs_have_cfg_test(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|a| {
        a.path().is_ident("cfg")
            && match &a.meta {
                syn::Meta::List(list) => cfg_predicate_gates_on_test(list.tokens.clone()),
                _ => false,
            }
    })
}

/// True when a `#[cfg(...)]` predicate is active *only* in `test` builds — i.e.
/// the predicate logically implies `test` (it cannot hold when `test` is off).
/// Walking the token tree (rather than substring-matching the printed predicate)
/// is what lets it distinguish the combinators precisely. `test` and
/// `all(test, X)` gate; `any(test, X)` does NOT (its `X` branch activates the
/// item in a non-test build — the case a naive "`test` appears positively" walk
/// and a `.contains("test")` match both get wrong); `not(...)` is production;
/// and `feature = "fastest"` / `unix` are non-test flags (feature names are
/// string literals, never `test` idents).
fn cfg_predicate_gates_on_test(tokens: proc_macro2::TokenStream) -> bool {
    use proc_macro2::TokenTree;
    let trees: Vec<TokenTree> = tokens.into_iter().collect();
    match trees.as_slice() {
        // A combinator: `ident( <inner> )`.
        [TokenTree::Ident(op), TokenTree::Group(g)] => match op.to_string().as_str() {
            // `not(...)` never *implies* test. Double negation (`not(not(test))`)
            // is intentionally not unwound — treated as non-test.
            "not" => false,
            // A conjunction implies test if ANY operand does.
            "all" => split_top_level_commas(g.stream())
                .into_iter()
                .any(cfg_predicate_gates_on_test),
            // A disjunction implies test only if EVERY operand does.
            "any" => {
                let operands = split_top_level_commas(g.stream());
                !operands.is_empty() && operands.into_iter().all(cfg_predicate_gates_on_test)
            }
            _ => false,
        },
        // A bare `test` flag.
        [TokenTree::Ident(id)] => *id == "test",
        // `feature = "…"`, other bare flags, or anything unrecognized.
        _ => false,
    }
}

/// Split a cfg predicate-list token stream on its top-level commas, dropping
/// empty operands so a trailing comma (`any(test,)`) doesn't synthesize a phantom
/// always-false operand. Commas nested inside an operand's own `(...)` are part
/// of a single `TokenTree::Group` and so are never seen at this level.
fn split_top_level_commas(tokens: proc_macro2::TokenStream) -> Vec<proc_macro2::TokenStream> {
    use proc_macro2::{TokenStream, TokenTree};
    let mut out: Vec<TokenStream> = Vec::new();
    let mut cur: Vec<TokenTree> = Vec::new();
    for tt in tokens {
        match &tt {
            TokenTree::Punct(p) if p.as_char() == ',' => {
                if !cur.is_empty() {
                    out.push(cur.drain(..).collect());
                }
            }
            _ => cur.push(tt),
        }
    }
    if !cur.is_empty() {
        out.push(cur.into_iter().collect());
    }
    out
}

/// Derived trait names minus the std-derive denylist (last path segment).
fn derive_traits(attrs: &[syn::Attribute]) -> Vec<String> {
    let mut out = Vec::new();
    for attr in attrs {
        if !attr.path().is_ident("derive") {
            continue;
        }
        let parsed = attr.parse_args_with(
            syn::punctuated::Punctuated::<syn::Path, syn::Token![,]>::parse_terminated,
        );
        if let Ok(paths) = parsed {
            for p in paths {
                if let Some(name) = last_segment(&p) {
                    if !util::is_std_derive(&name) {
                        out.push(name);
                    }
                }
            }
        }
    }
    out
}

pub(crate) fn is_pub(vis: &syn::Visibility) -> bool {
    matches!(vis, syn::Visibility::Public(_))
}

fn is_option(ty: &syn::Type) -> bool {
    matches!(ty, syn::Type::Path(tp)
        if tp.path.segments.last().map(|s| s.ident == "Option").unwrap_or(false))
}

pub(crate) fn last_segment(path: &syn::Path) -> Option<String> {
    path.segments.last().map(|s| s.ident.to_string())
}

pub(crate) fn type_base_name(ty: &syn::Type) -> Option<String> {
    match ty {
        syn::Type::Path(tp) => last_segment(&tp.path),
        syn::Type::Reference(r) => type_base_name(&r.elem),
        _ => None,
    }
}

/// Render a trait method's signature as deterministic shape text:
/// `(receiver, arg-types) -> ret`. Used only to give an `interface` record a
/// `fields[]` shape; the leading `fn name` and the body are intentionally
/// dropped (the field's name already carries the method name).
fn method_sig_text(sig: &syn::Signature) -> String {
    let mut parts: Vec<String> = Vec::new();
    for input in &sig.inputs {
        match input {
            syn::FnArg::Receiver(r) => parts.push(util::normalize_token_string(
                &r.to_token_stream().to_string(),
            )),
            syn::FnArg::Typed(pt) => parts.push(util::normalize_type(&pt.ty)),
        }
    }
    let ret = match &sig.output {
        syn::ReturnType::Default => String::new(),
        syn::ReturnType::Type(_, ty) => format!(" -> {}", util::normalize_type(ty)),
    };
    format!("({}){ret}", parts.join(", "))
}

/// Type + const generic parameter names (lifetimes dropped), in declaration order.
pub(crate) fn generic_names(g: &syn::Generics) -> Vec<String> {
    g.params
        .iter()
        .filter_map(|p| match p {
            syn::GenericParam::Type(t) => Some(t.ident.to_string()),
            syn::GenericParam::Const(c) => Some(c.ident.to_string()),
            syn::GenericParam::Lifetime(_) => None,
        })
        .collect()
}

pub(crate) fn generic_set(g: &syn::Generics) -> HashSet<String> {
    generic_names(g).into_iter().collect()
}

fn generic_string(g: &syn::Generics) -> Option<String> {
    let names = generic_names(g);
    if names.is_empty() {
        None
    } else {
        Some(names.join(","))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn impl_self(src: &str) -> (syn::Type, syn::Generics) {
        let item: syn::ItemImpl = syn::parse_str(src).unwrap();
        ((*item.self_ty).clone(), item.generics)
    }

    #[test]
    fn bare_generic_self_covers_plain_and_reference_blankets() {
        // `impl<T> Trait for T` and its reference-wrapped forms are blanket
        // impls over a type parameter and must be skipped.
        for src in [
            "impl<T> Tr for T {}",
            "impl<T> Tr for &T {}",
            "impl<T> Tr for &mut T {}",
        ] {
            let (ty, g) = impl_self(src);
            assert!(is_bare_generic_self(&ty, &g), "{src} is a blanket impl");
        }
        // A qualified concrete target whose last segment merely matches a generic
        // name, and a concrete generic instantiation, are NOT blanket impls.
        for src in [
            "impl<Renderer> Tr for crate::Renderer {}",
            "impl<T> Tr for Vec<T> {}",
            "impl Tr for Concrete {}",
        ] {
            let (ty, g) = impl_self(src);
            assert!(
                !is_bare_generic_self(&ty, &g),
                "{src} is NOT a blanket impl"
            );
        }
    }
}
