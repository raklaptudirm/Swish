import Foundation

// The shell's syntax in the core's tree: each form is a node that checks
// itself, held in the tree as a layer's node (Layer/LayerNode.swift), so the
// checker never names them; as each is checked, `Desugarer` rewrites it into
// the Swift it means, which is what runs. The factory functions
// keep the parser's spelling, `.commands(chain)`, `.substitution(program)`.

// MARK: Expressions

/// `$name`: a Swish variable, falling back to the environment.
struct DollarExpr: LayerNode {
    var name: String
    /// What the checker found: a variable in scope, not the environment's.
    var isVariable = false

    mutating func check(in context: CheckContext, expecting expected: ValueType?) throws -> ValueType {
        if case .variable(let type)? = context.lookup(name) {
            isVariable = true
            return type
        }
        return .string
    }
}

/// `$(…)`: the command's Output, whatever its status. Under `try`
/// (`throwing`), a non-zero status throws instead.
struct SubstitutionExpr: LayerNode {
    var program: SwiftBlock
    var throwing: Bool

    mutating func check(in context: CheckContext, expecting expected: ValueType?) throws -> ValueType {
        if throwing { try context.throwingSite("the command") }
        try context.check(&program, inNewScope: true)
        return .output
    }
}

/// `async swift build` or `async $(curl …)`: starts it in the background.
struct AsyncExpr: LayerNode {
    enum Target: Equatable, Sendable {
        case command(PipelineNode)
        /// `async $(…)`: its output is kept, for `await` to give.
        case capture(PipelineNode)
        /// `async f(x)`, `async { … }`: Swish code as a task of its own,
        /// whose value `await` gives; `source` as it was written, for `jobs`.
        case task(SwiftExpression, source: String)
    }

    var target: Target

    mutating func check(in context: CheckContext, expecting expected: ValueType?) throws -> ValueType {
        switch target {
        case .command(var pipeline):
            try context.checkPipeline(&pipeline)
            target = .command(pipeline)
        case .capture(var pipeline):
            try context.checkPipeline(&pipeline)
            target = .capture(pipeline)
        case .task(var expr, let source):
            // It runs as a closure would: `await` may be written in it.
            let type = try context.allowingAwait { () throws -> ValueType in
                // `async { … }`: what the closure gives.
                if expr.isClosure, let result = try context.typeOf(&expr).functionResult { return result }
                return try context.typeOf(&expr)
            }
            target = .task(expr, source: source)
            return .job(of: type)
        }
        return .job(of: nil)
    }
}

// MARK: Commands

/// Commands joined by `&&` and `||` (or one alone), with Swift between them
/// as in `x > 1 && echo big`: run left to right by exit status. A command is
/// a pipeline of them, `ls | sorted`, and may be fed a value, `xs | sorted`.
struct CommandChainExpr: LayerNode {
    enum Operand: Equatable, Sendable {
        case command(PipelineNode)
        case expression(SwiftExpression)
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

    mutating func check(in context: CheckContext, expecting expected: ValueType?) throws -> ValueType {
        // An expression joined with commands is asked whether it held.
        let joined = !links.isEmpty || isCondition
        func check(_ operand: inout Operand) throws {
            switch operand {
            case .command(var node):
                try context.checkPipeline(&node)
                operand = .command(node)
            case .expression(var expr):
                let type = try context.typeOf(&expr)
                if joined {
                    // `try? build() && …`: whether it succeeded.
                    let accepted = type == .bool || type == .output || type.isUnknown || type == .named("Status")
                    if !accepted && !(type.isOptional && expr.isOptionalAttempt) {
                        throw TypeFailure("a condition must be a Bool, not \(type)")
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

extension SwiftExpression {
    static func dollar(_ name: String) -> SwiftExpression { .node(DollarExpr(name: name)) }

    static func substitution(_ program: SwiftBlock, throwing: Bool = false) -> SwiftExpression {
        .node(SubstitutionExpr(program: program, throwing: throwing))
    }

    static func async(_ target: AsyncExpr.Target) -> SwiftExpression { .node(AsyncExpr(target: target)) }

    /// `$name`'s name, if this is one.
    var dollarName: String? { node(as: DollarExpr.self)?.name }
    /// `$(…)`'s program and whether it throws, if this is one.
    var substitutionParts: (program: SwiftBlock, throwing: Bool)? {
        node(as: SubstitutionExpr.self).map { ($0.program, $0.throwing) }
    }
    var asyncTarget: AsyncExpr.Target? { node(as: AsyncExpr.self)?.target }

    static func commands(_ chain: CommandChainExpr) -> SwiftExpression { .node(chain) }

    /// The one pipeline of commands this is, alone, if it is one.
    var pipelineNode: PipelineNode? {
        guard let chain = node(as: CommandChainExpr.self), chain.links.isEmpty, case .command(let node) = chain.first else { return nil }
        return node
    }
}

