//
//  LiteralCatalogVisitor.swift
//  swift-catalog
//
//  Walks a SwiftSyntax tree and emits LiteralRecord entries for numeric
//  literals in the two v1 positions: `let`/`var` binding initializers and
//  function-call arguments. Everything else (enum raw values, return
//  statements, tuple elements, attribute arguments, string literals) is
//  deliberately out of scope — those positions are either already cataloged
//  elsewhere (raw values ride on the type catalog) or aren't copy-not-link
//  signal.
//

import Foundation
import SwiftSyntax

final class LiteralCatalogVisitor: SyntaxVisitor {
    let file: WalkedFile
    let converter: SourceLocationConverter
    var records: [LiteralRecord] = []
    private var nameStack: [String] = []
    private var callableStack: [String] = []
    // VariableDecls only push a callable when a binding has an accessor block
    // (computed property / observers); visitPost pops iff this decl pushed.
    private var callablePusherIds: Set<SyntaxIdentifier> = []

    init(file: WalkedFile, tree: SourceFileSyntax) {
        self.file = file
        self.converter = SourceLocationConverter(fileName: file.relativePath, tree: tree)
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

    // MARK: - callable-stack tracking

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        callableStack.append(node.name.text); return .visitChildren
    }
    override func visitPost(_ node: FunctionDeclSyntax) { callableStack.removeLast() }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        callableStack.append("init"); return .visitChildren
    }
    override func visitPost(_ node: InitializerDeclSyntax) { callableStack.removeLast() }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        callableStack.append("deinit"); return .visitChildren
    }
    override func visitPost(_ node: DeinitializerDeclSyntax) { callableStack.removeLast() }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        callableStack.append("subscript"); return .visitChildren
    }
    override func visitPost(_ node: SubscriptDeclSyntax) { callableStack.removeLast() }

    // MARK: - binding form

    override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
        // Emit initializer literals BEFORE pushing the callable so a stored
        // property with observers (`var x = 5 { didSet {...} }`) doesn't
        // record itself as its own enclosing callable.
        for binding in node.bindings {
            guard let initializer = binding.initializer,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                  let lit = numericLiteral(initializer.value) else { continue }
            records.append(LiteralRecord(
                value: lit.text,
                valueNorm: normalizeValue(text: lit.text, kind: lit.kind),
                valueKind: lit.kind,
                form: "binding",
                package: file.package,
                file: file.relativePath,
                line: converter.location(for: lit.position).line,
                generated: file.generated,
                bindingName: pattern.identifier.text,
                isStatic: isStatic(node.modifiers),
                access: accessLevel(node.modifiers),
                enclosingType: enclosingType(),
                enclosingCallable: callableStack.last
            ))
        }
        for binding in node.bindings {
            guard binding.accessorBlock != nil,
                  let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
            callableStack.append(pattern.identifier.text)
            callablePusherIds.insert(node.id)
            break
        }
        return .visitChildren
    }
    override func visitPost(_ node: VariableDeclSyntax) {
        if callablePusherIds.remove(node.id) != nil {
            callableStack.removeLast()
        }
    }

    // MARK: - argument form

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        guard let callee = calleeBaseName(node.calledExpression) else { return .visitChildren }
        for arg in node.arguments {
            guard let lit = numericLiteral(arg.expression) else { continue }
            records.append(LiteralRecord(
                value: lit.text,
                valueNorm: normalizeValue(text: lit.text, kind: lit.kind),
                valueKind: lit.kind,
                form: "argument",
                package: file.package,
                file: file.relativePath,
                line: converter.location(for: lit.position).line,
                generated: file.generated,
                callee: callee,
                argLabel: arg.label?.text,
                enclosingType: enclosingType(),
                enclosingCallable: callableStack.last
            ))
        }
        return .visitChildren
    }

    // MARK: - helpers

    private func enclosingType() -> String? {
        nameStack.isEmpty ? nil : nameStack.joined(separator: ".")
    }

    /// Base name of the called expression: `Spacer(...)` → "Spacer",
    /// `.padding(...)` / `view.padding(...)` → "padding",
    /// `Cache<Int>(...)` → "Cache". Anything else (closures, subscripts,
    /// optional-chained calls) returns nil and the call's arguments are
    /// not cataloged — a row without a callee has no cluster label.
    private func calleeBaseName(_ expr: ExprSyntax) -> String? {
        if let declRef = expr.as(DeclReferenceExprSyntax.self) {
            return declRef.baseName.text
        }
        if let member = expr.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        if let generic = expr.as(GenericSpecializationExprSyntax.self) {
            return calleeBaseName(generic.expression)
        }
        return nil
    }

    /// Match a bare numeric literal, folding one prefix minus into the text.
    /// Position is the literal's own (so `line` points at the value, not the
    /// enclosing declaration).
    private func numericLiteral(_ expr: ExprSyntax) -> (text: String, kind: String, position: AbsolutePosition)? {
        if let intLit = expr.as(IntegerLiteralExprSyntax.self) {
            return (intLit.literal.text, "int", intLit.positionAfterSkippingLeadingTrivia)
        }
        if let floatLit = expr.as(FloatLiteralExprSyntax.self) {
            return (floatLit.literal.text, "float", floatLit.positionAfterSkippingLeadingTrivia)
        }
        if let prefixOp = expr.as(PrefixOperatorExprSyntax.self),
           prefixOp.operator.text == "-",
           let inner = numericLiteral(prefixOp.expression) {
            return ("-" + inner.text, inner.kind, prefixOp.positionAfterSkippingLeadingTrivia)
        }
        return nil
    }

    /// Cross-spelling normalization (the copied-literal query's join key):
    /// strip `_` separators, re-base 0x/0o/0b integers to decimal, collapse
    /// integral floats (`6.0`, `1e3`) to their integer spelling, trim float
    /// trailing zeros (`0.50` → `0.5`). On unparseable input (e.g. an integer
    /// literal overflowing Int64) falls back to the stripped, lowercased text.
    private func normalizeValue(text: String, kind: String) -> String {
        let negative = text.hasPrefix("-")
        let sign = negative ? "-" : ""
        let magnitude = (negative ? String(text.dropFirst()) : text)
            .replacingOccurrences(of: "_", with: "")
        if kind == "int" {
            let lower = magnitude.lowercased()
            let radix: Int
            let digits: String
            if lower.hasPrefix("0x") {
                radix = 16; digits = String(lower.dropFirst(2))
            } else if lower.hasPrefix("0o") {
                radix = 8; digits = String(lower.dropFirst(2))
            } else if lower.hasPrefix("0b") {
                radix = 2; digits = String(lower.dropFirst(2))
            } else {
                radix = 10; digits = lower
            }
            guard let v = Int64(digits, radix: radix) else { return sign + lower }
            return sign + String(v)
        }
        guard let d = Double(magnitude) else { return sign + magnitude.lowercased() }
        if let i = Int64(exactly: d) {
            return sign + String(i)
        }
        return sign + String(d)
    }

    private func accessLevel(_ modifiers: DeclModifierListSyntax) -> String? {
        for m in modifiers {
            switch m.name.text {
            case "public", "open", "package", "internal", "fileprivate", "private":
                return m.name.text
            default:
                continue
            }
        }
        return nil
    }

    private func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.text == "static" || $0.name.text == "class" }
    }
}
