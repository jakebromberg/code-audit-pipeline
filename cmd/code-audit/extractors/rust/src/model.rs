//! Serde model for the canonical catalog JSON (docs/pipeline-contract.md).
//!
//! Struct field declaration order is the JSON key order. `Option` fields that
//! the contract requires-as-null (`fields`, `shape_sig`) are emitted as `null`
//! when absent; the genuinely optional fields skip serialization when `None`.

use serde::Serialize;

#[derive(Serialize)]
pub struct Catalog {
    pub schema_version: &'static str,
    pub extractor: ExtractorBlock,
    pub fingerprint_v: &'static str,
    pub generated_at: String,
    pub entries: Vec<Entry>,
}

#[derive(Serialize)]
pub struct ExtractorBlock {
    pub language: &'static str,
    pub name: &'static str,
    pub version: &'static str,
    pub source_sha: String,
}

/// One field/variant rendered both flat (`fields`) and structured.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct FieldStruct {
    pub name: String,
    #[serde(rename = "type")]
    pub ty: String,
    pub is_optional: bool,
    pub is_static: bool,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Reference {
    pub name: String,
    pub kind: &'static str, // always "type-ref" in v1
}

impl Reference {
    pub fn type_ref(name: impl Into<String>) -> Self {
        Reference {
            name: name.into(),
            kind: "type-ref",
        }
    }
}

#[derive(Serialize)]
pub struct Entry {
    pub name: String,
    pub kind: String,
    pub package: String,
    pub file: String,
    pub line: usize,
    pub language: &'static str,
    pub symbol_id: String,
    pub exported: bool,
    pub generated: bool,
    pub is_test: bool,
    pub touched_in_window: bool,

    // Shape-of-named-members. `null` (not omitted) for non-shape kinds so
    // `select(.shape_sig != null)` query guards behave identically to other
    // extractors.
    pub fields: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fields_structured: Option<Vec<FieldStruct>>,
    pub shape_sig: Option<String>,

    // Non-object type aliases only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub type_text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub type_sig: Option<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub generics: Option<String>,

    pub extends: Vec<String>,
    pub conforms_to: Vec<String>,
    pub references: Vec<Reference>,
    pub references_count: usize,
}
