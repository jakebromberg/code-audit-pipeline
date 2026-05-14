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
/// are 1–2 deep).
///
/// Termination guarantee. The primary terminator is the per-record
/// `existingNames` dedup set in `appendInheritedFields`: once every
/// in-catalog parent's declared fields are present on the child, the
/// per-record helper returns false (no `addedFlat` to merge), `anyChanged`
/// stays false across the iteration, and the outer loop breaks early. This
/// holds even for cyclic graphs (`A: B`, `B: A`) because each protocol's
/// declared-field set is finite. The `maxResolutionIterations` cap is a
/// belt-and-suspenders bound for unforeseen pathological inputs — under
/// normal operation the early-exit on `anyChanged == false` fires long
/// before the cap.
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
        // error within a single module, but cross-package scans with --shared
        // can legitimately encounter two unrelated packages declaring the same
        // protocol name. First-occurrence-wins is a safe fallback; the warning
        // below alerts an operator so the collision can be triaged.
        if let priorIdx = protocolIndexByName[r.name] {
            let prior = records[priorIdx]
            logErr(
                "warning: protocol-inheritance index collision on '\(r.name)' — "
                + "kept \(prior.package):\(prior.file):\(prior.line), "
                + "ignored \(r.package):\(r.file):\(r.line)"
            )
        } else {
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
            // Transitive accumulation: if the parent itself was resolved with
            // ancestors of its own (e.g., `protocol B: A` after iteration 1
            // has inherited_from=[A]), the parent's ancestors transitively
            // contributed to this child via the fields we just pulled in. Add
            // them to the child's resolved-parent list so `inherited_from`
            // reflects the full transitive set rather than just direct
            // parents.
            //
            // Ordering note. The result interleaves: each direct parent is
            // appended, then *that parent's* transitive ancestors, then the
            // next direct parent, etc. For `D: A, B` where A.inheritedFrom =
            // [A1] and B.inheritedFrom = [B1], D.inheritedFrom becomes
            // [A, A1, B, B1] — not [A, B, A1, B1]. Downstream consumers that
            // need a direct-vs-transitive distinction should cross-reference
            // `conforms_to[]` (direct parents only) rather than relying on
            // position within `inherited_from`.
            for ancestor in records[parentIdx].inheritedFrom ?? []
            where !newlyResolvedParents.contains(ancestor) {
                newlyResolvedParents.append(ancestor)
            }
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
