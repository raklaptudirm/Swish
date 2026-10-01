import Foundation
import SwishKit

// MARK: - AST

struct Program: Equatable, Sendable {
    var statements: [Statement]
    /// Each statement's line in the source, 1-based, for error messages.
    var lines: [Int] = []

    /// Programs are equal by what they say, wherever it was written.
    static func == (lhs: Program, rhs: Program) -> Bool {
        lhs.statements == rhs.statements
    }
}

enum Statement: Equatable, Sendable {
    case declare(name: String, mutable: Bool, value: Expr)
    /// `x = v`, `p.x += 1`, `xs[0] = v`.
    case assign(Assignment)
    case function(FunctionDecl)
    /// `env.NAME = value` or `env["NAME"] = value`; nil unsets it.
    case setEnvironment(name: Expr, value: Expr)
    /// `do { … } catch { … }`: a runtime error in the body runs the
    /// handler with `error` (or the name given) bound to it.
    case doCatch(body: Program, errorName: String, handler: Program?)
    case enumDecl(EnumDecl)
    case structDecl(StructDecl)
    /// `extension Sequence { func filter(…) … }`: the prelude's methods of
    /// every sequence.
    case extensionDecl(name: String, methods: [FunctionDecl])
    /// `import Tools from "./Tools"`: builds a Swift package and loads the
    /// functions it exports.
    case importPlugin(name: String, path: Expr)
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
    var declaresType: Bool {
        switch self {
        case .structDecl, .enumDecl: true
        default: false
        }
    }
}

/// Units joined by `&&`/`||`, evaluated left to right on exit status.
struct Chain: Equatable, Sendable {
    var first: Unit
    var links: [Link] = []
}

struct Link: Equatable, Sendable {
    var op: ChainOperator
    var unit: Unit
}

enum ChainOperator: Equatable, Sendable {
    case and, or
}

indirect enum Unit: Equatable, Sendable {
    case pipeline(PipelineNode)
    case expression(Expr)
    case ifStatement(IfStatement)
    case switchStatement(SwitchStatement)
    case forLoop(ForLoop)
    case whileLoop(WhileLoop)
}

struct IfStatement: Equatable, Sendable {
    enum Condition: Equatable, Sendable {
        case chain(Chain)
        /// `if let name = value`: runs the body with `name` bound when the
        /// value isn't nil.
        case binding(name: String, mutable: Bool, value: Expr)
        /// `if case .failed(let code) = result`.
        case pattern(Pattern, Expr)
    }

    var condition: Condition
    var then: Program
    var otherwise: Program?

    /// A branch of an `if` expression: the one expression it is, or an
    /// `else if`'s own `if` expression.
    static func branchExpression(_ branch: Program) -> Expr? {
        guard branch.statements.count == 1, case .chain(let chain) = branch.statements[0], chain.links.isEmpty else { return nil }
        switch chain.first {
        case .expression(let expr): return expr
        case .ifStatement(let node): return node.asExpression.map(Expr.ifExpression)
        default: return nil
        }
    }

    /// A branch that is `expr`.
    static func branch(_ expr: Expr) -> Program {
        Program(statements: [.chain(Chain(first: .expression(expr)))])
    }

    /// This `if` as an expression, when it can be one: with an `else`, and
    /// every branch one expression. `else if` branches become expressions too.
    var asExpression: IfStatement? {
        guard let otherwise, let thenExpr = IfStatement.branchExpression(then),
              let elseExpr = IfStatement.branchExpression(otherwise) else { return nil }
        return IfStatement(condition: condition, then: IfStatement.branch(thenExpr), otherwise: IfStatement.branch(elseExpr))
    }
}

/// `enum Name: RawType { case a, b(label: Type) = raw }`
struct EnumDecl: Equatable, Sendable {
    var name: String
    var rawType: TypeAnnotation?
    var cases: [EnumCaseDecl]
    /// `enum Level: Int, Comparable`: the protocols after any raw type.
    var conformances: [String] = []
}

struct EnumCaseDecl: Equatable, Sendable {
    var name: String
    var rawValue: Expr?
    var associated: [AssociatedValue]
}

struct AssociatedValue: Equatable, Sendable {
    var label: String?
    var type: TypeAnnotation
}

struct SwitchStatement: Equatable, Sendable {
    var subject: Expr
    var cases: [SwitchCase]
}

/// `case p1, p2 where guard: body`; no patterns is `default:`.
struct SwitchCase: Equatable, Sendable {
    var patterns: [Pattern]
    var guardExpr: Expr?
    var body: Program
}

indirect enum Pattern: Equatable, Sendable {
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

struct PatternArgument: Equatable, Sendable {
    var label: String?
    var pattern: Pattern
}

struct ForLoop: Equatable, Sendable {
    var variable: String
    var sequence: Expr
    var body: Program
}

struct WhileLoop: Equatable, Sendable {
    var condition: Chain
    var body: Program
}
