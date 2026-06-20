//! End-to-end: run the built `rust-catalog` binary with the `func` subcommand
//! against `tests/fixtures` and assert the emitted function catalog against the
//! contract (docs/pipeline-contract.md §"Function catalog").

use std::process::Command;

use serde_json::{json, Value};

fn fixtures_dir() -> String {
    format!("{}/tests/fixtures", env!("CARGO_MANIFEST_DIR"))
}

fn run_func() -> Value {
    run_func_args(&["func", "--root", &fixtures_dir()])
}

fn run_func_args(args: &[&str]) -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_rust-catalog"))
        .args(args)
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
fn trait_impl_method_exported_is_declared_visibility() {
    let cat = run_func();
    // Trait-impl methods carry `Inherited` visibility (Rust forbids `pub` on
    // them), so `exported` is false — honest about the declaration rather than
    // an over-report. `public-api-leaks.jq` skips method rows, so nothing relies
    // on the old `true`; this avoids claiming a private-trait/private-type method
    // is exported.
    let m = find(&cat, "PrivateType.secret");
    assert_eq!(m["kind"], "method");
    assert_eq!(m["exported"], false);
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
fn is_test_tagged_for_cfg_test_functions() {
    let cat = run_func();
    // Production free fn -> false.
    assert_eq!(find(&cat, "real_helper")["is_test"], false);
    // Item-level `#[cfg(test)]` on a free fn -> true (regression: the walker
    // must consult each item's own attrs, not only `mod` attrs).
    assert_eq!(find(&cat, "item_level_test_fn")["is_test"], true);
    // Fn nested in a `#[cfg(test)]` module -> true.
    assert_eq!(find(&cat, "nested_test_fn")["is_test"], true);
}

#[test]
fn generated_flag_propagates_to_functions() {
    let cat = run_func();
    assert_eq!(find(&cat, "generated_fn")["generated"], true);
}

#[test]
fn inline_generic_bound_is_recorded_in_references() {
    let cat = run_func();
    let f = find(&cat, "run_with_handler");
    assert_eq!(f["generics"], "H");
    // `DomainHandler` appears only as the bound on `H`, never in a param/return
    // type position — it must still surface as a reference.
    assert_eq!(
        f["references"],
        json!([{"name": "DomainHandler", "kind": "type-ref"}])
    );
}

#[test]
fn self_projection_is_not_a_phantom_reference() {
    let cat = run_func();
    // `Self::Output` is the trait's own associated type, not an external ref.
    let p = find(&cat, "Projector.project");
    assert!(p["return_ref"].is_null());
    assert_eq!(p["references"], json!([]));
    // The qualified form `<Self as Projector>::Output` must also be dropped.
    let q = find(&cat, "Projector.project_qualified");
    assert!(q["return_ref"].is_null());
    assert_eq!(q["references"], json!([]));
}

#[test]
fn raw_identifier_param_name_is_unrawed() {
    let cat = run_func();
    let f = find(&cat, "raw_param");
    assert_eq!(f["param_names"], json!(["type"]));
    assert_eq!(f["params"][0]["name"], "type");
}

#[test]
fn empty_body_is_null_even_at_min_body_lines_zero() {
    // `--min-body-lines 0` must not cluster every empty-bodied fn on the sha256
    // of the empty string — an empty body carries no duplication signal.
    let cat = run_func_args(&["func", "--root", &fixtures_dir(), "--min-body-lines", "0"]);
    let empty = find(&cat, "truly_empty");
    assert!(empty["body_hash"].is_null());
    assert!(empty["body_lines"].is_null());
    // A real multi-line body is still emitted at min 0.
    assert!(find(&cat, "assemble_widget")["body_hash"].is_string());
}

#[test]
fn output_is_deterministic() {
    let a = run_func();
    let b = run_func();
    // generated_at may differ between runs; entries must be byte-stable.
    assert_eq!(a["entries"], b["entries"]);
}
