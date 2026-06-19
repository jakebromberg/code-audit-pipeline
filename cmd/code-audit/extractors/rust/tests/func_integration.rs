//! End-to-end: run the built `rust-catalog` binary with the `func` subcommand
//! against `tests/fixtures` and assert the emitted function catalog against the
//! contract (docs/pipeline-contract.md §"Function catalog").

use std::process::Command;

use serde_json::{json, Value};

fn fixtures_dir() -> String {
    format!("{}/tests/fixtures", env!("CARGO_MANIFEST_DIR"))
}

fn run_func() -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_rust-catalog"))
        .args(["func", "--root", &fixtures_dir()])
        .output()
        .expect("spawn rust-catalog");
    assert!(
        out.status.success(),
        "extractor exited non-zero: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).expect("valid JSON on stdout")
}

fn find<'a>(cat: &'a Value, name: &str) -> &'a Value {
    cat["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["name"] == name)
        .unwrap_or_else(|| panic!("entry `{name}` not found"))
}

#[test]
fn wrapper_metadata() {
    let cat = run_func();
    assert_eq!(cat["schema_version"], "2.0");
    assert_eq!(cat["fingerprint_v"], "shape_sig:1");
    assert_eq!(cat["extractor"]["language"], "rust");
    // `name` is the catalog KIND — the function catalog, not the type catalog.
    assert_eq!(cat["extractor"]["name"], "function-catalog");
}

#[test]
fn free_function_signature_and_body() {
    let cat = run_func();
    let f = find(&cat, "assemble_widget");
    assert_eq!(f["kind"], "function");
    assert_eq!(f["exported"], true);
    assert_eq!(f["async"], false);
    assert_eq!(f["signature_index"], 0);
    assert_eq!(f["param_count"], 2);
    assert_eq!(f["param_names"], json!(["input", "count"]));
    // input: Widget (kept) + count: usize (builtin, dropped); return Gadget.
    assert_eq!(f["return_ref"], "Gadget");
    assert_eq!(
        f["references"],
        json!([
            {"name": "Gadget", "kind": "type-ref"},
            {"name": "Widget", "kind": "type-ref"},
        ])
    );
    assert_eq!(f["references_count"], 2);
    // First param's single-ident type ref.
    assert_eq!(f["params"][0]["type_ref"], "Widget");
    // Long body -> populated body fields.
    assert!(f["body_hash"].is_string());
    assert!(f["body_line_count"].as_u64().unwrap() >= 3);
    assert!(f["body_lines"].is_array());
    assert_eq!(find(&cat, "private_helper")["exported"], false);
}

#[test]
fn async_flag() {
    let cat = run_func();
    assert_eq!(find(&cat, "fetch_gadget")["async"], true);
}

#[test]
fn generics_excluded_from_references() {
    let cat = run_func();
    let f = find(&cat, "wrap_in_vec");
    assert_eq!(f["generics"], "T");
    // T (generic) and Vec (builtin) are filtered; Widget survives.
    assert_eq!(
        f["references"],
        json!([{"name": "Widget", "kind": "type-ref"}])
    );
    // `item: T` -> type_ref null (generic); `seed: Widget` -> "Widget".
    let item = &f["params"][0];
    assert_eq!(item["name"], "item");
    assert!(item["type_ref"].is_null());
    assert_eq!(f["params"][1]["type_ref"], "Widget");
    // Return `Vec<T>` -> return_ref null (Vec is builtin).
    assert!(f["return_ref"].is_null());
}

#[test]
fn short_body_emits_null_fields() {
    let cat = run_func();
    let f = find(&cat, "tiny");
    // Row is present, but every body field is explicit JSON null (not omitted).
    assert!(f["body_hash"].is_null());
    assert!(f["body_lines"].is_null());
    assert!(f["body_line_count"].is_null());
    assert!(f["body_length"].is_null());
    // The keys must exist so `select(.body_hash != null)` query guards work.
    assert!(f.as_object().unwrap().contains_key("body_hash"));
}

#[test]
fn inherent_method_visibility() {
    let cat = run_func();
    assert_eq!(find(&cat, "PublicType.visible")["kind"], "method");
    assert_eq!(find(&cat, "PublicType.visible")["exported"], true);
    assert_eq!(find(&cat, "PublicType.hidden")["exported"], false);
}

#[test]
fn trait_impl_method_is_over_reported_exported() {
    let cat = run_func();
    // Private trait + private type, yet marked exported (documented approximation).
    let m = find(&cat, "PrivateType.secret");
    assert_eq!(m["kind"], "method");
    assert_eq!(m["exported"], true);
    assert!(m["body_hash"].is_string());
}

#[test]
fn trait_default_and_signature_only_methods() {
    let cat = run_func();
    // Default method: body populated, exported from the pub trait.
    let described = find(&cat, "PublicTrait.described");
    assert_eq!(described["exported"], true);
    assert!(described["body_hash"].is_string());
    // Signature-only method: null body, still exported (pub trait), has param.
    let required = find(&cat, "PublicTrait.required");
    assert_eq!(required["exported"], true);
    assert!(required["body_hash"].is_null());
    assert_eq!(required["param_names"], json!(["factor"]));
    // Method declared in a private trait -> exported = false.
    assert_eq!(find(&cat, "PrivateTrait.secret")["exported"], false);
}

#[test]
fn duplicate_bodies_share_hash() {
    let cat = run_func();
    let a = find(&cat, "compute_alpha");
    let b = find(&cat, "compute_beta");
    assert!(a["body_hash"].is_string());
    assert_eq!(a["body_hash"], b["body_hash"]);
    // Distinct identity despite the shared body.
    assert_ne!(a["symbol_id"], b["symbol_id"]);
}

#[test]
fn output_is_deterministic() {
    let a = run_func();
    let b = run_func();
    // generated_at may differ between runs; entries must be byte-stable.
    assert_eq!(a["entries"], b["entries"]);
}
