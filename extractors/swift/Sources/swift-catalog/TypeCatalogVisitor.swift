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
        let fields = extractFields(members: members, includeMethods: includeMethodSignatures)
        var record = TypeRecord(
            name: qualify(simpleName),
            kind: kind,
            package: file.package,
            file: file.relativePath,
            line: line,
            exported: isExported(modifiers),
            generated: file.generated,
            fields: fields.isEmpty ? nil : fields,
            shapeSig: fields.isEmpty ? nil : shapeSig(of: fields)
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
        var cases: [String] = []
        var caseTexts: [String] = []
        for member in node.memberBlock.members {
            guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in caseDecl.elements {
                let caseName = element.name.text
                if let assoc = element.parameterClause {
                    let paramText = assoc.trimmedDescription
                    cases.append("\(caseName):\(paramText)")
                    caseTexts.append("\(caseName)\(paramText)")
                } else if let raw = element.rawValue {
                    let rawText = raw.value.trimmedDescription
                    cases.append("\(caseName):=\(rawText)")
                    caseTexts.append("\(caseName)=\(rawText)")
                } else {
                    cases.append(caseName)
                    caseTexts.append(caseName)
                }
            }
        }
        let typeText = "case " + caseTexts.joined(separator: " | case ")
        var record = TypeRecord(
            name: qualify(node.name.text),
            kind: "type-alias-union",
            package: file.package,
            file: file.relativePath,
            line: line,
            exported: isExported(node.modifiers),
            generated: file.generated,
            fields: cases.isEmpty ? nil : cases.sorted(),
            shapeSig: cases.isEmpty ? nil : shapeSig(of: cases)
        )
        record.typeText = typeText
        record.typeSig = normalizeTypeText(typeText)
        if let generics = node.genericParameterClause {
            record.generics = generics.parameters.map { $0.name.text }.joined(separator: ",")
        }
        records.append(record)
    }

    private func extractFields(members: MemberBlockSyntax, includeMethods: Bool) -> [String] {
        var fields: [String] = []
        for member in members.members {
            if let varDecl = member.decl.as(VariableDeclSyntax.self) {
                for binding in varDecl.bindings {
                    if let entry = fieldEntry(binding: binding) {
                        fields.append(entry)
                    }
                }
            } else if includeMethods, let funcDecl = member.decl.as(FunctionDeclSyntax.self) {
                fields.append(methodSignatureField(funcDecl: funcDecl))
            }
        }
        return fields.sorted()
    }

    private func fieldEntry(binding: PatternBindingSyntax) -> String? {
        guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { return nil }
        let name = pattern.identifier.text
        if let typeAnnot = binding.typeAnnotation {
            let typeText = normalizeFieldType(typeAnnot.type.trimmedDescription)
            return "\(name):\(typeText)"
        }
        return nil
    }

    private func methodSignatureField(funcDecl: FunctionDeclSyntax) -> String {
        let name = funcDecl.name.text
        let sig = funcDecl.signature.trimmedDescription
        return "\(name):\(normalizeFieldType(sig))"
    }

    private func normalizeFieldType(_ text: String) -> String {
        text.replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private func normalizeTypeText(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "").lowercased()
    }
}
