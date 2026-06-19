//! End-to-end: run the built `rust-catalog` binary against `tests/fixtures`
//! and assert the emitted catalog against the contract.

use std::process::Command;

use serde_json::{json, Value};

fn fixtures_dir() -> String {
    format!("{}/tests/fixtures", env!("CARGO_MANIFEST_DIR"))
}

fn run_catalog() -> Value {
    let out = Command::new(env!("CARGO_BIN_EXE_rust-catalog"))
        .args(["type", "--root", &fixtures_dir()])
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
    let cat = run_catalog();
    assert_eq!(cat["schema_version"], "2.0");
    assert_eq!(cat["fingerprint_v"], "shape_sig:1");
    assert_eq!(cat["extractor"]["language"], "rust");
    // `name` is the catalog KIND, not the language (contract + Python/TS siblings).
    assert_eq!(cat["extractor"]["name"], "type-catalog");
}

#[test]
fn named_struct_fields_refs_and_optional() {
    let cat = run_catalog();
    let e = find(&cat, "BranchInfo");
    assert_eq!(e["kind"], "type-alias-object");
    assert_eq!(e["exported"], true);
    assert_eq!(
        e["fields"],
        json!([
            "classification:Classification",
            "counts:HashMap<String, usize>",
            "name:String",
            "repo_path:PathBuf",
            "upstream:Option<String>",
        ])
    );
    // Only the domain type survives the builtin denylist.
    assert_eq!(
        e["references"],
        json!([{"name": "Classification", "kind": "type-ref"}])
    );
    assert_eq!(e["references_count"], 1);
    assert!(e["shape_sig"].is_string());
    // upstream is the optional field.
    let upstream = e["fields_structured"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["name"] == "upstream")
        .unwrap();
    assert_eq!(upstream["is_optional"], true);
    assert_eq!(upstream["type"], "Option<String>");
}

#[test]
fn generics_excluded_from_references() {
    let cat = run_catalog();
    let e = find(&cat, "Wrapper");
    assert_eq!(e["generics"], "T");
    assert_eq!(e["references"], json!([])); // T and String both filtered
}

#[test]
fn tuple_and_unit_structs() {
    let cat = run_catalog();
    assert_eq!(find(&cat, "Pair")["fields"], json!(["0:String", "1:usize"]));
    assert_eq!(find(&cat, "Marker")["fields"], json!([]));
    assert_eq!(find(&cat, "PrivateThing")["exported"], false);
}

#[test]
fn enum_variants_and_discriminants() {
    let cat = run_catalog();
    let c = find(&cat, "Classification");
    assert_eq!(c["kind"], "type-alias-union");
    assert_eq!(
        c["fields"],
        json!([
            "Active:(String)",
            "Diverged:(usize, usize)",
            "Landed:",
            "LandedByContent:{ matched: usize, total: usize }",
        ])
    );
    assert_eq!(
        find(&cat, "Priority")["fields"],
        json!(["High:=10", "Low:=1"])
    );
}

#[test]
fn trait_is_interface_with_supertrait_conformance() {
    let cat = run_catalog();
    let label = find(&cat, "ClassificationLabel");
    assert_eq!(label["kind"], "interface");
    assert_eq!(label["fields"], Value::Null);

    let reportable = find(&cat, "Reportable");
    // Send is denylisted; ClassificationLabel survives.
    assert_eq!(reportable["conforms_to"], json!(["ClassificationLabel"]));
    // Method-signature types surface as references.
    assert_eq!(
        reportable["references"],
        json!([
            {"name": "ReportCtx", "kind": "type-ref"},
            {"name": "Summary", "kind": "type-ref"},
        ])
    );
}

#[test]
fn type_aliases() {
    let cat = run_catalog();
    let m = find(&cat, "RepoMap");
    assert_eq!(m["kind"], "type-alias-other");
    assert!(m["type_text"].as_str().unwrap().contains("HashMap"));
    assert_eq!(
        m["references"],
        json!([{"name": "BranchInfo", "kind": "type-ref"}])
    );

    let h = find(&cat, "Handler");
    assert_eq!(h["generics"], "T");
    assert_eq!(
        h["references"],
        json!([{"name": "Error", "kind": "type-ref"}])
    );
}

#[test]
fn conforms_to_merges_derive_and_impl_blocks() {
    let cat = run_catalog();
    // Serialize (derive) + ClassificationLabel + Display (impl blocks); Debug/Clone filtered.
    assert_eq!(
        find(&cat, "BranchScanResult")["conforms_to"],
        json!(["ClassificationLabel", "Display", "Serialize"])
    );
    // All derives denylisted.
    assert_eq!(find(&cat, "PlainCounts")["conforms_to"], json!([]));
}

#[test]
fn is_test_via_cfg_test_module() {
    let cat = run_catalog();
    assert_eq!(find(&cat, "RealType")["is_test"], false);
    assert_eq!(find(&cat, "TestOnly")["is_test"], true);
}

#[test]
fn cfg_predicate_not_test_and_test_substring_are_not_test() {
    // `#[cfg(not(test))]` is production-only and `feature = "fastest"` merely
    // contains the substring "test"; neither may flip is_test (regression for
    // the prior `.contains("test")` predicate match).
    let cat = run_catalog();
    assert_eq!(find(&cat, "ProdOnly")["is_test"], false);
    assert_eq!(find(&cat, "FastPath")["is_test"], false);
}

#[test]
fn generated_flag_from_path() {
    let cat = run_catalog();
    assert_eq!(find(&cat, "Generated")["generated"], true);
}

#[test]
fn output_is_deterministic() {
    let a = run_catalog();
    let b = run_catalog();
    // generated_at may differ between runs; entries must be byte-stable.
    assert_eq!(a["entries"], b["entries"]);
}
