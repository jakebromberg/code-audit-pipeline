//
//  TypeCatalogVisitor.swift
//  swift-catalog
//
//  Walks a SwiftSyntax tree and emits TypeRecord entries for struct/class/protocol/
//  enum/extension/typealias/actor declarations. Fields are the type's stored or
//  computed members; protocols include property + method signatures.
//

import Foundation
import SwiftSyntax

/// Discriminator for the kind of declaration whose inheritance clause we're
/// extracting. The split matters in two places: (1) protocol declarations
/// admit only protocol conformances in their heritage list (Swift forbids
/// a protocol inheriting from a concrete type), so we route the whole list
/// to `conformsTo`. (2) Other decl kinds use the curated CLASS_LIKE_INHERITED
/// vs PROTOCOL_LIKE_INHERITED partition with the default-both fallback.
///
/// Case names append `Decl` for cases that would otherwise collide with
/// Swift keywords (`enum`, `extension`, `protocol`). This mirrors the
/// SwiftSyntax node-type suffix convention (`EnumDeclSyntax`,
/// `ExtensionDeclSyntax`, `ProtocolDeclSyntax`) and keeps the mapping legible.
enum DeclaringKind {
    case structDecl, classDecl, actorDecl, enumDecl, extensionDecl, protocolDecl
}

final class TypeCatalogVisitor: SyntaxVisitor {
    let file: WalkedFile
    let converter: SourceLocationConverter
    var records: [TypeRecord] = []
    /// Tally of types emitted with a non-nil `wraps_notification_name` field.
    /// Surfaced in the type-subcommand stderr summary so an audit knows
    /// whether the detection pass found anything without grepping the JSON.
    var notificationWrappersDetected: Int = 0
    private var nameStack: [String] = []

    init(file: WalkedFile, tree: SourceFileSyntax) {
        self.file = file
        self.converter = SourceLocationConverter(fileName: file.relativePath, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - struct

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        emitShapeBearing(
            simpleName: node.name.text,
            kind: "type-alias-object",
            position: node.positionAfterSkippingLeadingTrivia,
            modifiers: node.modifiers,
            generics: node.genericParameterClause,
            members: node.memberBlock,
            inheritanceClause: node.inheritanceClause,
            declaringKind: .structDecl
        )
        nameStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: StructDeclSyntax) {
        nameStack.removeLast()
    }

    // MARK: - class

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        emitShapeBearing(
            simpleName: node.name.text,
            kind: "type-alias-object",
            position: node.positionAfterSkippingLeadingTrivia,
            modifiers: node.modifiers,
            generics: node.genericParameterClause,
            members: node.memberBlock,
            inheritanceClause: node.inheritanceClause,
            declaringKind: .classDecl
        )
        nameStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ClassDeclSyntax) {
        nameStack.removeLast()
    }

    // MARK: - actor

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        emitShapeBearing(
            simpleName: node.name.text,
            kind: "type-alias-object",
            position: node.positionAfterSkippingLeadingTrivia,
            modifiers: node.modifiers,
            generics: node.genericParameterClause,
            members: node.memberBlock,
            inheritanceClause: node.inheritanceClause,
            declaringKind: .actorDecl
        )
        nameStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ActorDeclSyntax) {
        nameStack.removeLast()
    }

    // MARK: - protocol

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        emitShapeBearing(
            simpleName: node.name.text,
            kind: "interface",
            position: node.positionAfterSkippingLeadingTrivia,
            modifiers: node.modifiers,
            generics: nil,
            members: node.memberBlock,
            inheritanceClause: node.inheritanceClause,
            declaringKind: .protocolDecl,
            includeMethodSignatures: true
        )
        nameStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: ProtocolDeclSyntax) {
        nameStack.removeLast()
    }

    // MARK: - enum

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        emitEnum(node)
        nameStack.append(node.name.text)
        return .visitChildren
    }

    override func visitPost(_ node: EnumDeclSyntax) {
        nameStack.removeLast()
    }

    // MARK: - extension

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        let extended = node.extendedType.trimmedDescription
        // Extensions record their extended type in `extends` (the extension
        // IS-A extension-of that type), independent of the inheritance clause.
        // The clause itself contributes only to `conformsTo` via the
        // `.extensionDecl` discriminator in extractHeritageEdges; the
        // extended-type name is injected by emitShapeBearing through
        // `extendedTypeForExtension`.
        emitShapeBearing(
            simpleName: extended,
            kind: "extension",
            position: node.positionAfterSkippingLeadingTrivia,
            modifiers: node.modifiers,
            generics: nil,
            members: node.memberBlock,
            inheritanceClause: node.inheritanceClause,
            declaringKind: .extensionDecl,
            extendedTypeForExtension: extended
        )
        nameStack.append(extended)
        return .visitChildren
    }

    override func visitPost(_ node: ExtensionDeclSyntax) {
        nameStack.removeLast()
    }

    // MARK: - typealias

    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind {
        let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        let typeText = node.initializer.value.trimmedDescription
        var record = TypeRecord(
            name: qualify(node.name.text),
            kind: "type-alias-other",
            package: file.package,
            file: file.relativePath,
            line: line,
            exported: isExported(node.modifiers),
            generated: file.generated,
            fields: nil,
            shapeSig: nil
        )
        record.typeText = typeText
        record.typeSig = normalizeTypeText(typeText)
        if let generics = node.genericParameterClause {
            record.generics = generics.parameters.map { $0.name.text }.joined(separator: ",")
        }
        // Typealiases admit no inheritance clause syntactically; extends and
        // conformsTo stay nil so the JSON omits the fields entirely. This
        // distinguishes "the record genuinely has no inheritance" (kinds that
        // can have an inheritance clause but don't declare one — emit `[]`)
        // from "the record's syntactic form admits no inheritance clause"
        // (typealiases — omit the field).
        records.append(record)
        return .visitChildren
    }

    // MARK: - helpers

    private func qualify(_ name: String) -> String {
        nameStack.isEmpty ? name : "\(nameStack.joined(separator: ".")).\(name)"
    }

    private func isExported(_ modifiers: DeclModifierListSyntax) -> Bool {
        for m in modifiers {
            switch m.name.text {
            case "public", "open", "package":
                return true
            case "private", "fileprivate":
                return false
            default:
                continue
            }
        }
        return true
    }

    /// Walk an inheritance clause and partition the inherited identifiers
    /// into supertype (`extends`) vs. protocol conformance (`conformsTo`).
    ///
    /// Routing rules:
    ///
    /// - `.protocolDecl`: Swift forbids a protocol from inheriting from a
    ///   concrete type, so every inherited identifier MUST be a protocol.
    ///   Whole list → `conformsTo`; `extends` stays empty.
    ///
    /// - `.extensionDecl`: The clause contains only conformances (the
    ///   extension's extended type is recorded separately by the caller).
    ///   Whole list → `conformsTo`; `extends` is populated by the caller
    ///   with the extended type's name.
    ///
    /// - struct / class / actor / enum: per-identifier dispatch against
    ///   the curated CLASS_LIKE_INHERITED and PROTOCOL_LIKE_INHERITED sets
    ///   in Common.swift. Identifiers in neither set fall through to the
    ///   "default-both" rule: appended to both `extends` and `conformsTo`
    ///   so cluster queries can disambiguate via the target's `kind` at
    ///   query time. (For enums, the first inherited identifier is the
    ///   raw-value type by Swift convention — `enum Status: String, Codable`
    ///   — and the syntactic position is indistinguishable from a leading
    ///   protocol. The curated PROTOCOL_LIKE_INHERITED set routes `Codable`
    ///   correctly; the default-both rule on `String` lands it in both
    ///   arrays, and the query-time `kind`-join sorts it out.)
    ///
    /// Both returned arrays are sorted lexicographically and de-duplicated.
    /// Empty input clause → ([], []).
    private func extractHeritageEdges(
        of clause: InheritanceClauseSyntax?,
        declaringKind kind: DeclaringKind
    ) -> (extends: [String], conformsTo: [String]) {
        guard let clause else { return ([], []) }
        let identifiers = clause.inheritedTypes.map { $0.type.trimmedDescription }

        switch kind {
        case .protocolDecl, .extensionDecl:
            // Whole list is conformance-only.
            let sorted = Array(Set(identifiers)).sorted()
            return ([], sorted)

        case .structDecl, .classDecl, .actorDecl, .enumDecl:
            var extends: Set<String> = []
            var conforms: Set<String> = []
            for id in identifiers {
                if CLASS_LIKE_INHERITED.contains(id) {
                    extends.insert(id)
                } else if PROTOCOL_LIKE_INHERITED.contains(id) {
                    conforms.insert(id)
                } else {
                    // Default-both: cluster queries disambiguate via the
                    // target's `kind` at query time.
                    extends.insert(id)
                    conforms.insert(id)
                }
            }
            return (extends.sorted(), conforms.sorted())
        }
    }

    private func emitShapeBearing(
        simpleName: String,
        kind: String,
        position: AbsolutePosition,
        modifiers: DeclModifierListSyntax,
        generics: GenericParameterClauseSyntax?,
        members: MemberBlockSyntax,
        inheritanceClause: InheritanceClauseSyntax?,
        declaringKind: DeclaringKind,
        extendedTypeForExtension: String? = nil,
        includeMethodSignatures: Bool = false
    ) {
        let line = converter.location(for: position).line
        let extracted = extractFields(members: members, includeMethods: includeMethodSignatures)
        var record = TypeRecord(
            name: qualify(simpleName),
            kind: kind,
            package: file.package,
            file: file.relativePath,
            line: line,
            exported: isExported(modifiers),
            generated: file.generated,
            fields: extracted.flat.isEmpty ? nil : extracted.flat,
            fieldsStructured: extracted.structured.isEmpty ? nil : extracted.structured,
            shapeSig: extracted.flat.isEmpty ? nil : shapeSig(of: extracted.flat)
        )
        if let g = generics {
            record.generics = g.parameters.map { $0.name.text }.joined(separator: ",")
        }
        let (extendsFromClause, conformsFromClause) =
            extractHeritageEdges(of: inheritanceClause, declaringKind: declaringKind)
        // For extensions, the extended type is injected into `extends`
        // alongside any clause-derived contributions (which extractHeritageEdges
        // has already emptied for the .extensionDecl path).
        if let extendedName = extendedTypeForExtension {
            record.extends = Array(Set([extendedName] + extendsFromClause)).sorted()
        } else {
            record.extends = extendsFromClause
        }
        record.conformsTo = conformsFromClause

        // Notification-wrapper detection (issue #222). Scan the member block
        // for a `static var name: Notification.Name { ... }` and record the
        // body expression text. Skipped on protocol decls — a protocol's own
        // requirement declaration doesn't WRAP a notification name, it just
        // requires that conformers do. ALSO requires that the type conforms
        // to a `*NotificationMessage` protocol (per pipeline-contract.md
        // "Notification-wrapper detection" and plans/issue-217-222 detection
        // rules); without this guard any type that happens to expose a
        // `static var name: Notification.Name { ... }` (model identifiers,
        // view IDs, etc.) gets falsely tagged and pollutes the
        // notification-wrapper-grouping cluster output.
        let conformsToNotificationMessage = conformsFromClause.contains { proto in
            proto.hasSuffix("NotificationMessage")
        }
        if declaringKind != .protocolDecl,
           conformsToNotificationMessage,
           let wrapName = extractNotificationName(from: members)
        {
            record.wrapsNotificationName = wrapName
            notificationWrappersDetected += 1
        }

        records.append(record)
    }

    private func emitEnum(_ node: EnumDeclSyntax) {
        let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        var cases: [String] = []
        var caseTexts: [String] = []
        var structured: [FieldStructured] = []
        for member in node.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                let caseName = element.name.text
                if let assoc = element.parameterClause {
                    let paramText = assoc.trimmedDescription
                    cases.append("\(caseName):\(paramText)")
                    caseTexts.append("\(caseName)\(paramText)")
                    structured.append(FieldStructured(
                        name: caseName, type: paramText, isOptional: false, isStatic: false))
                } else if let raw = element.rawValue {
                    let rawText = raw.value.trimmedDescription
                    cases.append("\(caseName):=\(rawText)")
                    caseTexts.append("\(caseName)=\(rawText)")
                    structured.append(FieldStructured(
                        name: caseName, type: "=\(rawText)", isOptional: false, isStatic: false))
                } else {
                    cases.append(caseName)
                    caseTexts.append(caseName)
                    structured.append(FieldStructured(
                        name: caseName, type: "", isOptional: false, isStatic: false))
                }
            }
        }
        let typeText = "case " + caseTexts.joined(separator: " | case ")
        // Sort flat and structured by name in lockstep so a downstream consumer
        // can zip them confidently.
        let sortedFlat = cases.sorted()
        let sortedStructured = structured.sorted { $0.name < $1.name }
        var record = TypeRecord(
            name: qualify(node.name.text),
            kind: "type-alias-union",
            package: file.package,
            file: file.relativePath,
            line: line,
            exported: isExported(node.modifiers),
            generated: file.generated,
            fields: cases.isEmpty ? nil : sortedFlat,
            fieldsStructured: cases.isEmpty ? nil : sortedStructured,
            shapeSig: cases.isEmpty ? nil : shapeSig(of: cases)
        )
        record.typeText = typeText
        record.typeSig = normalizeTypeText(typeText)
        if let generics = node.genericParameterClause {
            record.generics = generics.parameters.map { $0.name.text }.joined(separator: ",")
        }
        let (extendsFromClause, conformsFromClause) =
            extractHeritageEdges(of: node.inheritanceClause, declaringKind: .enumDecl)
        record.extends = extendsFromClause
        record.conformsTo = conformsFromClause
        records.append(record)
    }

    // MARK: - notification-wrapper detection

    /// Find a `static var name: Notification.Name { <expr> }` declaration in
    /// the given member block and return the body expression's text.
    ///
    /// Recognized patterns:
    ///
    ///   static var name: Notification.Name { someName }
    ///   static var name: Notification.Name { .someCaseName }
    ///   static var name: Notification.Name { return someName }
    ///   static var name: Notification.Name { get { someName } }
    ///   static var name: Notification.Name { AVPlayer.rateDidChangeNotification }
    ///
    /// Returns the body expression's verbatim text (e.g.,
    /// `"AVPlayer.rateDidChangeNotification"` or `".someCaseName"`). The
    /// notification-wrapper-grouping query joins by exact string equality —
    /// the convention is "both wrappers spell the name the same way."
    ///
    /// Returns nil if no matching declaration is found, or if the type
    /// annotation isn't recognizably `Notification.Name`, or if the body
    /// is more complex than a single expression / single-statement getter.
    private func extractNotificationName(from members: MemberBlockSyntax) -> String? {
        for member in members.members {
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { continue }
            guard hasStaticModifier(varDecl.modifiers) else { continue }
            for binding in varDecl.bindings {
                guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                      pattern.identifier.text == "name"
                else { continue }
                guard let typeAnnot = binding.typeAnnotation else { continue }
                let typeText = typeAnnot.type.trimmedDescription
                guard typeText == "Notification.Name" || typeText == "Foundation.Notification.Name"
                else { continue }
                // Body is a code block (getter): {…} or explicit-getter {get{…}}.
                guard let accessor = binding.accessorBlock else { continue }
                switch accessor.accessors {
                case .getter(let statements):
                    return extractSingleExpression(statements)
                case .accessors(let accessorList):
                    for acc in accessorList {
                        guard acc.accessorSpecifier.text == "get" else { continue }
                        guard let body = acc.body else { continue }
                        if let expr = extractSingleExpression(body.statements) {
                            return expr
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Extract a single expression's text from a getter's statement list.
    /// Handles the bare-expression form (`{ foo }`) and the `return foo` form.
    /// Multi-statement bodies aren't supported — the wrapper pattern is
    /// always a single-line getter in practice.
    private func extractSingleExpression(_ statements: CodeBlockItemListSyntax) -> String? {
        guard statements.count == 1, let first = statements.first else { return nil }
        switch first.item {
        case .expr(let expr):
            return expr.trimmedDescription
        case .stmt(let stmt):
            // Handle `return foo` form.
            if let ret = stmt.as(ReturnStmtSyntax.self), let expr = ret.expression {
                return expr.trimmedDescription
            }
            return nil
        case .decl:
            return nil
        }
    }

    /// Both forms of the field set, returned together so emitShapeBearing can
    /// populate the flat (V6) `fields` and structured (V7 §6.1) `fields_structured`
    /// from a single walk over the member block. The pair is sorted by the
    /// flat string (`"name:type"`), so `flat[i]` and `structured[i]` always
    /// refer to the same member. This matches V6's `cases.sorted()` ordering
    /// in `emitEnum`, so V6 byte-equivalence is preserved.
    private func extractFields(members: MemberBlockSyntax, includeMethods: Bool)
        -> (flat: [String], structured: [FieldStructured])
    {
        var pairs: [(flat: String, structured: FieldStructured)] = []
        for member in members.members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self) {
                let isStatic = hasStaticModifier(varDecl.modifiers)
                for binding in varDecl.bindings {
                    if let pair = fieldEntry(binding: binding, isStatic: isStatic) {
                        pairs.append(pair)
                    }
                }
            } else if includeMethods, let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
                pairs.append(methodSignatureField(funcDecl: funcDecl))
            }
        }
        // Sort the pair by the flat string (`"name:type"`) so flat[i] and
        // structured[i] refer to the same member. `shapeSig()` re-sorts flat
        // internally for hash stability, so the re-sort on already-sorted
        // input is a no-op and introduces no drift.
        pairs.sort { $0.flat < $1.flat }
        return (flat: pairs.map(\.flat), structured: pairs.map(\.structured))
    }

    private func fieldEntry(binding: PatternBindingSyntax, isStatic: Bool)
        -> (flat: String, structured: FieldStructured)?
    {
        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
        let name = pattern.identifier.text
        guard let typeAnnot = binding.typeAnnotation else { return nil }
        let typeText = normalizeFieldType(typeAnnot.type.trimmedDescription)
        let isOptional = isOptionalType(typeAnnot.type)
        return (
            flat: "\(name):\(typeText)",
            structured: FieldStructured(
                name: name, type: typeText, isOptional: isOptional, isStatic: isStatic)
        )
    }

    private func methodSignatureField(funcDecl: FunctionDeclSyntax)
        -> (flat: String, structured: FieldStructured)
    {
        let name = funcDecl.name.text
        let sig = normalizeFieldType(funcDecl.signature.trimmedDescription)
        let isStatic = hasStaticModifier(funcDecl.modifiers)
        // Methods aren't "optional" in the Swift sense — protocol requirements
        // can be marked `optional` only inside `@objc` protocols, which the
        // extractor doesn't yet special-case. For now methods are always
        // isOptional: false; future enrichment could add @objc-optional support.
        return (
            flat: "\(name):\(sig)",
            structured: FieldStructured(
                name: name, type: sig, isOptional: false, isStatic: isStatic)
        )
    }

    /// True if any modifier in the list is `static` or `class` (the Swift
    /// modifiers that mark a type-level rather than instance-level member).
    /// `class` is included because `class var foo` and `class func bar` are
    /// the Swift idiom for overridable type-level members on classes — they
    /// behave like `static` from an addressing standpoint.
    private func hasStaticModifier(_ modifiers: DeclModifierListSyntax) -> Bool {
        for m in modifiers {
            if m.name.text == "static" || m.name.text == "class" { return true }
        }
        return false
    }

    /// True if the SwiftSyntax type annotation is optional in any of its
    /// recognized forms: `T?` (OptionalTypeSyntax), `T!`
    /// (ImplicitlyUnwrappedOptionalTypeSyntax), the bare `Optional<T>`
    /// identifier form, or the qualified `Swift.Optional<T>` member form.
    /// The first two cover the syntactic sugar; the last two cover the rare
    /// explicit forms.
    private func isOptionalType(_ type: TypeSyntax) -> Bool {
        if type.is(OptionalTypeSyntax.self) { return true }
        if type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return true }
        if let id = type.as(IdentifierTypeSyntax.self), id.name.text == "Optional" {
            return true
        }
        if let member = type.as(MemberTypeSyntax.self), member.name.text == "Optional" {
            return true
        }
        return false
    }

    private func normalizeFieldType(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private func normalizeTypeText(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "").lowercased()
    }
}
