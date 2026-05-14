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

final class TypeCatalogVisitor: SyntaxVisitor {
    let file: WalkedFile
    let converter: SourceLocationConverter
    var records: [TypeRecord] = []
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
            extending: nil,
            inheritanceClause: node.inheritanceClause
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
            extending: nil,
            inheritanceClause: node.inheritanceClause
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
            extending: nil,
            inheritanceClause: node.inheritanceClause
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
            extending: nil,
            inheritanceClause: node.inheritanceClause,
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
        emitShapeBearing(
            simpleName: extended,
            kind: "extension",
            position: node.positionAfterSkippingLeadingTrivia,
            modifiers: node.modifiers,
            generics: nil,
            members: node.memberBlock,
            extending: extended,
            inheritanceClause: node.inheritanceClause
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
        let qualified = qualify(node.name.text)
        var record = TypeRecord(
            name: qualified,
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
        applyContextFlags(to: &record, recordName: qualified)
        records.append(record)
        return .visitChildren
    }

    // MARK: - helpers

    private func qualify(_ name: String) -> String {
        nameStack.isEmpty ? name : "\(nameStack.joined(separator: ".")).\(name)"
    }

    /// V7 §6.6: propagate the WalkedFile's path-derived context flags to a
    /// TypeRecord, and OR the per-record `is_mock` with a name-suffix check.
    /// The name-suffix half catches `protocol FooMock { ... }` in a file
    /// that's not in a Mocks/ directory; the path half catches
    /// `Mocks/AuthClient.swift` whose record is named `AuthClient`. Both
    /// signals can fire independently — the agent cross-checks.
    private func applyContextFlags(to record: inout TypeRecord, recordName: String) {
        record.isTest = file.isTest
        record.isCodegen = file.isCodegen
        record.isSampleApp = file.isSampleApp
        record.isMock = file.isMockPath || nameEndsWithMockStubFakeSuffix(recordName)
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

    private func emitShapeBearing(
        simpleName: String,
        kind: String,
        position: AbsolutePosition,
        modifiers: DeclModifierListSyntax,
        generics: GenericParameterClauseSyntax?,
        members: MemberBlockSyntax,
        extending: String?,
        inheritanceClause: InheritanceClauseSyntax?,
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
        if let ext = extending {
            record.extending = ext
        }
        // V7 §6.2: always populate conforms_to (empty array for no-conformance
        // records). This distinguishes "the record genuinely has no conformances"
        // from "the catalog doesn't know" — typealiases, which never have an
        // inheritance clause, keep conformsTo nil and the JSON omits the field.
        record.conformsTo = inheritanceNames(of: inheritanceClause)
        applyContextFlags(to: &record, recordName: qualify(simpleName))
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
        // V7 §6.2: enum conformances. `enum Status: String, Codable` produces
        // ["String", "Codable"] — for raw-value enums, the first entry is the
        // raw-value type rather than a protocol, but the syntactic position is
        // indistinguishable from a leading protocol, so we emit the full list
        // unchanged (same caveat as classes carrying a parent-class slot in
        // their conformsTo[]).
        record.conformsTo = inheritanceNames(of: node.inheritanceClause)
        applyContextFlags(to: &record, recordName: qualify(node.name.text))
        records.append(record)
    }

    /// Extract the names from an inheritance clause. Returns `[]` for an
    /// inheritance clause that's present but empty (rare), and `[]` for the
    /// absent-but-applicable case (the record's declaration form admits an
    /// inheritance clause, but the source doesn't declare one). Returns the
    /// list of trimmed type-syntax descriptions otherwise — the substrate
    /// captures NAME-based edges; cross-catalog joins are downstream work.
    ///
    /// Names are kept verbatim from source — generic conformances like
    /// `Equatable` stay as `"Equatable"`, qualified protocol names like
    /// `Combine.Cancellable` stay qualified, and composed protocols like
    /// `Foo & Bar` (rare in inheritance clauses but legal) stay as written.
    /// The downstream consumer decides what to do with non-bare names.
    private func inheritanceNames(of clause: InheritanceClauseSyntax?) -> [String] {
        guard let clause else { return [] }
        return clause.inheritedTypes.map { $0.type.trimmedDescription }
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
