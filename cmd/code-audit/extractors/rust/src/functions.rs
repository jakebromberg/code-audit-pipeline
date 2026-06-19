//! Per-file callable extraction → `FnEntry` rows (function-catalog.json).
//!
//! Walks `syn` items for callables and emits one row each:
//!   - `Item::Fn`                       -> kind `function` (free function)
//!   - `ImplItem::Fn` in `Item::Impl`   -> kind `method`, name `SelfType.method`
//!   - `TraitItem::Fn` in `Item::Trait` -> kind `method`, name `Trait.method`
//!     (default body -> body fields; signature-only -> null body fields)
//!
//! Nested fns inside fn bodies are NOT extracted (mirrors the type catalog's
//! "no fn-body items" limitation). `signature_index` is always 0 — Rust has no
//! overloading. Reuses the type-catalog helpers promoted to `pub(crate)` in
//! `extract.rs` (ref collection, visibility, generic scoping, cfg(test) gating).

use std::collections::HashSet;

use quote::ToTokens;

use crate::extract::{
    attrs_have_cfg_test, collect_refs, generic_names, generic_set, is_pub, type_base_name, FileCtx,
};
use crate::func_model::{FnEntry, Param};
use crate::util;

/// Parse one file and append its callable rows. Parse errors go to stderr and
/// the file is skipped (mirrors `extract::extract_file`).
pub fn extract_funcs_file(
    text: &str,
    ctx: &FileCtx,
    min_body_lines: usize,
    entries: &mut Vec<FnEntry>,
) {
    let file = match syn::parse_file(text) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("  parse error {}: {e}", ctx.rel);
            return;
        }
    };
    walk_items(&file.items, ctx, false, min_body_lines, entries);
}

fn walk_items(
    items: &[syn::Item],
    ctx: &FileCtx,
    in_cfg_test: bool,
    min: usize,
    entries: &mut Vec<FnEntry>,
) {
    for item in items {
        match item {
            syn::Item::Fn(f) => entries.push(free_fn(f, ctx, in_cfg_test, min)),
            syn::Item::Impl(i) => impl_methods(i, ctx, in_cfg_test, min, entries),
            syn::Item::Trait(t) => trait_methods(t, ctx, in_cfg_test, min, entries),
            syn::Item::Mod(m) => {
                if let Some((_, inner)) = &m.content {
                    let nested_test = in_cfg_test || attrs_have_cfg_test(&m.attrs);
                    walk_items(inner, ctx, nested_test, min, entries);
                }
            }
            _ => {} // consts, statics, uses, macros, etc.
        }
    }
}

fn free_fn(f: &syn::ItemFn, ctx: &FileCtx, in_cfg_test: bool, min: usize) -> FnEntry {
    build_entry(BuildParts {
        ctx,
        in_cfg_test,
        min,
        kind: "function",
        name: f.sig.ident.to_string(),
        line: f.sig.ident.span().start().line,
        sig: &f.sig,
        outer_generics: None,
        block: Some(&f.block),
        exported: is_pub(&f.vis),
    })
}

fn impl_methods(
    i: &syn::ItemImpl,
    ctx: &FileCtx,
    in_cfg_test: bool,
    min: usize,
    entries: &mut Vec<FnEntry>,
) {
    let self_base = type_base_name(&i.self_ty);
    // Trait-impl methods carry `Inherited` visibility in syn but are reachable
    // wherever the trait + type are in scope; conservatively mark them exported
    // so `public-api-leaks.jq` never under-reports (documented approximation).
    let is_trait_impl = i.trait_.is_some();
    for it in &i.items {
        if let syn::ImplItem::Fn(m) = it {
            let name = match &self_base {
                Some(t) => format!("{t}.{}", m.sig.ident),
                None => m.sig.ident.to_string(),
            };
            let exported = if is_trait_impl { true } else { is_pub(&m.vis) };
            entries.push(build_entry(BuildParts {
                ctx,
                in_cfg_test,
                min,
                kind: "method",
                name,
                line: m.sig.ident.span().start().line,
                sig: &m.sig,
                outer_generics: Some(&i.generics),
                block: Some(&m.block),
                exported,
            }));
        }
    }
}

fn trait_methods(
    t: &syn::ItemTrait,
    ctx: &FileCtx,
    in_cfg_test: bool,
    min: usize,
    entries: &mut Vec<FnEntry>,
) {
    // Trait items inherit the trait's visibility (they have no `vis` of their own).
    let exported = is_pub(&t.vis);
    for it in &t.items {
        if let syn::TraitItem::Fn(m) = it {
            entries.push(build_entry(BuildParts {
                ctx,
                in_cfg_test,
                min,
                kind: "method",
                name: format!("{}.{}", t.ident, m.sig.ident),
                line: m.sig.ident.span().start().line,
                sig: &m.sig,
                outer_generics: Some(&t.generics),
                // Default body -> body fields; signature-only -> null body.
                block: m.default.as_ref(),
                exported,
            }));
        }
    }
}

struct BuildParts<'a> {
    ctx: &'a FileCtx<'a>,
    in_cfg_test: bool,
    min: usize,
    kind: &'static str,
    name: String,
    line: usize,
    sig: &'a syn::Signature,
    /// impl-/trait-level generics in scope, merged into the reference-exclusion
    /// set so an outer `T` doesn't leak into a method's `references`.
    outer_generics: Option<&'a syn::Generics>,
    block: Option<&'a syn::Block>,
    exported: bool,
}

fn build_entry(p: BuildParts) -> FnEntry {
    // Names bound by generics (this fn's own + any enclosing impl/trait) are
    // excluded from refs — `fn f<T>(x: T) -> T` records zero references.
    let mut exclude: HashSet<String> = generic_set(&p.sig.generics);
    if let Some(g) = p.outer_generics {
        exclude.extend(generic_names(g));
    }

    let mut params: Vec<Param> = Vec::new();
    let mut param_names: Vec<String> = Vec::new();
    let mut sig_types: Vec<&syn::Type> = Vec::new();
    for input in &p.sig.inputs {
        // FnArg::Receiver (`self` / `&self`) is skipped — caller-perspective arity.
        if let syn::FnArg::Typed(pt) = input {
            let pname = pat_name(&pt.pat);
            param_names.push(pname.clone());
            params.push(Param {
                name: pname,
                type_ref: single_type_ref(&pt.ty, &exclude),
                type_refs: collect_refs(&[&pt.ty], &exclude),
            });
            sig_types.push(&pt.ty);
        }
    }

    let return_ref = match &p.sig.output {
        syn::ReturnType::Type(_, ty) => {
            sig_types.push(ty);
            single_type_ref(ty, &exclude)
        }
        syn::ReturnType::Default => None,
    };

    let references = collect_refs(&sig_types, &exclude);
    let references_count = references.len();
    let body = p.block.map(|b| body_fields(b, p.min)).unwrap_or_default();

    FnEntry {
        symbol_id: util::symbol_id(p.ctx.package, p.ctx.rel, &p.name, p.kind),
        name: p.name,
        kind: p.kind,
        package: p.ctx.package.to_string(),
        file: p.ctx.rel.to_string(),
        line: p.line,
        language: util::LANGUAGE,
        generated: p.ctx.generated,
        exported: p.exported,
        r#async: p.sig.asyncness.is_some(),
        is_test: p.ctx.path_is_test || p.in_cfg_test,
        touched_in_window: p.ctx.touched,
        synthetic: false,
        param_count: param_names.len(),
        param_names,
        body_hash: body.hash,
        body_line_count: body.line_count,
        body_length: body.length,
        body_lines: body.lines,
        generics: generic_names(&p.sig.generics).join(","),
        params,
        return_ref,
        references,
        references_count,
        signature_index: 0,
    }
}

/// Single-identifier type reference, or `None` for primitives, in-scope
/// generics, and anonymous shapes (tuples, closures, `impl Trait`).
fn single_type_ref(ty: &syn::Type, exclude: &HashSet<String>) -> Option<String> {
    match type_base_name(ty) {
        Some(n) if !util::is_builtin_type(&n) && !exclude.contains(&n) => Some(n),
        _ => None,
    }
}

/// Param name from its pattern: the bound identifier for the common case,
/// else a normalized token rendering of the pattern (e.g. `(a, b)`).
fn pat_name(pat: &syn::Pat) -> String {
    match pat {
        syn::Pat::Ident(pi) => pi.ident.to_string(),
        other => util::normalize_token_string(&other.to_token_stream().to_string()),
    }
}

#[derive(Default)]
struct BodyFields {
    hash: Option<String>,
    line_count: Option<usize>,
    length: Option<usize>,
    lines: Option<Vec<String>>,
}

/// Normalize a block body into deduped, sorted lines (one per statement,
/// token-rendered so comments and formatting are dropped) and compute the
/// derived fields. Below `min` distinct lines, all fields stay `None` (`null`).
fn body_fields(block: &syn::Block, min: usize) -> BodyFields {
    let mut lines: Vec<String> = block
        .stmts
        .iter()
        .map(|s| util::normalize_token_string(&s.to_token_stream().to_string()))
        .filter(|l| !l.is_empty())
        .collect();
    lines.sort();
    lines.dedup();
    if lines.len() < min {
        return BodyFields::default();
    }
    let joined = lines.join("\n");
    BodyFields {
        hash: Some(util::sha256_hex(&joined)),
        line_count: Some(lines.len()),
        length: Some(joined.len()),
        lines: Some(lines),
    }
}
