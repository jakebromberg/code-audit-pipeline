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

fn run_catalog_raw() -> String {
    let out = Command::new(env!("CARGO_BIN_EXE_rust-catalog"))
        .args(["type", "--root", &fixtures_dir()])
        .output()
        .expect("spawn rust-catalog");
    assert!(
        out.status.success(),
        "extractor exited non-zero: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).expect("utf-8 stdout")
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
    // A trait's requirement set IS its shape: each method becomes a
    // `name:(recv, args) -> ret` field so the interface record carries a
    // non-empty fields[]/shape_sig. Without this the `is_already_abstracted`
    // demote (which requires a target interface with >= 2 fields) can never fire
    // for a Rust catalog. Mirrors the Swift extractor's includeMethodSignatures.
    assert_eq!(
        label["fields"],
        json!(["label:(&self) -> &'static str", "priority:(&self) -> u8"])
    );
    assert_eq!(
        label["shape_sig"],
        json!("label:(&self) -> &'static str|priority:(&self) -> u8")
    );
    // fields_structured stays in lockstep and is now emitted for traits.
    let first = &label["fields_structured"][0];
    assert_eq!(first["name"], "label");
    assert_eq!(first["is_static"], false);
    assert_eq!(first["is_optional"], false);

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

    // Method-level generic `T` and the `Self::Item` projection are in-scope
    // names, not external refs (contract §references); only `Id` survives.
    let repo = find(&cat, "Repository");
    assert_eq!(
        repo["references"],
        json!([{"name": "Id", "kind": "type-ref"}])
    );
    // Associated types and generic methods also become fields: `type Item;` →
    // `Item:` (no bounds); `fn save<T>(&self, value: T) -> T` →
    // `save:(&self, T) -> T`. So the trait has >= 2 fields (non-trivial). The
    // `Self::Item` projection in `fetch`'s return is kept verbatim in the field
    // shape but (correctly) does not leak into `references` above.
    assert_eq!(
        repo["fields"],
        json!([
            "Item:",
            "fetch:(&self, Id) -> Self::Item",
            "save:(&self, T) -> T"
        ])
    );

    // ...but an external type sharing a name with an associated type is NOT
    // over-excluded: `inventory::Item` survives even though `Item` is also the
    // associated-type name.
    let externals = find(&cat, "Externals");
    assert_eq!(
        externals["references"],
        json!([{"name": "Item", "kind": "type-ref"}])
    );
}

#[test]
fn trait_object_and_bound_references() {
    // Trait names in `dyn`/bound positions are collected; `Send` (marker) and
    // `Fn`/`Iterator` (structural std traits) are denylisted, but the
    // `Iterator<Item = Event>` binding value `Event` survives.
    let cat = run_catalog();
    assert_eq!(
        find(&cat, "Registry")["references"],
        json!([
            {"name": "Encoder", "kind": "type-ref"},
            {"name": "Event", "kind": "type-ref"},
            {"name": "Handler", "kind": "type-ref"},
        ])
    );
}

#[test]
fn trait_assoc_fn_is_static_and_generic_bound_is_a_reference() {
    let cat = run_catalog();
    let factory = find(&cat, "Factory");
    // `build()` has no receiver → static; `run(&self, ..)` is an instance method.
    assert_eq!(
        factory["fields"],
        json!(["build:() -> Self", "run:(&self, H)"])
    );
    let by_name = |n: &str| {
        factory["fields_structured"]
            .as_array()
            .unwrap()
            .iter()
            .find(|f| f["name"] == n)
            .unwrap()
            .clone()
    };
    assert_eq!(by_name("build")["is_static"], true);
    assert_eq!(by_name("run")["is_static"], false);
    // The method's own generic bound `<H: Handler>` is an inline usage edge:
    // `Handler` surfaces in references; `H` (in-scope) and `Self` (builtin) do
    // not.
    assert_eq!(
        factory["references"],
        json!([{"name": "Handler", "kind": "type-ref"}])
    );
}

#[test]
fn unwritable_output_exits_nonzero() {
    // A requested --output that cannot be written is a failure, not a
    // success-with-stdout-dump (regression for the silent exit-0 path).
    let out = Command::new(env!("CARGO_BIN_EXE_rust-catalog"))
        .args([
            "type",
            "--root",
            &fixtures_dir(),
            "--output",
            "/nonexistent-dir-xyz-983/cat.json",
        ])
        .output()
        .expect("spawn rust-catalog");
    assert!(
        !out.status.success(),
        "expected non-zero exit when --output is unwritable"
    );
    assert!(
        out.stdout.is_empty(),
        "catalog must not be dumped to stdout when --output fails"
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

    // A `#[cfg(test)]` impl must not leak conformance into the production type.
    let client = find(&cat, "ProductionClient");
    assert_eq!(client["is_test"], false);
    assert_eq!(client["conforms_to"], json!([]));
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
fn is_test_via_item_level_cfg_test() {
    // `#[cfg(test)]` directly on a type item (not wrapped in a `mod`) flips
    // is_test — declarations written beside production code are covered.
    let cat = run_catalog();
    assert_eq!(find(&cat, "ItemLevelTestOnly")["is_test"], true);
}

#[test]
fn cfg_any_test_does_not_gate_but_all_test_does() {
    // `any(test, X)` is active in non-test builds (via X), so it must NOT be
    // tagged test-only; `all(test, X)` genuinely requires test, so it is.
    let cat = run_catalog();
    assert_eq!(find(&cat, "AnyTestOrFeature")["is_test"], false);
    assert_eq!(find(&cat, "AllTestAndUnix")["is_test"], true);
}

#[test]
fn generated_flag_from_path() {
    let cat = run_catalog();
    assert_eq!(find(&cat, "Generated")["generated"], true);
}

#[test]
fn output_is_deterministic() {
    // Byte-for-byte: the contract guarantees byte-identical output, so compare
    // raw stdout rather than parsed `Value` (which normalizes object key order
    // and whitespace and would miss a formatting or key-order regression). Only
    // the `generated_at` timestamp line legitimately varies between runs, so it
    // is stripped before comparison.
    let strip_ts = |s: String| {
        s.lines()
            .filter(|l| !l.trim_start().starts_with("\"generated_at\""))
            .collect::<Vec<_>>()
            .join("\n")
    };
    let a = strip_ts(run_catalog_raw());
    let b = strip_ts(run_catalog_raw());
    assert_eq!(a, b, "catalog output is not byte-deterministic");
}
