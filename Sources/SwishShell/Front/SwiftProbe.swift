import Foundation
import SwiftParser
import SwiftSyntax

// Spike: what the shell asks of Swift's grammar, answered by SwiftParser's tree: where an expression ends, whether one is
// there at all, and which names the text around declares. The text is the shell's with Swift in it, so a probe reads a
// stretch of it as Swift and says how far Swift gets.

/// What a name refers to where the reader is, which decides the mode of a statement starting with it.
enum NameRole: Equatable, Sendable {
    case variable, function, type, member, staticMember
}

/// A name a tree declares, and where it can be read: a scope (a byte range) and the offset it is readable from.
struct NameDeclaration {
    var name: String
    var role: NameRole
    var scope: Range<Int>
    var from: Int
    /// A static member, readable only in the bodies of static members.
    var staticOnly = false
}

/// The names there are where a stretch of the text is: those the interpreter has, and those the text declares, each in its scope.
struct Names {
    var base: [String: NameRole]
    var declarations: [NameDeclaration] = []
    var staticBodies: [Range<Int>] = []
    /// How many parameters the closure a declared function takes has.
    var closureArities: [String: Int] = [:]

    init(roles: [String: NameRole]) { base = roles }

    func role(of name: String, at byte: Int? = nil) -> NameRole? {
        guard let byte else { return declarations.last { $0.name == name }?.role ?? base[name] }
        var best: NameDeclaration?
        for declaration in declarations where declaration.name == name && declaration.scope.contains(byte) && declaration.from <= byte {
            if declaration.staticOnly, !staticBodies.contains(where: { $0.contains(byte) && declaration.scope.contains($0.lowerBound) }) { continue }
            if let current = best {
                let narrower = declaration.scope.count < current.scope.count
                let later = declaration.scope.count == current.scope.count && declaration.from >= current.from
                if narrower || later { best = declaration }
            } else {
                best = declaration
            }
        }
        return best?.role ?? base[name]
    }

    /// The names as they are readable at a byte offset, with no scopes left to ask.
    func snapshot(atByte byte: Int) -> Names {
        var roles = base
        for name in Set(declarations.map(\.name)) {
            if let role = role(of: name, at: byte) { roles[name] = role }
        }
        var names = Names(roles: roles)
        names.closureArities = closureArities
        return names
    }

    /// These names with what a tree declares, in the tree's offsets.
    func adding(declaredIn tree: SourceFileSyntax) -> Names {
        let finder = DeclarationFinder(viewMode: .sourceAccurate)
        finder.walk(tree)
        var names = self
        names.declarations = finder.found
        names.staticBodies = finder.staticBodies
        names.closureArities.merge(finder.closureArities) { _, new in new }
        return names
    }
}

private final class DeclarationFinder: SyntaxVisitor {
    var found: [NameDeclaration] = []
    var staticBodies: [Range<Int>] = []
    var closureArities: [String: Int] = [:]

    private func range(_ node: some SyntaxProtocol) -> Range<Int> {
        node.positionAfterSkippingLeadingTrivia.utf8Offset..<node.endPositionBeforeTrailingTrivia.utf8Offset
    }

    /// The braces, closure, type body, case or file that holds a node.
    private func scope(around node: Syntax) -> Range<Int> {
        var current = node.parent
        while let candidate = current {
            if candidate.is(CodeBlockSyntax.self) || candidate.is(ClosureExprSyntax.self) || candidate.is(MemberBlockSyntax.self)
                || candidate.is(SwitchCaseSyntax.self) || candidate.is(SourceFileSyntax.self) {
                // A file's scope is all of it, trivia included.
                if candidate.is(SourceFileSyntax.self) { return 0..<Int.max }
                return range(candidate)
            }
            current = candidate.parent
        }
        return 0..<Int.max
    }

    private func declare(_ name: String, _ role: NameRole, in scope: Range<Int>, from: Int, staticOnly: Bool = false) {
        guard name != "_" else { return }
        found.append(NameDeclaration(name: name, role: role, scope: scope, from: from, staticOnly: staticOnly))
    }

    private func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { $0.name.tokenKind == .keyword(.static) || $0.name.tokenKind == .keyword(.class) }
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        let outer = scope(around: Syntax(node))
        let staticFunction = isStatic(node.modifiers)
        declare(node.name.text, .function, in: outer, from: outer.lowerBound, staticOnly: staticFunction)
        for parameter in node.signature.parameterClause.parameters {
            var type = parameter.type
            if let attributed = type.as(AttributedTypeSyntax.self) { type = attributed.baseType }
            if let function = type.as(FunctionTypeSyntax.self) { closureArities[node.name.text] = function.parameters.count; break }
        }
        if let body = node.body {
            if staticFunction { staticBodies.append(range(body)) }
            for parameter in node.signature.parameterClause.parameters {
                declare((parameter.secondName ?? parameter.firstName).text, .variable, in: range(body), from: range(body).lowerBound)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        if let body = node.body {
            for parameter in node.signature.parameterClause.parameters {
                declare((parameter.secondName ?? parameter.firstName).text, .variable, in: range(body), from: range(body).lowerBound)
            }
        }
        return .visitChildren
    }

    override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind {
        guard let signature = node.signature else { return .visitChildren }
        let whole = range(node)
        switch signature.parameterClause {
        case .simpleInput(let list)?:
            for parameter in list { declare(parameter.name.text, .variable, in: whole, from: whole.lowerBound) }
        case .parameterClause(let clause)?:
            for parameter in clause.parameters { declare((parameter.secondName ?? parameter.firstName).text, .variable, in: whole, from: whole.lowerBound) }
        case nil: break
        }
        return .visitChildren
    }

    override func visit(_ node: CatchClauseSyntax) -> SyntaxVisitorContinueKind {
        if node.catchItems.isEmpty { declare("error", .variable, in: range(node.body), from: range(node.body).lowerBound) }
        return .visitChildren
    }

    override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
        let name = node.identifier.text
        var current: Syntax? = node.parent
        while let candidate = current {
            if let binding = candidate.as(PatternBindingSyntax.self), let declaration = binding.parent?.parent?.as(VariableDeclSyntax.self) {
                let outer = scope(around: Syntax(declaration))
                if declaration.parent?.parent?.is(MemberBlockSyntax.self) == true || declaration.parent?.is(MemberBlockItemSyntax.self) == true {
                    let staticMember = isStatic(declaration.modifiers)
                    declare(name, staticMember ? .staticMember : .member, in: outer, from: outer.lowerBound, staticOnly: staticMember)
                    if staticMember { staticBodies.append(range(declaration)) }
                } else {
                    declare(name, .variable, in: outer, from: range(declaration).upperBound)
                }
                return .visitChildren
            }
            if candidate.is(OptionalBindingConditionSyntax.self) || candidate.is(MatchingPatternConditionSyntax.self) {
                var statement: Syntax? = candidate.parent
                while let owner = statement, !(owner.is(IfExprSyntax.self) || owner.is(GuardStmtSyntax.self) || owner.is(WhileStmtSyntax.self)) { statement = owner.parent }
                if let owner = statement {
                    if owner.is(GuardStmtSyntax.self) {
                        let outer = scope(around: owner)
                        declare(name, .variable, in: outer, from: range(owner).upperBound)
                    } else {
                        declare(name, .variable, in: range(owner), from: range(candidate).upperBound)
                    }
                }
                return .visitChildren
            }
            if let loop = candidate.as(ForStmtSyntax.self) {
                declare(name, .variable, in: range(loop.body), from: range(loop.body).lowerBound)
                return .visitChildren
            }
            if let item = candidate.as(SwitchCaseItemSyntax.self), let switchCase = item.parent?.parent?.as(SwitchCaseSyntax.self) {
                declare(name, .variable, in: range(switchCase), from: range(switchCase).lowerBound)
                return .visitChildren
            }
            if let item = candidate.as(CatchItemSyntax.self), let clause = item.parent?.parent?.as(CatchClauseSyntax.self) {
                declare(name, .variable, in: range(clause.body), from: range(clause.body).lowerBound)
                return .visitChildren
            }
            current = candidate.parent
        }
        return .visitChildren
    }

    private func declareType(_ name: String, _ node: some SyntaxProtocol) {
        let outer = scope(around: Syntax(node))
        declare(name, .type, in: outer, from: outer.lowerBound)
    }

    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { declareType(node.name.text, node); return .visitChildren }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { declareType(node.name.text, node); return .visitChildren }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { declareType(node.name.text, node); return .visitChildren }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { declareType(node.name.text, node); return .visitChildren }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { declareType(node.name.text, node); return .visitChildren }
    override func visit(_ node: TypeAliasDeclSyntax) -> SyntaxVisitorContinueKind { declareType(node.name.text, node); return .visitChildren }
    override func visit(_ node: GenericParameterSyntax) -> SyntaxVisitorContinueKind {
        var owner: Syntax? = node.parent
        while let candidate = owner, !candidate.is(DeclSyntax.self) { owner = candidate.parent }
        declare(node.name.text, .type, in: owner.map { range($0) } ?? 0..<Int.max, from: 0)
        return .visitChildren
    }
}

/// How far Swift reads from a position.
struct Probe {
    /// Where the expression ends (a character index into the text probed), when there is one.
    var end: Int
    /// Where the first thing is that is no Swift (the character index), when there is such a thing before `end`.
    var failure: Int?
}

enum SwiftProbe {
    /// The expression starting at `start`: where it ends, and where it stops being Swift. The expression stops before a
    /// single `|` (the shell's pipe) and, when `logical`, before `&&` and `||`.
    /// `text` has its substitutions blanked.
    static func expression(in text: Text, at start: Int, logical: Bool, names: Names, strictNames: Bool = true, inCondition: Bool = false) -> Probe {
        var tail = Array(text.chars[start...])
        if inCondition { tail = Lex.truncatingAtBlock(tail) }
        let rest = Text(Lex.blankingBlocks(tail))
        let tree = Parser.parse(source: rest.string)
        let names = names.snapshot(atByte: text.byteOf[start]).adding(declaredIn: tree)
        guard let first = tree.statements.first, case .expr(let expr) = first.item else {
            return Probe(end: 0, failure: 0)
        }
        var endByte = expr.endPositionBeforeTrailingTrivia.utf8Offset
        // A sequence of operands and operators, as SwiftParser leaves it unfolded: cut at the first operator that is the shell's.
        var sequenceOwner: ExprSyntax = expr
        if let attempt = expr.as(TryExprSyntax.self) { sequenceOwner = attempt.expression }
        if let sequence = sequenceOwner.as(SequenceExprSyntax.self) {
            let elements = Array(sequence.elements)
            for (index, element) in elements.enumerated() where index > 0 {
                guard let op = element.as(BinaryOperatorExprSyntax.self)?.operator.text else { continue }
                if op == "|" || (logical && (op == "&&" || op == "||")) {
                    endByte = elements[index - 1].endPositionBeforeTrailingTrivia.utf8Offset
                    break
                }
            }
        }
        let problems = Problems(names: names, limit: endByte, checkNames: strictNames)
        problems.walk(tree)
        // Statement-level tokens left over after the item are not the expression's.
        return Probe(end: rest.character(atByte: endByte) + start, failure: problems.first.map { rest.character(atByte: $0) + start })
    }

    /// Whether the text is a closure that names no parameters.
    static func isParameterlessClosure(_ source: String) -> Bool {
        let tree = Parser.parse(source: String(Lex.blankingSubstitutions(Array(source))))
        guard let first = tree.statements.first, case .expr(let expr) = first.item, let closure = expr.as(ClosureExprSyntax.self) else { return false }
        return closure.signature == nil
    }

    /// Whether the text is the program of a Swift file with nothing wrong in it (for tests).
    static func parses(_ source: String) -> Bool { firstProblem(in: source) == nil }

    /// The source around the first thing wrong with it as Swift.
    static func firstProblem(in source: String) -> String? {
        let tree = Parser.parse(source: source)
        let problems = Problems(names: Names(roles: [:]), limit: Int.max, checkNames: false)
        problems.walk(tree)
        guard let offset = problems.first else { return nil }
        let bytes = Array(source.utf8)
        let from = max(0, offset - 40), to = min(bytes.count, offset + 40)
        return String(decoding: bytes[from..<to], as: UTF8.self)
    }
}

/// The first thing before `limit` (a byte offset) that SwiftParser is unhappy with or that names nothing.
private final class Problems: SyntaxVisitor {
    let names: Names
    let limit: Int
    let checkNames: Bool
    var first: Int?

    init(names: Names, limit: Int, checkNames: Bool = true) {
        self.names = names
        self.limit = limit
        self.checkNames = checkNames
        super.init(viewMode: .all)
    }

    private func note(_ offset: Int) {
        guard offset < limit else { return }
        first = min(first ?? offset, offset)
    }

    override func visit(_ node: UnexpectedNodesSyntax) -> SyntaxVisitorContinueKind {
        if !node.isEmpty { note(node.positionAfterSkippingLeadingTrivia.utf8Offset) }
        return .skipChildren
    }

    override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
        if token.presence == .missing { note(token.position.utf8Offset) }
        return .skipChildren
    }

    override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
        guard checkNames, node.argumentNames == nil else { return .visitChildren }
        // `count` in `xs.count` is a member's, not a name in scope.
        if let access = node.parent?.as(MemberAccessExprSyntax.self), access.declName.id == node.id { return .visitChildren }
        let token = node.baseName
        guard case .identifier = token.tokenKind else { return .visitChildren }
        let name = token.text
        let offset = token.positionAfterSkippingLeadingTrivia.utf8Offset
        if names.role(of: name, at: offset) == nil { note(offset) }
        return .visitChildren
    }
}
