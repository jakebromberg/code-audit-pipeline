//
//  ResolveInheritance.swift
//  swift-catalog
//
//  V7 §6.3 protocol-inheritance resolution. Second pass over the type catalog
//  that walks each protocol record's `conforms_to[]`, finds parents that are
//  themselves protocols in the catalog, and unions the parent's `fields[]` /
//  `fields_structured[]` into the child's. Marks resolved records with
//  `resolved_from: "protocol-inheritance"` and `inherited_from: [...]`.
//
//  Mirrors the V5 intersection-type resolution in the TypeScript extractor:
//  fixed-point iteration up to a small cap to handle transitive chains
//  (`C: B`, `B: A` → C ends up with A's fields after two iterations); names
//  that don't resolve to in-catalog protocols are left unresolved (no harm,
//  no error).
//
//  Scope note: this resolves ONLY protocol → protocol inheritance. The V7 §6.2
//  `conforms_to[]` edge captures every name in the inheritance clause,
//  including potential parent classes on class records and raw-value types on
//  enums. The resolution pass skips both — it only proceeds when both the
//  child record and the named parent record are `kind == "interface"`.
//

import Foundation

private let maxResolutionIterations = 5

/// Resolve protocol-inheritance field unions in place across the records list.
/// Idempotent — running multiple times on the same input produces the same
/// output. Fixed-point iteration converges quickly in practice (most chains
/// are 1–2 deep); the iteration cap is the safety net against pathological
/// or cyclic inheritance graphs that the substrate didn't catch.
///
/// Order of operations per record per iteration:
///   1. Look up each name in `conforms_to[]` against the catalog index.
///   2. Skip names not in the catalog (external SDK protocols like `Codable`).
///   3. Skip names whose catalog record isn't `kind == "interface"` (the §6.2
///      class-vs-protocol caveat — if the substrate can't tell, the
///      resolution pass conservatively declines).
///   4. Union the parent's `fields` / `fields_structured` into the child's,
///      deduping by structured-form `name`. Child's declarations take
///      precedence on collision (the child's `name:type` stays; the parent's
///      same-name entry doesn't override).
///   5. Re-sort fields in lockstep (sort by flat `"name:type"` string), so
///      `fields[i]` and `fields_structured[i]` continue to refer to the same
///      member.
///   6. Recompute `shape_sig` from the new flat-fields set.
///   7. Mark `resolved_from = "protocol-inheritance"` and accumulate
///      `inherited_from` with the parent names that contributed fields.
func resolveProtocolInheritance(_ records: inout [TypeRecord]) {
    // Index in-catalog records by name → array-index. Built once; the loop
    // mutates record contents but never reorders.
    var protocolIndexByName: [String: Int] = [:]
    for (i, r) in records.enumerated() where r.kind == "interface" {
        // Same-name protocol records: keep the first occurrence. Swift permits
        // an `extension Foo` on a protocol Foo that adds default impls, but
        // those are extension records (kind == "extension"), not duplicates of
        // the protocol's interface record. Genuine name-collision protocols
        // (two `protocol Foo` in different files) would be a Swift compile
        // error in practice, but the substrate scanner doesn't enforce that;
        // first-occurrence-wins is a safe fallback.
        if protocolIndexByName[r.name] == nil {
            protocolIndexByName[r.name] = i
        }
    }

    for _ in 0 ..< maxResolutionIterations {
        var anyChanged = false
        for i in records.indices where records[i].kind == "interface" {
            if appendInheritedFields(into: &records, at: i, index: protocolIndexByName) {
                anyChanged = true
            }
        }
        if !anyChanged { break }
    }
}

/// One record's worth of resolution work. Returns true if any field was added,
/// false otherwise. Splitting this out keeps the per-iteration loop readable
/// and gives the fixed-point convergence check a clean signal.
private func appendInheritedFields(
    into records: inout [TypeRecord],
    at i: Int,
    index: [String: Int]
) -> Bool {
    guard let parents = records[i].conformsTo, !parents.isEmpty else { return false }

    // Existing field-name set guards against re-adding members the child
    // already declares (or that an earlier iteration already pulled in).
    let existingNames = Set((records[i].fieldsStructured ?? []).map(\.name))

    var newlyResolvedParents: [String] = []
    var addedFlat: [String] = []
    var addedStructured: [FieldStructured] = []

    for parentName in parents {
        guard let parentIdx = index[parentName] else { continue }
        // Don't union from a non-protocol record. The §6.2 conforms_to[] can
        // carry class names (for class records) or raw-value types (for
        // raw-value enums); only resolve when the parent is genuinely a
        // protocol. The `kind == "interface"` filter on `index` building
        // already covers this for the lookup path; the explicit check here is
        // for legibility.
        guard records[parentIdx].kind == "interface" else { continue }

        let parentFlat = records[parentIdx].fields ?? []
        let parentStructured = records[parentIdx].fieldsStructured ?? []

        // The two arrays are emitted in lockstep by TypeCatalogVisitor —
        // sorted by the flat `"name:type"` string. Zip-iterating preserves
        // that correspondence.
        var contributed = false
        for (flat, structured) in zip(parentFlat, parentStructured) {
            if existingNames.contains(structured.name) { continue }
            if addedStructured.contains(where: { $0.name == structured.name }) { continue }
            addedFlat.append(flat)
            addedStructured.append(structured)
            contributed = true
        }
        if contributed {
            newlyResolvedParents.append(parentName)
        }
    }

    if addedFlat.isEmpty { return false }

    // Merge child's existing fields with the added parent fields, then re-sort
    // in lockstep so the flat[i] ↔ structured[i] invariant from V6/V7 §6.1
    // is preserved.
    let mergedFlat = (records[i].fields ?? []) + addedFlat
    let mergedStructured = (records[i].fieldsStructured ?? []) + addedStructured
    let sortedPairs = zip(mergedFlat, mergedStructured).sorted { $0.0 < $1.0 }

    records[i].fields = sortedPairs.map(\.0)
    records[i].fieldsStructured = sortedPairs.map(\.1)
    records[i].shapeSig = shapeSig(of: sortedPairs.map(\.0))
    records[i].resolvedFrom = "protocol-inheritance"

    // Accumulate inherited_from across iterations. The fixed-point loop calls
    // us repeatedly; each iteration pulls in only fields that weren't already
    // there, so the parent list grows monotonically until convergence.
    var inherited = records[i].inheritedFrom ?? []
    for parent in newlyResolvedParents where !inherited.contains(parent) {
        inherited.append(parent)
    }
    records[i].inheritedFrom = inherited

    return true
}
