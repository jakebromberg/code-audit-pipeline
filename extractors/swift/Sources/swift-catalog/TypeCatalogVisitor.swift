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
            extending: nil
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
            extending: nil
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
            extending: nil
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
            extending: extended
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

    private func emitShapeBearing(
        simpleName: String,
        kind: String,
        position: AbsolutePosition,
        modifiers: DeclModifierListSyntax,
        generics: GenericParameterClauseSyntax?,
        members: MemberBlockSyntax,
        extending: String?,
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
        records.append(record)
    }

    private func emitEnum(_ node: EnumDeclSyntax) {
        let line = converter.location(for: node.positionAfterSkippingLeadingTrivia).line
        // `pairs` holds the lockstep flat/structured rendering for each case;
        // `caseTexts` retains the declaration-order spellings used to build
        // `typeText` (which is *not* sorted — it's the source-order summary).
        var pairs: [(flat: String, structured: FieldStructured)] = []
        var caseTexts: [String] = []
        for member in node.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                let caseName = element.name.text
                if let assoc = element.parameterClause {
                    let paramText = assoc.trimmedDescription
                    pairs.append((
                        flat: "\(caseName):\(paramText)",
                        structured: FieldStructured(
                            name: caseName, type: paramText, isOptional: false, isStatic: false)
                    ))
                    caseTexts.append("\(caseName)\(paramText)")
                } else if let raw = element.rawValue {
                    let rawText = raw.value.trimmedDescription
                    pairs.append((
                        flat: "\(caseName):=\(rawText)",
                        structured: FieldStructured(
                            name: caseName, type: "=\(rawText)", isOptional: false, isStatic: false)
                    ))
                    caseTexts.append("\(caseName)=\(rawText)")
                } else {
                    pairs.append((
                        flat: caseName,
                        structured: FieldStructured(
                            name: caseName, type: "", isOptional: false, isStatic: false)
                    ))
                    caseTexts.append(caseName)
                }
            }
        }
        let typeText = "case " + caseTexts.joined(separator: " | case ")
        // Sort pairs by the flat string so flat[i] and structured[i] refer to
        // the same case. Uses the same key as `extractFields` (`$0.flat`) so
        // the two emission paths share one lockstep contract.
        pairs.sort { $0.flat < $1.flat }
        let sortedFlat = pairs.map(\.flat)
        let sortedStructured = pairs.map(\.structured)
        var record = TypeRecord(
            name: qualify(node.name.text),
            kind: "type-alias-union",
            package: file.package,
            file: file.relativePath,
            line: line,
            exported: isExported(node.modifiers),
            generated: file.generated,
            fields: sortedFlat.isEmpty ? nil : sortedFlat,
            fieldsStructured: sortedStructured.isEmpty ? nil : sortedStructured,
            shapeSig: sortedFlat.isEmpty ? nil : shapeSig(of: sortedFlat)
        )
        record.typeText = typeText
        record.typeSig = normalizeTypeText(typeText)
        if let generics = node.genericParameterClause {
            record.generics = generics.parameters.map { $0.name.text }.joined(separator: ",")
        }
        records.append(record)
    }

    /// Both forms of the field set, returned together so emitShapeBearing can
    /// populate the flat (V6) `fields` and structured (V7 §6.1) `fields_structured`
    /// from a single walk over the member block. The pair is sorted by the
    /// flat string (`"name:type"`), so `flat[i]` and `structured[i]` always
    /// refer to the same member. `emitEnum` uses the same paired-sort idiom
    /// for the same lockstep guarantee on enum-case records, and the resulting
    /// `flat` ordering is V6-byte-equivalent to the pre-§6.1 `cases.sorted()`
    /// output.
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
    ///
    /// The qualified form requires `baseType` to spell as `Swift` so a
    /// user-defined `Foo.Optional<T>` nested type doesn't get mis-flagged.
    /// The bare-identifier form keeps the more permissive match (any type
    /// literally named `Optional`) — this is consistent with how Swift
    /// resolves an unqualified `Optional` reference at the type-checker
    /// level, and the false-positive surface is small.
    private func isOptionalType(_ type: TypeSyntax) -> Bool {
        if type.is(OptionalTypeSyntax.self) { return true }
        if type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) { return true }
        if let id = type.as(IdentifierTypeSyntax.self), id.name.text == "Optional" {
            return true
        }
        if let member = type.as(MemberTypeSyntax.self),
           member.name.text == "Optional",
           member.baseType.trimmedDescription == "Swift"
        {
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
