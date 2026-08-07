//
//  FunctionCatalogVisitor.swift
//  swift-catalog
//
//  Walks a SwiftSyntax tree and emits FunctionRecord entries for func/method/
//  initializer/deinitializer/subscript/computed-property declarations. Every
//  declaration gets a row; bodies shorter than --min-body-lines (default 3)
//  emit with their body-level fields nulled rather than being dropped, so
//  signature-level queries (e.g. public-api-leaks) still see one-liners.
//

import Foundation
import SwiftSyntax

final class FunctionCatalogVisitor: SyntaxVisitor {
    let file: WalkedFile
    let converter: SourceLocationConverter
    let minBodyLines: Int
    var records: [FunctionRecord] = []
    private var nameStack: [String] = []

    init(file: WalkedFile, tree: SourceFileSyntax, minBodyLines: Int) {
        self.file = file
        self.converter = SourceLocationConverter(fileName: file.relativePath, tree: tree)
        self.minBodyLines = minBodyLines
        super.init(viewMode: .sourceAccurate)
    }

    // MARK: - type-decl name-stack tracking

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind {
        nameStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: StructDeclSyntax) { nameStack.removeLast() }

    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind {
        nameStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ClassDeclSyntax) { nameStack.removeLast() }

    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind {
        nameStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ActorDeclSyntax) { nameStack.removeLast() }

    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind {
        nameStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: EnumDeclSyntax) { nameStack.removeLast() }

    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind {
        nameStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: ProtocolDeclSyntax) { nameStack.removeLast() }

    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
        nameStack.append(node.extendedType.trimmedDescription); return .visitChildren
    }
    override func visitPost(_ node: ExtensionDeclSyntax) { nameStack.removeLast() }

    // MARK: - func

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let body = node.body else { return .visitChildren }
        let paramList = node.signature.parameterClause.parameters
        let paramNames = paramList.map { p -> String in
            let label = p.firstName.text
            return label.isEmpty ? "_" : label
        }
        emit(
            simpleName: node.name.text,
            kind: nameStack.isEmpty ? "function" : "method",
            position: node.positionAfterSkippingLeadingTrivia,
            modifiers: node.modifiers,
            isAsync: node.signature.effectSpecifiers?.asyncSpecifier != nil,
            paramNames: paramNames,
            body: body
        )
        return .visitChildren
    }

    // MARK: - init

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let body = node.body else { return .visitChildren }
        let paramList = node.signature.parameterClause.parameters
        let paramNames = paramList.map { p -> String in
            let label = p.firstName.text
            return label.isEmpty ? "_" : label
        }
        let labels = paramList.map { $0.firstName.text }.joined(separator: ":")
        let initName = labels.isEmpty ? "init" : "init(\(labels):)"
        emit(
            simpleName: initName,
            kind: "initializer",
            position: node.positionAfterSkippingLeadingTrivia,
            modifiers: node.modifiers,
            isAsync: node.signature.effectSpecifiers?.asyncSpecifier != nil,
            paramNames: paramNames,
            body: body
        )
        return .visitChildren
    }

    // MARK: - deinit

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let body = node.body else { return .visitChildren }
        emit(
            simpleName: "deinit",
            kind: "deinitializer",
            position: node.positionAfterSkippingLeadingTrivia,
            modifiers: node.modifiers,
            isAsync: false,
            paramNames: [],
            body: body
        )
        return .visitChildren
    }

    // MARK: - subscript

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        guard let accessors = node.accessorBlock else { return .visitChildren }
        let paramList = node.parameterClause.parameters
        let paramNames = paramList.map { p -> String in
            let label = p.firstName.text
            return label.isEmpty ? "_" : label
        }
        emitFromAccessorBlock(
            simpleName: "subscript",
            kind: "subscript",
            position: node.positionAfterSkippingLeadingTrivia,
            modifiers: node.modifiers,
            paramNames: paramNames,
            accessors: accessors
        )
        return .visitChildren
    }

    // MARK: - computed property (var x: T { get/set })

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        for binding in node.bindings {
            guard let accessors = binding.accessorBlock else { continue }
            guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            emitFromAccessorBlock(
                simpleName: pattern.identifier.text,
                kind: "computed-property",
                position: node.positionAfterSkippingLeadingTrivia,
                modifiers: node.modifiers,
                paramNames: [],
                accessors: accessors
            )
        }
        return .visitChildren
    }

    // MARK: - emit helpers

    private func emit(
        simpleName: String,
        kind: String,
        position: AbsolutePosition,
        modifiers: DeclModifierListSyntax,
        isAsync: Bool,
        paramNames: [String],
        body: CodeBlockSyntax
    ) {
        let bodyText = body.statements.description
        let normalized = normalizeBody(bodyText)
        let line = converter.location(for: position).line
        let qualified = nameStack.isEmpty ? simpleName : "\(nameStack.joined(separator: ".")).\(simpleName)"
        let enclosingType = nameStack.isEmpty ? nil : nameStack.joined(separator: ".")
        let meetsThreshold = normalized.lines.count >= minBodyLines
        records.append(FunctionRecord(
            name: qualified,
            kind: kind,
            package: file.package,
            file: file.relativePath,
            line: line,
            generated: file.generated,
            exported: isExported(modifiers),
            isTest: file.isTest,
            async: isAsync,
            paramCount: paramNames.count,
            paramNames: paramNames,
            enclosingType: enclosingType,
            bodyLineCount: meetsThreshold ? normalized.lines.count : nil,
            bodyLength: meetsThreshold ? normalized.length : nil,
            bodyHash: meetsThreshold ? normalized.hash : nil,
            bodyLines: meetsThreshold ? normalized.lines : nil
        ))
    }

    private func emitFromAccessorBlock(
        simpleName: String,
        kind: String,
        position: AbsolutePosition,
        modifiers: DeclModifierListSyntax,
        paramNames: [String],
        accessors: AccessorBlockSyntax
    ) {
        switch accessors.accessors {
        case .accessors(let list):
            for accessor in list {
                guard let body = accessor.body else { continue }
                let kindKey = accessor.accessorSpecifier.text
                let accessorName = "\(simpleName).\(kindKey)"
                emit(
                    simpleName: accessorName,
                    kind: kind,
                    position: accessor.positionAfterSkippingLeadingTrivia,
                    modifiers: modifiers,
                    isAsync: accessor.effectSpecifiers?.asyncSpecifier != nil,
                    paramNames: paramNames,
                    body: body
                )
            }
        case .getter(let getterBody):
            let line = converter.location(for: accessors.positionAfterSkippingLeadingTrivia).line
            let bodyText = getterBody.description
            let normalized = normalizeBody(bodyText)
            let qualified = nameStack.isEmpty ? simpleName : "\(nameStack.joined(separator: ".")).\(simpleName)"
            let enclosingType = nameStack.isEmpty ? nil : nameStack.joined(separator: ".")
            let meetsThreshold = normalized.lines.count >= minBodyLines
            records.append(FunctionRecord(
                name: qualified,
                kind: kind,
                package: file.package,
                file: file.relativePath,
                line: line,
                generated: file.generated,
                exported: isExported(modifiers),
                isTest: file.isTest,
                async: false,
                paramCount: paramNames.count,
                paramNames: paramNames,
                enclosingType: enclosingType,
                bodyLineCount: meetsThreshold ? normalized.lines.count : nil,
                bodyLength: meetsThreshold ? normalized.length : nil,
                bodyHash: meetsThreshold ? normalized.hash : nil,
                bodyLines: meetsThreshold ? normalized.lines : nil
            ))
        }
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
}
