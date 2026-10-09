import Foundation
import SwishKit

// MARK: - AST

package struct Program: Equatable, Sendable {
    package var statements: [Statement]
    /// Each statement's line in the source, 1-based, for error messages.
    package var lines: [Int] = []

    /// Programs are equal by what they say, wherever it was written.
    package static func == (lhs: Program, rhs: Program) -> Bool {
        lhs.statements == rhs.statements
    }

    package init(statements: [Statement], lines: [Int] = []) {
        self.statements = statements
        self.lines = lines
    }
}

package enum Statement: Equatable, Sendable {
    case declare(name: String, mutable: Bool, value: Expr)
    /// `x = v`, `p.x += 1`, `xs[0] = v`.
    case assign(Assignment)
    case function(FunctionDecl)
    /// `do { … } catch { … }`: a runtime error in the body runs the
    /// handler with `error` (or the name given) bound to it.
    case doCatch(body: Program, errorName: String, handler: Program?)
    case enumDecl(EnumDecl)
    case structDecl(StructDecl)
    /// `extension Sequence { func filter(…) … }`: the prelude's methods of
    /// every sequence.
    case extensionDecl(name: String, methods: [FunctionDecl])
    /// Syntax a layer over the core adds: the shell's `env.NAME = value` and
    /// `import Tools from "./Tools"` (Syntax/SyntaxExtension.swift).
    case extended(StatementExtensionBox)
    /// `defer { … }`: runs when the block it's in ends, however it ends,
    /// last deferred first. At a script's top level, when the script ends.
    case deferBlock(Program)
    /// Carries on into the next case of a switch.
    case fallthroughStatement
    case returnStatement(Expr?)
    /// `guard let x = y else { return }`: unless the condition holds, runs
    /// the `else`, which must leave the block; what it binds stays bound
    /// for the rest of the block.
    case guardStatement(IfStatement.Condition, otherwise: Program)
    case breakStatement
    case continueStatement
    case chain(Chain)
}

extension Statement {
    /// A struct or enum declaration, which a block declares before it runs.
    package var declaresType: Bool {
        switch self {
        case .structDecl, .enumDecl: true
        default: false
        }
    }
}

/// Units joined by `&&`/`||`, evaluated left to right on exit status.
package struct Chain: Equatable, Sendable {
    package var first: Unit
    package var links: [Link] = []

    package init(first: Unit, links: [Link] = []) {
        self.first = first
        self.links = links
    }
}

package struct Link: Equatable, Sendable {
    package var op: ChainOperator
    package var unit: Unit

    package init(op: ChainOperator, unit: Unit) {
        self.op = op
        self.unit = unit
    }
}

package enum ChainOperator: Equatable, Sendable {
    case and, or
}

package indirect enum Unit: Equatable, Sendable {
    /// A command or pipeline of them, from a layer over the core.
    case extended(UnitExtensionBox)
    case expression(Expr)
    case ifStatement(IfStatement)
    case switchStatement(SwitchStatement)
    case forLoop(ForLoop)
    case whileLoop(WhileLoop)
}

package struct IfStatement: Equatable, Sendable {
    package enum Condition: Equatable, Sendable {
        case chain(Chain)
        /// `if let name = value`: runs the body with `name` bound when the
        /// value isn't nil.
        case binding(name: String, mutable: Bool, value: Expr)
        /// `if case .failed(let code) = result`.
        case pattern(Pattern, Expr)
    }

    package var condition: Condition
    package var then: Program
    package var otherwise: Program?

    /// A branch of an `if` expression: the one expression it is, or an
    /// `else if`'s own `if` expression.
    package static func branchExpression(_ branch: Program) -> Expr? {
        guard branch.statements.count == 1, case .chain(let chain) = branch.statements[0], chain.links.isEmpty else { return nil }
        switch chain.first {
        case .expression(let expr): return expr
        case .ifStatement(let node): return node.asExpression.map(Expr.ifExpression)
        default: return nil
        }
    }

    /// A branch that is `expr`.
    package static func branch(_ expr: Expr) -> Program {
        Program(statements: [.chain(Chain(first: .expression(expr)))])
    }

    /// This `if` as an expression, when it can be one: with an `else`, and
    /// every branch one expression. `else if` branches become expressions too.
    package var asExpression: IfStatement? {
        guard let otherwise, let thenExpr = IfStatement.branchExpression(then),
              let elseExpr = IfStatement.branchExpression(otherwise) else { return nil }
        return IfStatement(condition: condition, then: IfStatement.branch(thenExpr), otherwise: IfStatement.branch(elseExpr))
    }

    package init(condition: Condition, then: Program, otherwise: Program? = nil) {
        self.condition = condition
        self.then = then
        self.otherwise = otherwise
    }
}

/// `enum Name: RawType { case a, b(label: Type) = raw }`
package struct EnumDecl: Equatable, Sendable {
    package var name: String
    package var rawType: TypeAnnotation?
    package var cases: [EnumCaseDecl]
    /// `enum Level: Int, Comparable`: the protocols after any raw type.
    package var conformances: [String] = []

    package init(name: String, rawType: TypeAnnotation? = nil, cases: [EnumCaseDecl], conformances: [String] = []) {
        self.name = name
        self.rawType = rawType
        self.cases = cases
        self.conformances = conformances
    }
}

package struct EnumCaseDecl: Equatable, Sendable {
    package var name: String
    package var rawValue: Expr?
    package var associated: [AssociatedValue]

    package init(name: String, rawValue: Expr? = nil, associated: [AssociatedValue]) {
        self.name = name
        self.rawValue = rawValue
        self.associated = associated
    }
}

package struct AssociatedValue: Equatable, Sendable {
    package var label: String?
    package var type: TypeAnnotation

    package init(label: String? = nil, type: TypeAnnotation) {
        self.label = label
        self.type = type
    }
}

package struct SwitchStatement: Equatable, Sendable {
    package var subject: Expr
    package var cases: [SwitchCase]

    package init(subject: Expr, cases: [SwitchCase]) {
        self.subject = subject
        self.cases = cases
    }
}

/// `case p1, p2 where guard: body`; no patterns is `default:`.
package struct SwitchCase: Equatable, Sendable {
    package var patterns: [Pattern]
    package var guardExpr: Expr?
    package var body: Program

    package init(patterns: [Pattern], guardExpr: Expr? = nil, body: Program) {
        self.patterns = patterns
        self.guardExpr = guardExpr
        self.body = body
    }
}

package indirect enum Pattern: Equatable, Sendable {
    /// `_`
    case wildcard
    /// `let x`: matches anything, binding it.
    case binding(name: String, mutable: Bool)
    /// `.failed(code: let c)`, or `Result.failed(…)`; nil arguments match
    /// whatever associated values the case has.
    case enumCase(type: String?, name: String, arguments: [PatternArgument]?)
    /// A value to compare with, or a range to be in: `3`, `"a"`, `1...9`.
    case expression(Expr)
}

package struct PatternArgument: Equatable, Sendable {
    package var label: String?
    package var pattern: Pattern

    package init(label: String? = nil, pattern: Pattern) {
        self.label = label
        self.pattern = pattern
    }
}

package struct ForLoop: Equatable, Sendable {
    package var variable: String
    package var sequence: Expr
    package var body: Program

    package init(variable: String, sequence: Expr, body: Program) {
        self.variable = variable
        self.sequence = sequence
        self.body = body
    }
}

package struct WhileLoop: Equatable, Sendable {
    package var condition: Chain
    package var body: Program

    package init(condition: Chain, body: Program) {
        self.condition = condition
        self.body = body
    }
}
