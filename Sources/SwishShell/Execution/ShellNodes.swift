import SwishCore
import Foundation
import SwishKit

// The shell's syntax in the core's tree: each form is a node that checks and
// runs itself, held in the tree as an extension (Syntax/SyntaxExtension.swift),
// so the checker and the interpreter never name them. The factory functions
// keep the parser's spelling, `.pipeline(node)`, `.substitution(program)`.

// MARK: Expressions

/// `$name`: a Swish variable, falling back to the environment.
struct DollarExpr: ExprExtension, Equatable {
    var name: String

    mutating func check(in checker: TypeChecker, expecting expected: TypeAnnotation?) throws -> TypeAnnotation {
        if case .variable(let type, _)? = checker.lookup(name) { return type }
        return .string
    }

    func evaluate(in interpreter: Interpreter) throws -> Value {
        if let binding = interpreter.lookup(name) { return binding.value }
        if case .object(let environment as DynamicObject)? = interpreter.lookup("env")?.value,
           case .string(let value) = try environment.read(name) { return .string(value) }
        throw RuntimeError("no variable or environment variable named '\(name)'")
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

    func evaluate(in interpreter: Interpreter) throws -> Value {
        var status: Int32 = 0
        var text = try interpreter.shell.capturing { status = try interpreter.runBlock(program) }
        while text.last == "\n" { text.removeLast() }
        let (code, signal) = interpreter.exitCode(status)
        let output = Output(text: text, code: code, signal: signal)
        // Without `try`, failing is just what `.status` says.
        if throwing && status != 0 {
            throw RuntimeError("$(…) failed with status \(status)", status: status, output: output)
        }
        return .output(output)
    }
}

/// `async swift build` or `async $(curl …)`: starts it in the background.
struct AsyncExpr: ExprExtension, Equatable {
    enum Target: Equatable, Sendable {
        case command(PipelineNode)
        /// `async $(…)`: its output is kept, for `await` to give.
        case capture(PipelineNode)
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
        }
        return .named("Job")
    }

    func evaluate(in interpreter: Interpreter) throws -> Value {
        switch target {
        case .command(let node): try interpreter.shell.start(node, capture: false)
        case .capture(let node): try interpreter.shell.start(node, capture: true)
        }
    }
}

// MARK: Units

/// A command, or commands piped together.
struct PipelineUnit: UnitExtension, Equatable {
    var node: PipelineNode

    mutating func check(in checker: TypeChecker) throws {
        try checker.checkPipeline(&node)
    }

    func run(in interpreter: Interpreter, context: UnitContext) throws -> Int32 {
        let status = try interpreter.shell.run(node, display: context == .statement)
        // `try make`: failing throws, with the status in the error.
        if case .some(let kind) = node.throwing, status != 0 {
            let (code, signal) = interpreter.exitCode(status)
            let error = RuntimeError("\(node.source) failed with status \(status)", status: status,
                                     output: Output(text: "", code: code, signal: signal))
            throw kind == .forced ? FatalError(error: error) : error
        }
        return status
    }

    /// `exit 1` ends the interpreter.
    var leavesProgram: Bool {
        guard node.commands.count == 1, case .text(let parts)? = node.commands[0].words.first else { return false }
        return parts == [.literal("exit")]
    }
}

// MARK: Statements

/// `import Tools from "./Tools"`: builds a Swift package and loads the
/// functions it exports.
struct ImportPluginStatement: StatementExtension, Equatable {
    var name: String
    var path: Expr

    mutating func check(in checker: TypeChecker) throws {
        try checker.expect(&path, .string, "an import's path")
        checker.scopes[checker.scopes.count - 1][name] = .module
        checker.afterImport = true
    }

    func run(in interpreter: Interpreter) throws -> Int32 {
        let value = try interpreter.evaluate(path)
        guard case .string(let text) = value else {
            throw RuntimeError("import \(name): the path must be a String, not \(value.typeName)")
        }
        try interpreter.importPlugin(name, from: text)
        return 0
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

    private var extensionNode: (any ExprExtension)? {
        if case .extended(let box) = self { box.node } else { nil }
    }
}

extension Unit {
    static func pipeline(_ node: PipelineNode) -> Unit { .extended(UnitExtensionBox(PipelineUnit(node: node))) }

    /// The command or pipeline this unit is, if it is one.
    var pipelineNode: PipelineNode? {
        if case .extended(let box) = self { (box.node as? PipelineUnit)?.node } else { nil }
    }
}

extension Statement {
    static func importPlugin(name: String, path: Expr) -> Statement {
        .extended(StatementExtensionBox(ImportPluginStatement(name: name, path: path)))
    }
}

extension Shell {
    /// Runs a pipeline of commands, showing its result when asked, and gives
    /// the exit status.
    func run(_ node: PipelineNode, display: Bool) throws -> Int32 {
        try runPipeline(try stages(for: node), source: node.source, display: display)
    }

    /// Starts a pipeline in the background, giving the job.
    func start(_ node: PipelineNode, capture: Bool) throws -> Value {
        .object(try startJob(try stages(for: node), source: node.source, capture: capture))
    }
}

extension Interpreter {
    /// The shell this interpreter belongs to.
    var shell: Shell { owner as! Shell }
}

// Foundation has a `Unit` too; the language's is the one the shell means.
typealias Unit = SwishCore.Unit
