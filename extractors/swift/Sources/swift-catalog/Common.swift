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

    var generics: String?
    var typeText: String?
    var typeSig: String?
    var extending: String?
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
        let renamed = node.with(\.name, .identifier(placeholder))
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
