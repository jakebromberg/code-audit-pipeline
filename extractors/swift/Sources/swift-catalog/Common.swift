//
//  Common.swift
//  swift-catalog
//
//  Record types, JSON encoding, body normalization. These shapes mirror the
//  TypeScript extractor output documented in docs/pipeline-contract.md.
//

import CryptoKit
import Foundation
import SwiftSyntax

/// One structured field on a type-catalog record. V7 §6.1: parallel to the
/// flat `fields: ["name:Type"]` form, so downstream queries can ask
/// "find type pairs whose name set is identical but type set differs at slot X"
/// without re-splitting strings at query time.
///
/// `type` is the verbatim type annotation as written in source (Swift syntax
/// sugar preserved: `Int?` stays `Int?`, `Optional<Int>` stays `Optional<Int>`).
/// `isOptional` is the structural flag derived from SwiftSyntax, true when
/// the type-annotation node is OptionalTypeSyntax (`T?`),
/// ImplicitlyUnwrappedOptionalTypeSyntax (`T!`), or an identifier/member
/// reference to `Optional` / `Swift.Optional`. Carrying both is intentional
/// redundancy: `type` is ergonomic for display and string-matching, but
/// optionality detection on `type` alone is unreliable across the Swift
/// spelling variants — `isOptional` is the load-bearing structural flag.
///
/// For enum cases (emitted by `emitEnum`), `type` is the associated-value
/// parameter clause as written (e.g., `"(Int, String)"`), or `"=<rawValue>"`
/// for raw-value cases, or `""` for parameterless cases. Enum cases always
/// emit `isOptional: false` and `isStatic: false`.
struct FieldStructured: Encodable {
    var name: String
    var type: String
    var isOptional: Bool
    var isStatic: Bool
}

struct TypeRecord: Encodable {
    var name: String
    var kind: String
    var package: String
    var file: String
    var line: Int
    var exported: Bool
    var generated: Bool
    var fields: [String]?
    var fieldsStructured: [FieldStructured]?
    var shapeSig: String?
    var touchedInWindow: Bool = false

    /// V7 §6.6 context flags (#44). Heuristic booleans the agent weighs to
    /// distinguish intentional duplication (tests, codegen, sample apps,
    /// mocks) from genuine refactor candidates. Path-based components live in
    /// `Walker.swift`; `is_mock` additionally OR's a record-name suffix check
    /// (`*Mock`, `*Stub`, `*Fake`).
    ///
    /// `is_codegen` is a SUPERSET of `generated`. The legacy `generated`
    /// stays narrow for V6 backwards compat; V7-aware queries should consume
    /// `is_codegen`.
    var isTest: Bool = false
    var isCodegen: Bool = false
    var isSampleApp: Bool = false
    var isMock: Bool = false

    var generics: String?
    var typeText: String?
    var typeSig: String?
    var extending: String?

    /// V7 §6.2: protocol-conformance edges (name-keyed). Lists every name in
    /// this record's inheritance clause. For `struct Foo: Bar, Baz`, this is
    /// `["Bar", "Baz"]`. For `protocol B: A`, this is `["A"]`. For records
    /// whose declaration form doesn't admit an inheritance clause (typealiases),
    /// this stays `nil` (and is omitted from JSON).
    ///
    /// For classes, the FIRST entry MAY be a parent class rather than a
    /// protocol — SwiftSyntax doesn't distinguish "class name" from "protocol
    /// name" at the syntax layer. Downstream consumers that need the class-
    /// inheritance edge specifically should treat the first entry of a class's
    /// `conforms_to` as ambiguous (parent class XOR first protocol). The
    /// dedicated class-inheritance enrichment is V7 §6.3 round 2 scope.
    var conformsTo: [String]?

    /// V7 §6.3: marker for catalog entries whose `fields`/`fields_structured`
    /// have been augmented by a post-pass resolution. Currently the only
    /// resolution kind on the Swift extractor is `"protocol-inheritance"` —
    /// child protocols whose parents' fields have been unioned in by
    /// `resolveProtocolInheritance`. Stays `nil` for records that weren't
    /// touched by any resolution pass (so the JSON omits the field).
    ///
    /// The TypeScript extractor uses `"intersection"` for its own resolution
    /// pass (V5 intersection-type field union); the two markers share this
    /// field's namespace but never appear on the same record — the kinds are
    /// disjoint (intersections are `type-alias-intersection`, protocols are
    /// `interface`).
    var resolvedFrom: String?

    /// V7 §6.3: the list of in-catalog protocol parent names whose declarations
    /// contributed at least one new field to this record's resolved field set.
    /// Set on the same records that carry `resolved_from: "protocol-inheritance"`.
    /// Transitive — if `C: B` and `B: A`, then C's `inherited_from` includes
    /// both `B` and `A` after the fixed-point pass converges.
    ///
    /// "Contributed" is load-bearing: a parent whose declared fields are
    /// entirely shadowed by the child's same-named declarations does NOT
    /// appear in `inherited_from` (no field crossed from parent to child).
    /// For the full set of declared direct parents — including shadowed ones —
    /// consult `conforms_to[]` instead.
    ///
    /// Names are kept verbatim, matching the `conforms_to` convention.
    /// Inheritance edges that point at protocols outside the scanned roots
    /// (external SDK protocols like `Codable`) don't contribute to
    /// `inherited_from` — only in-catalog resolutions appear.
    var inheritedFrom: [String]?
}

struct FunctionRecord: Encodable {
    var name: String
    var kind: String
    var package: String
    var file: String
    var line: Int
    var generated: Bool
    var exported: Bool
    var async: Bool
    var paramCount: Int
    var paramNames: [String]
    var bodyLineCount: Int
    var bodyLength: Int
    var bodyHash: String
    var bodyLines: [String]

    /// V7 §6.4: hash of the normalized body with every `IdentifierTypeSyntax`
    /// token replaced by `_T1`, `_T2`, ... in order of first appearance in the
    /// body. Two functions that differ only at type-identifier slots collide
    /// here while their `bodyHash` values stay distinct.
    var bodyHashErased: String

    /// V7 §6.4: sorted-unique normalized lines of the type-erased body. Mirrors
    /// `bodyLines` shape so the same Jaccard pipeline can run against the
    /// erased form.
    var bodyLinesErased: [String]

    /// V7 §6.6 context flags (#44). Same shape as `TypeRecord`'s — see the
    /// docstring there. For function records, `is_mock` checks the
    /// containing-type name (e.g., `FooMock.bar` → is_mock if `FooMock` ends
    /// with Mock); free functions fall back to the function name itself.
    var isTest: Bool = false
    var isCodegen: Bool = false
    var isSampleApp: Bool = false
    var isMock: Bool = false
}

let catalogJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

func sha256Hex(_ s: String) -> String {
    let digest = SHA256.hash(data: Data(s.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

/// Normalize a function body's text for hashing and Jaccard-pairwise comparison.
/// Strips block comments, line comments, collapses whitespace, drops blank lines.
/// Returns sorted-unique lines (for Jaccard sets), the joined body's sha256, and the joined length.
func normalizeBody(_ text: String) -> (lines: [String], hash: String, length: Int) {
    var stripped = text
    while let range = stripped.range(of: #"/\*[\s\S]*?\*/"#, options: .regularExpression) {
        stripped.removeSubrange(range)
    }

    let perLine = stripped.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        var s = String(line)
        if let r = s.range(of: "//") {
            s = String(s[s.startIndex..<r.lowerBound])
        }
        let collapsed = s.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespaces)
    }

    let nonEmpty = perLine.filter { !$0.isEmpty }
    let sortedUnique = Array(Set(nonEmpty)).sorted()
    let joined = sortedUnique.joined(separator: "\n")
    return (lines: sortedUnique, hash: sha256Hex(joined), length: joined.count)
}

/// V7 §6.4. Rewrites a syntax subtree, replacing every `IdentifierTypeSyntax`
/// token's name with a placeholder `_T1`, `_T2`, ... in order of first
/// appearance, then returns the resulting source text via `.description`.
///
/// Used to erase type identifiers from a function body before normalization,
/// so two bodies that differ only at type slots normalize to the same string.
/// The placeholder assignment walks parents before children (depth-first
/// pre-order), so `Array<UIColor>` erases to `_T1<_T2>` (not `_T2<_T1>`).
///
/// Scope: only `IdentifierTypeSyntax` is rewritten. Qualified type forms
/// (`MemberTypeSyntax`, e.g. `Swift.Int`) have an `IdentifierTypeSyntax`
/// base node, which gets erased; the trailing member token does not.
/// Expression-position references (`DeclReferenceExprSyntax` for `UIColor`
/// in `UIColor.red`) are also not rewritten — the methodology scopes erasure
/// to type-position identifiers only.
func eraseTypeIdentifiers<S: SyntaxProtocol>(_ node: S) -> String {
    let rewriter = TypeIdentifierEraser()
    let rewritten = rewriter.rewrite(Syntax(node))
    return rewritten.description
}

private final class TypeIdentifierEraser: SyntaxRewriter {
    private var mapping: [String: String] = [:]
    private var counter: Int = 0

    override func visit(_ node: IdentifierTypeSyntax) -> TypeSyntax {
        let name = node.name.text
        if mapping[name] == nil {
            counter += 1
            mapping[name] = "_T\(counter)"
        }
        let placeholder = mapping[name]!
        // Preserve the original token's leading/trailing trivia so the erased
        // body keeps the same surrounding whitespace as the source. Without
        // this, `let a: Int = 1` erases to `let a: _T1= 1` (no space before
        // `=`) because `Int`'s trailing space lives on the token, not on a
        // structural separator — and `body_lines_erased` would no longer be
        // faithful to the documented "same normalization on the erased body."
        let renamed = node.with(\.name, .identifier(
            placeholder,
            leadingTrivia: node.name.leadingTrivia,
            trailingTrivia: node.name.trailingTrivia
        ))
        // Recurse into children (e.g., generic-argument clause) so nested
        // identifiers also get placeholders, with first-appearance order
        // counted from the now-renamed outer node.
        return super.visit(renamed)
    }
}

/// Format a "name:Type" field entry the way the TS extractor does, then sort
/// the whole array alphabetically. The `shape_sig` is the sorted fields joined
/// by '|' and lowercased.
func shapeSig(of fields: [String]) -> String {
    fields.sorted().joined(separator: "|").lowercased()
}

func writeJSON<T: Encodable>(_ value: T, to output: String?) throws {
    let data = try catalogJSONEncoder.encode(value)
    if let path = output {
        try data.write(to: URL(fileURLWithPath: path))
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
    }
}

func logErr(_ message: String) {
    if let data = (message + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}
