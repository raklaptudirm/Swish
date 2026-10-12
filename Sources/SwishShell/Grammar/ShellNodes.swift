@_spi(Layer) import Swiit
import Foundation
import SwiitKit

// The shell's syntax in the core's tree: each form is a node that checks
// itself, held in the tree as an extension (Language/Syntax/SyntaxExtension.swift),
// so the checker never names them; then `Desugarer` rewrites each into the
// Swift it means, which is what runs. The factory functions
// keep the parser's spelling, `.commands(chain)`, `.substitution(program)`.

// MARK: Expressions

/// `$name`: a Swish variable, falling back to the environment.
struct DollarExpr: ExprExtension, Equatable {
    var name: String
    /// What the checker found: a variable in scope, not the environment's.
    var isVariable = false

    mutating func check(in checker: TypeChecker, expecting expected: TypeAnnotation?) throws -> TypeAnnotation {
        if case .variable(let type, _)? = checker.lookup(name) {
            isVariable = true
            return type
        }
        return .string
    }

}

/// `$(…)`: the command's Output, whatever its status. Under `try`
/// (`throwing`), a non-zero status throws instead.
struct SubstitutionExpr: ExprExtension, Equatable {
    var program: Program
    var throwing: Bool

    mutating func check(in checker: TypeChecker, expecting expected: TypeAnnotation?) throws -> TypeAnnotation {
        if throwing { try checker.throwingSite("the command") }
        try checker.checkBlock(&program, newScope: true)
        return .output
    }

}

/// `async swift build` or `async $(curl …)`: starts it in the background.
struct AsyncExpr: ExprExtension, Equatable {
    enum Target: Equatable, Sendable {
        case command(PipelineNode)
        /// `async $(…)`: its output is kept, for `await` to give.
        case capture(PipelineNode)
        /// `async f(x)`, `async { … }`: Swish code as a task of its own,
        /// whose value `await` gives; `source` as it was written, for `jobs`.
        case task(Expr, source: String)
    }

    var target: Target

    mutating func check(in checker: TypeChecker, expecting expected: TypeAnnotation?) throws -> TypeAnnotation {
        switch target {
        case .command(var pipeline):
            try checker.checkPipeline(&pipeline)
            target = .command(pipeline)
        case .capture(var pipeline):
            try checker.checkPipeline(&pipeline)
            target = .capture(pipeline)
        case .task(var expr, let source):
            // It runs as a closure would: `await` may be written in it.
            let (type, _) = try checker.withEffects(allowsAwait: true) { () throws -> TypeAnnotation in
                // `async { … }`: what the closure gives.
                if case .closure = expr, case .functionType(_, let result, _, _) = try checker.typeOf(&expr) { return result }
                return try checker.typeOf(&expr)
            }
            target = .task(expr, source: source)
            return .generic("Job", [type])
        }
        return .named("Job")
    }

}

// MARK: Commands

/// Commands joined by `&&` and `||` (or one alone), with Swift between them
/// as in `x > 1 && echo big`: run left to right by exit status. A command is
/// a pipeline of them, `ls | sorted`, and may be fed a value, `xs | sorted`.
struct CommandChainExpr: ExprExtension, Equatable {
    enum Operand: Equatable, Sendable {
        case command(PipelineNode)
        case expression(Expr)
    }

    struct Link: Equatable, Sendable {
        var isAnd: Bool
        var operand: Operand
    }

    var first: Operand
    var links: [Link] = []
    /// An `if`, `guard` or `while` condition, which asks whether it held.
    var isCondition = false

    var operands: [Operand] { [first] + links.map(\.operand) }

    mutating func check(in checker: TypeChecker, expecting expected: TypeAnnotation?) throws -> TypeAnnotation {
        // An expression joined with commands is asked whether it held.
        let joined = !links.isEmpty || isCondition
        func check(_ operand: inout Operand) throws {
            switch operand {
            case .command(var node):
                try checker.checkPipeline(&node)
                operand = .command(node)
            case .expression(var expr):
                let type = try checker.typeOf(&expr)
                if joined {
                    // `try? build() && …`: whether it succeeded.
                    let attempted = if case .attempt(_, .optional) = expr { true } else { false }
                    switch type {
                    case .bool, .output, .unknown, .named("Status"): break
                    case .optional where attempted: break
                    default: throw TypeError("a condition must be a Bool, not \(type)")
                    }
                }
                operand = .expression(expr)
            }
        }
        try check(&first)
        for index in links.indices { try check(&links[index].operand) }
        return isCondition ? .bool : .named("Status")
    }

    /// `exit 1` ends the interpreter.
    var leavesProgram: Bool {
        guard links.isEmpty, case .command(let node) = first, node.commands.count == 1,
              case .text(let parts)? = node.commands[0].words.first else { return false }
        return parts == [.literal("exit")]
    }
}

// MARK: The parser's spelling, and reading them back

extension Expr {
    static func dollar(_ name: String) -> Expr { .extended(ExprExtensionBox(DollarExpr(name: name))) }

    static func substitution(_ program: Program, throwing: Bool = false) -> Expr {
        .extended(ExprExtensionBox(SubstitutionExpr(program: program, throwing: throwing)))
    }

    static func async(_ target: AsyncExpr.Target) -> Expr { .extended(ExprExtensionBox(AsyncExpr(target: target))) }

    /// `$name`'s name, if this is one.
    var dollarName: String? { (extensionNode as? DollarExpr)?.name }
    /// `$(…)`'s program and whether it throws, if this is one.
    var substitutionParts: (program: Program, throwing: Bool)? {
        (extensionNode as? SubstitutionExpr).map { ($0.program, $0.throwing) }
    }
    var asyncTarget: AsyncExpr.Target? { (extensionNode as? AsyncExpr)?.target }

    static func commands(_ chain: CommandChainExpr) -> Expr { .extended(ExprExtensionBox(chain)) }

    /// The one pipeline of commands this is, alone, if it is one.
    var pipelineNode: PipelineNode? {
        guard let chain = extensionNode as? CommandChainExpr, chain.links.isEmpty, case .command(let node) = chain.first else { return nil }
        return node
    }

    private var extensionNode: (any ExprExtension)? {
        if case .extended(let box) = self { box.node } else { nil }
    }
}

extension Interpreter {
    /// The shell this interpreter belongs to.
    var shell: Shell { owner as! Shell }
}
