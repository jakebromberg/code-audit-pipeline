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

/// One declared associated type on a protocol (issue #320, shape settled in
/// #321's joint decision). `{name, constraints}` is the shape already
/// ratified in docs/pipeline-contract-v2-fixtures.jsonl for
/// `language_data.swift.associated_types`; `primary` is added as a superset
/// field rather than a redefinition, so that fixture stays valid.
///
/// `constraints` comes from `AssociatedTypeDeclSyntax.inheritanceClause`
/// only — sorted, deduped, `[]` when the clause is absent. A `where` clause
/// requirement is a different kind of statement from a conformance bound and
/// is deliberately NOT folded in here. A composition bound is split into its
/// elements, so `Codable & Sendable` and `Codable, Sendable` agree. `primary`
/// is true when the name appears in
/// `ProtocolDeclSyntax.primaryAssociatedTypeClause` — including when it is
/// inherited rather than declared as a member here, which Swift permits
/// (`protocol Child<Element>: Parent {}`); such a name is emitted with empty
/// `constraints`, since its bound lives on the parent. One entry per distinct
/// name either way.
///
/// Deliberate recall gaps: default types (`associatedtype T = Int`) are not
/// captured, and associated types inherited from a protocol's own
/// conformances are not collected unless this protocol names them in its own
/// primary clause — the transitive closure is a query-side join over
/// `conforms_to`. See docs/pipeline-contract.md `associated_types`
/// for the full rationale.
struct AssociatedType: Encodable {
    var name: String
    var constraints: [String]
    var primary: Bool
}

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
    /// True when the member is a *computed* property — one whose accessor block
    /// declares a `get`/`set` (or `_read`/`_modify`/address) accessor — rather
    /// than stored state. Stored properties, including those with `willSet` /
    /// `didSet` observers, and enum cases and methods, are `false`. Consumers
    /// that reason about per-instance persisted state (e.g.
    /// `persistence-store-field-density.jq`) filter on this so derived
    /// properties do not inflate stored-property counts. Defaults to `false` so
    /// non-property construction sites (enum cases, methods) need no change.
    var isComputed: Bool = false
}

/// One type-catalog record. Mirrors the schema in
/// `docs/pipeline-contract.md` § "Type catalog".
///
/// **Heritage axes** (issue #217). `extends` carries the class-like
/// inheritance edges (Swift class superclass; TS interface extending
/// interface; TS intersection-type named operand). `conformsTo` carries
/// the protocol/interface-implementation edges (Swift `: Protocol`;
/// TS `class implements I`). When an inherited identifier is neither
/// in the curated CLASS_LIKE_INHERITED nor PROTOCOL_LIKE_INHERITED set,
/// the Swift extractor's `extractHeritageEdges` appends it to BOTH
/// arrays per the documented "default-both" rule — cluster queries
/// disambiguate by joining against the target's `kind` at query time.
///
/// Both arrays are sorted alphabetically and de-duplicated before
/// emission. Empty arrays still serialize (per the pipeline contract's
/// "required-on-every-row" rule). The kinds that admit no inheritance
/// clause syntactically (currently: `type-alias-other`, populated by
/// `TypeAliasDeclSyntax`) carry the array fields as nil so they don't
/// appear in the JSON.
///
/// `wrapsNotificationName` (issue #222) captures the identifier text
/// of a `Notification.Name` value wrapped by a type conforming to a
/// `*NotificationMessage` protocol (project-specific naming, or
/// Foundation's iOS 26 `NotificationCenter.MainActorMessage` /
/// `NotificationCenter.AsyncMessage`). The wrapper detector reads
/// the `static var name: Notification.Name { ... }` member's body as
/// text — string equality is the join key for the
/// notification-wrapper-grouping query.
struct TypeRecord: Encodable {
    var name: String
    var kind: String
    var package: String
    var file: String
    var line: Int
    var exported: Bool
    /// Access modifier **as written** (`public`, `open`, `package`,
    /// `internal`, `fileprivate`, `private`), defaulting to `"internal"` when
    /// the declaration carries none. This is a syntactic reading, not
    /// resolved effective visibility: a declaration nested in an
    /// access-modified extension inherits that extension's level in Swift
    /// (`public extension X { struct Y {} }` makes `Y` public), but carries
    /// no modifier of its own and so is reported `"internal"` here. See
    /// docs/pipeline-contract.md "access (type vs literal)" for the caveat
    /// and its consequence for `.access == "public"` filters.
    ///
    /// Unlike `LiteralRecord.access` (which describes an enclosing binding
    /// and is omitted where structurally inapplicable), every type
    /// declaration has *some* written-or-default visibility, so this field is
    /// always present.
    var access: String
    var generated: Bool
    var isTest: Bool
    var fields: [String]?
    var fieldsStructured: [FieldStructured]?
    var shapeSig: String?
    var touchedInWindow: Bool = false

    var generics: String?
    var typeText: String?
    var typeSig: String?
    // `extending` was the pre-#217 single-string field carrying an
    // extension's extended type. It's superseded by `extends` (plural,
    // sorted array). The value formerly stored here now lives as
    // `extends: [<extendedType>]` on extension records.
    var extends: [String]?
    var conformsTo: [String]?
    var wrapsNotificationName: String?
    /// Declared associated types (issue #320). Protocol rows (`kind ==
    /// "interface"`) ALWAYS carry this, `[]` when the protocol declares
    /// none; every other kind leaves it `nil` so it's omitted from the
    /// JSON. No hand-written `encode(to:)` is needed for this omission —
    /// unlike `FunctionRecord`, `TypeRecord`'s optionals are
    /// contract-sanctioned to omit on `nil`, and the compiler-synthesized
    /// `Encodable` already does that. See docs/pipeline-contract.md
    /// `associated_types` and the `access` (type vs literal) precedent this
    /// mirrors.
    var associatedTypes: [AssociatedType]?
}

/// Stdlib / SwiftUI / Apple-framework identifiers that, when appearing
/// in an inheritance clause on a struct / class / actor / enum / extension,
/// are unambiguously a SUPERCLASS edge — never a protocol conformance.
///
/// Intentionally narrow: only the high-frequency Apple-framework classes
/// that appear in heritage clauses. Anything outside this set falls
/// through to the "default-both" rule (appended to both `extends` and
/// `conforms_to`). Cluster queries disambiguate at query-time by joining
/// against the target's `kind` in the catalog.
let CLASS_LIKE_INHERITED: Set<String> = [
    "NSObject",
    "UIView", "UIViewController", "UIControl", "UIResponder",
    "UIWindow", "UITableViewCell", "UICollectionViewCell",
    "NSView", "NSViewController", "NSResponder", "NSWindow",
    "CALayer",
    "Operation", "Thread",
]

/// Stdlib / SwiftUI / Foundation protocol identifiers that, when
/// appearing in an inheritance clause, are unambiguously a CONFORMANCE
/// edge — never a superclass.
///
/// This set is intentionally narrow (precision over recall). Adding a
/// name here means "we are confident this is always a protocol";
/// guessing wrong would put an actual superclass into `conforms_to` and
/// silently degrade the cluster queries. The default-both rule is the
/// safety net for anything we're not sure about.
let PROTOCOL_LIKE_INHERITED: Set<String> = [
    // Stdlib markers and common protocols
    "Equatable", "Hashable", "Comparable",
    "Codable", "Decodable", "Encodable",
    "Sendable", "AnyObject", "AnyActor",
    "CustomStringConvertible", "CustomDebugStringConvertible",
    "Error", "LocalizedError",
    "Identifiable", "RawRepresentable", "CaseIterable", "OptionSet",
    "Collection", "Sequence", "IteratorProtocol",
    "BidirectionalCollection", "RandomAccessCollection",
    "MutableCollection", "RangeReplaceableCollection",
    "AsyncSequence", "AsyncIteratorProtocol",
    "Observable", "ObservableObject",
    "ExpressibleByStringLiteral", "ExpressibleByIntegerLiteral",
    "ExpressibleByArrayLiteral", "ExpressibleByDictionaryLiteral",
    "ExpressibleByNilLiteral", "ExpressibleByBooleanLiteral",
    "ExpressibleByFloatLiteral", "ExpressibleByStringInterpolation",
    "Numeric", "BinaryInteger", "BinaryFloatingPoint", "FloatingPoint",
    "FixedWidthInteger", "SignedInteger", "UnsignedInteger",
    "Strideable",
    // SwiftUI
    "View", "App", "Scene", "ViewModifier",
    "PreviewProvider", "EnvironmentKey", "PreferenceKey",
    "Shape", "InsettableShape", "LayoutValueKey",
    "Animatable", "DynamicProperty",
    "ToolbarContent", "Commands", "Gesture", "ButtonStyle",
    "LabelStyle", "TextFieldStyle", "ToggleStyle", "PickerStyle",
    // Combine
    "Publisher", "Subscriber", "Subscription", "Cancellable",
    // Foundation notification-wrapper protocols (iOS 26+)
    "NotificationCenter.MainActorMessage",
    "NotificationCenter.AsyncMessage",
]

struct FunctionRecord: Encodable {
    var name: String
    var kind: String
    var package: String
    var file: String
    var line: Int
    var generated: Bool
    var exported: Bool
    var isTest: Bool
    var async: Bool
    var paramCount: Int
    var paramNames: [String]
    /// Dotted nesting-stack qualification of the enclosing declaration,
    /// mirroring `LiteralRecord.enclosingType`; extensions push the extended
    /// type's text. `nil` for free functions.
    var enclosingType: String?
    /// Body-level fields. `nil` below `--min-body-lines` — the row is still
    /// emitted so signature-level data is available for one-liner functions.
    /// See docs/pipeline-contract.md "Body-fields gating".
    var bodyLineCount: Int?
    var bodyLength: Int?
    var bodyHash: String?
    var bodyLines: [String]?

    /// Hand-written `encode(to:)`: Swift's compiler-synthesized `Encodable`
    /// emits `encodeIfPresent` for `Optional` properties, which OMITS the key
    /// entirely for `nil` rather than encoding JSON `null`. That collides with
    /// this catalog's key-omission convention for form-inapplicable fields
    /// (e.g. `LiteralRecord`'s binding-vs-argument fields) — `enclosing_type`
    /// and the four body-level fields are always *applicable* to every row,
    /// just sometimes below threshold, so they must always be present as an
    /// explicit `null` rather than absent. `has("body_hash")` must be `true`
    /// on every emitted row; only its *value* varies. `container.encode`
    /// (never `encodeIfPresent`) is what makes `Optional.none` serialize as
    /// `null` instead of a dropped key. `CodingKeys` mirrors the property
    /// names verbatim so `catalogJSONEncoder`'s `.convertToSnakeCase` key
    /// strategy still applies.
    enum CodingKeys: String, CodingKey {
        case name, kind, package, file, line, generated, exported, isTest, async
        case paramCount, paramNames, enclosingType
        case bodyLineCount, bodyLength, bodyHash, bodyLines
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(package, forKey: .package)
        try container.encode(file, forKey: .file)
        try container.encode(line, forKey: .line)
        try container.encode(generated, forKey: .generated)
        try container.encode(exported, forKey: .exported)
        try container.encode(isTest, forKey: .isTest)
        try container.encode(async, forKey: .async)
        try container.encode(paramCount, forKey: .paramCount)
        try container.encode(paramNames, forKey: .paramNames)
        try container.encode(enclosingType, forKey: .enclosingType)
        try container.encode(bodyLineCount, forKey: .bodyLineCount)
        try container.encode(bodyLength, forKey: .bodyLength)
        try container.encode(bodyHash, forKey: .bodyHash)
        try container.encode(bodyLines, forKey: .bodyLines)
    }
}

/// One literal-catalog record (occurrence catalog, not a declaration catalog —
/// no `name`/`kind`/`is_test`/`language`; see the contract's literal-catalog
/// section for the exemption rationale). `form` discriminates the two v1
/// emission positions: `"binding"` (a `let`/`var` initializer that is a bare
/// numeric literal, or a plain static string literal) carries
/// `bindingName`/`isStatic`/`access`; `"argument"` (a numeric literal passed
/// directly to a function call) carries `callee`/`argLabel`. Fields of the
/// other form stay nil and are omitted from the JSON. String literals emit in
/// the binding position only.
///
/// `value` is the literal verbatim as written (numeric prefix minus folded in:
/// `-4` not `4`; string values keep their surrounding quotes). `valueNorm` is
/// the join key: for numerics the cross-spelling normalization (underscores
/// stripped, hex/octal/binary re-based to decimal, floats trimmed of a trailing
/// `.0` and scientific notation expanded — so `6.0`, `0x6`, and `6` all
/// normalize to `"6"`); for strings the raw segment content with quotes
/// removed and no case-folding or escape decoding. `valueKind` is `"int"`,
/// `"float"`, or `"string"`. `line` is the literal's line, not the enclosing
/// declaration's.
struct LiteralRecord: Encodable {
    var value: String
    var valueNorm: String
    var valueKind: String
    var form: String
    var package: String
    var file: String
    var line: Int
    var generated: Bool
    var bindingName: String?
    var isStatic: Bool?
    var access: String?
    var callee: String?
    var argLabel: String?
    var enclosingType: String?
    var enclosingCallable: String?
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

/// Format a "name:Type" field entry the way the TS extractor does, then sort
/// the whole array alphabetically. The `shape_sig` is the sorted fields joined
/// by '|' and lowercased.
func shapeSig(of fields: [String]) -> String {
    fields.sorted().joined(separator: "|").lowercased()
}

/// Concatenated content of a string literal's segments, or nil if the literal
/// contains any interpolation (`\(…)`) — SwiftSyntax exposes an interpolated
/// segment as `ExpressionSegmentSyntax` rather than `StringSegmentSyntax`.
/// Escapes are preserved verbatim (`content.text` is the raw source, so `\t`
/// stays backslash-`t`). This does NOT distinguish single-line / multiline /
/// raw strings; callers that need those excluded must guard on the literal's
/// `openingQuote` / `openingPounds` before calling.
func staticStringContent(_ lit: StringLiteralExprSyntax) -> String? {
    var out = ""
    for segment in lit.segments {
        guard let seg = segment.as(StringSegmentSyntax.self) else { return nil }
        out.append(seg.content.text)
    }
    return out
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
