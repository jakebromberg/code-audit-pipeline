//! Serde model for the function catalog JSON (docs/pipeline-contract.md
//! §"Function catalog"). Separate from the type catalog's `Entry` (model.rs);
//! it reuses `ExtractorBlock` and `Reference` from that module.
//!
//! Struct field declaration order is the JSON key order, matched to the
//! contract's example entry. The `body_*` fields are `Option` with **no**
//! `skip_serializing_if`, so a short body emits explicit `null` (not an omitted
//! key) — body-level cluster queries early-filter with `select(.body_hash !=
//! null)`, so the key must be present.

use serde::Serialize;

use crate::model::{ExtractorBlock, Reference};

#[derive(Serialize)]
pub struct FnCatalog {
    pub schema_version: &'static str,
    pub extractor: ExtractorBlock,
    pub fingerprint_v: &'static str,
    pub generated_at: String,
    pub entries: Vec<FnEntry>,
}

/// One typed parameter (the implicit `self` receiver is excluded upstream).
#[derive(Serialize)]
pub struct Param {
    pub name: String,
    /// Single-identifier type, or `null` for primitives / generic params /
    /// anonymous shapes (tuples, closures).
    pub type_ref: Option<String>,
    /// Full deduped reference set inside the param's type (`Vec<Foo>` -> Foo).
    pub type_refs: Vec<Reference>,
}

/// One free function / method / trait-method declaration.
#[derive(Serialize)]
pub struct FnEntry {
    pub name: String,
    pub kind: &'static str, // "function" | "method"
    pub package: String,
    pub file: String,
    pub line: usize,
    pub language: &'static str,
    pub symbol_id: String,
    pub generated: bool,
    pub exported: bool,
    #[serde(rename = "async")]
    pub r#async: bool,
    pub is_test: bool,
    pub touched_in_window: bool,
    pub synthetic: bool, // always false; reserved for future use

    pub param_count: usize,
    pub param_names: Vec<String>,

    // Body-level data (duplication clustering). All `null` when the normalized
    // body has fewer than `--min-body-lines` lines, or for signature-only
    // (bodyless) trait methods. Emitted as `null`, never omitted.
    pub body_hash: Option<String>,
    pub body_line_count: Option<usize>,
    pub body_length: Option<usize>,
    pub body_lines: Option<Vec<String>>,

    // Signature-level data (cross-catalog type resolution).
    pub generics: String, // comma-joined; "" when none
    pub params: Vec<Param>,
    pub return_ref: Option<String>,
    pub references: Vec<Reference>,
    pub references_count: usize,

    pub signature_index: usize, // always 0 — Rust has no overloading
}
