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
            syn::Item::Impl(i) => record_impl(i, impl_map),
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
    if let Some(type_name) = type_base_name(&item.self_ty) {
        impl_map.entry(type_name).or_default().insert(trait_name);
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

    // references: types named in method signatures, minus in-scope generics.
    // Each method's own type parameters form a child scope (contract
    // §references: "function types introduce their own scopes ... so nested
    // generics shadow correctly"), so they're excluded per method. Associated
    // types are not excluded by name (that would also drop an unrelated
    // external type of the same name); the `Self::Assoc` projection is dropped
    // structurally in `RefVisitor` instead.
    let mut ref_names: BTreeSet<String> = BTreeSet::new();
    for it in &t.items {
        if let syn::TraitItem::Fn(m) = it {
            let mut method_exclude = exclude.clone();
            method_exclude.extend(generic_names(&m.sig.generics));
            let mut sig_types: Vec<&syn::Type> = Vec::new();
            for input in &m.sig.inputs {
                if let syn::FnArg::Typed(pt) = input {
                    sig_types.push(&pt.ty);
                }
            }
            if let syn::ReturnType::Type(_, ty) = &m.sig.output {
                sig_types.push(ty);
            }
            for r in collect_refs(&sig_types, &method_exclude) {
                ref_names.insert(r.name);
            }
        }
    }
    let refs: Vec<Reference> = ref_names.into_iter().map(Reference::type_ref).collect();

    make_entry(EntryParts {
        ctx,
        in_cfg_test,
        name: t.ident.to_string(),
        kind: "interface",
        line: t.ident.span().start().line,
        exported: is_pub(&t.vis),
        fields: None, // a trait's method set is not a struct shape
        structured: None,
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
        // `Self::Assoc` is a projection onto the enclosing type's own
        // associated type, not a use of an external type named `Assoc` — skip
        // it (but still recurse, in case it carries generic arguments).
        let is_self_projection = node.qself.is_none()
            && node.path.segments.len() >= 2
            && node
                .path
                .segments
                .first()
                .is_some_and(|s| s.ident == "Self");
        if !is_self_projection {
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

fn collect_refs(types: &[&syn::Type], exclude: &HashSet<String>) -> Vec<Reference> {
    let mut v = RefVisitor {
        exclude,
        found: BTreeSet::new(),
    };
    for t in types {
        v.visit_type(t);
    }
    v.found.into_iter().map(Reference::type_ref).collect()
}

fn attrs_have_cfg_test(attrs: &[syn::Attribute]) -> bool {
    attrs.iter().any(|a| {
        a.path().is_ident("cfg")
            && match &a.meta {
                syn::Meta::List(list) => cfg_predicate_gates_on_test(list.tokens.clone()),
                _ => false,
            }
    })
}

/// True when a `#[cfg(...)]` predicate activates a `test` configuration in a
/// *positive* position — a bare `test` identifier that is not inside a
/// `not(...)`. Walking the token tree (rather than substring-matching the
/// printed predicate) avoids three false positives the naive `.contains("test")`
/// hit: `cfg(not(test))` (production-only — the inverted case), and any feature
/// whose name merely contains the substring, e.g. `feature = "fastest"` or
/// `feature = "test-utils"` (feature names are string literals, never `test`
/// identifiers).
fn cfg_predicate_gates_on_test(tokens: proc_macro2::TokenStream) -> bool {
    use proc_macro2::TokenTree;
    let mut iter = tokens.into_iter().peekable();
    while let Some(tt) = iter.next() {
        match tt {
            TokenTree::Ident(id) => {
                if id == "test" {
                    return true;
                }
                if id == "not" {
                    // Skip the negated group entirely: `not(test)` must NOT gate.
                    if matches!(iter.peek(), Some(TokenTree::Group(_))) {
                        iter.next();
                    }
                }
                // `all(...)` / `any(...)` idents fall through; their group is
                // recursed into by the `Group` arm below.
            }
            TokenTree::Group(g) => {
                if cfg_predicate_gates_on_test(g.stream()) {
                    return true;
                }
            }
            _ => {}
        }
    }
    false
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

fn is_pub(vis: &syn::Visibility) -> bool {
    matches!(vis, syn::Visibility::Public(_))
}

fn is_option(ty: &syn::Type) -> bool {
    matches!(ty, syn::Type::Path(tp)
        if tp.path.segments.last().map(|s| s.ident == "Option").unwrap_or(false))
}

fn last_segment(path: &syn::Path) -> Option<String> {
    path.segments.last().map(|s| s.ident.to_string())
}

fn type_base_name(ty: &syn::Type) -> Option<String> {
    match ty {
        syn::Type::Path(tp) => last_segment(&tp.path),
        syn::Type::Reference(r) => type_base_name(&r.elem),
        _ => None,
    }
}

/// Type + const generic parameter names (lifetimes dropped), in declaration order.
fn generic_names(g: &syn::Generics) -> Vec<String> {
    g.params
        .iter()
        .filter_map(|p| match p {
            syn::GenericParam::Type(t) => Some(t.ident.to_string()),
            syn::GenericParam::Const(c) => Some(c.ident.to_string()),
            syn::GenericParam::Lifetime(_) => None,
        })
        .collect()
}

fn generic_set(g: &syn::Generics) -> HashSet<String> {
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
