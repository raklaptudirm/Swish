@_spi(Shell) import Swiit
import Foundation
import SwishKit

/// Rewrites the shell's constructs in a checked program into Swift: what each
/// means is in Docs/Design/desugaring.md. It runs after the checker, which
/// has decided what it needs to know (here, whether `$name` is a variable),
/// and before the program runs; what it leaves is the core's own tree, which
/// the Swift printer can print. A construct it doesn't rewrite yet stays a
/// node that runs itself, and the pass goes through what is inside it.
final class Desugarer {
    private lazy var rewriter = TreeRewriter(
        expr: { [unowned self] in expression($0) },
        unit: { [unowned self] in unit($0) },
        statement: { [unowned self] in statement($0) },
        chain: { [unowned self] in chain($0, $1) }
    )

    func program(_ program: Program) -> Program {
        rewriter.program(program)
    }

    // MARK: Constructs

    private func expression(_ expr: Expr) -> Expr {
        guard case .extended(let box) = expr else { return expr }
        switch box.node {
        case let node as DollarExpr:
            return dollar(node)
        case var node as SubstitutionExpr:
            node.program = rewriter.program(node.program)
            return .extended(ExprExtensionBox(node))
        case var node as AsyncExpr:
            switch node.target {
            case .command(let pipeline): node.target = .command(self.pipeline(pipeline))
            case .capture(let pipeline): node.target = .capture(self.pipeline(pipeline))
            }
            return .extended(ExprExtensionBox(node))
        default:
            return expr
        }
    }

    private func unit(_ unit: Unit) -> Unit {
        guard case .extended(let box) = unit, var node = box.node as? PipelineUnit else { return unit }
        node.node = pipeline(node.node)
        return .extended(UnitExtensionBox(node))
    }

    private func statement(_ statement: Statement) -> Statement {
        guard case .extended(let box) = statement, var node = box.node as? ImportPluginStatement else { return statement }
        node.path = rewriter.expression(node.path)
        return .extended(StatementExtensionBox(node))
    }

    /// `$name` is the variable `name` if one is in scope, else the
    /// environment's: `env["name"]!`, which stops with a plain error when it
    /// isn't set.
    private func dollar(_ node: DollarExpr) -> Expr {
        if node.isVariable { return .variable(node.name) }
        return .forceUnwrap(.index(.variable("env"), .literal(.string(node.name))))
    }

    // MARK: Command statements and conditions

    /// A chain of plain commands, as the Swift they mean. A statement is the
    /// `Status` of `Command(…).run()`, with `a && b || c` as
    /// `a.run().and { b.run() }.or { c.run() }`; a condition asks whether that
    /// `succeeded`. A chain with anything else in it is left as it is.
    private func chain(_ chain: Chain, _ position: TreeRewriter.Position) -> Chain {
        let standalone = position == .statement && chain.links.isEmpty
        // `try make`, alone: failing throws.
        if standalone, let call = Desugarer.checkedCall(chain.first) {
            return Chain(first: .expression(call))
        }
        guard let first = Desugarer.call(chain.first, display: standalone) else { return chain }
        var status = first
        for link in chain.links {
            guard let next = Desugarer.call(link.unit, display: false) else { return chain }
            let body = Program(statements: [.chain(Chain(first: .expression(next)))])
            status = .call(.member(status, link.op == .and ? "and" : "or"), [
                Argument(label: nil, value: .closure(ClosureLiteral(parameters: [], body: body))),
            ])
        }
        return Chain(first: .expression(position == .condition ? .member(status, "succeeded") : status))
    }

    /// The command a unit is, when it is only words (no `~`, `$name`, glob,
    /// redirect, closure or call, and not `exit`, which ends the program) and
    /// the one command of its pipeline: `Command(…).run()`, which shows its
    /// output when it is a whole statement, inside `with(env:)` when it sets
    /// variables for itself. Not a `try`.
    private static func call(_ unit: Unit, display: Bool) -> Expr? {
        guard let (command, words) = plain(unit), command.node.throwing == nil else { return nil }
        return run(words, environment: command.environment, display: display)
    }

    /// `try make` as `try Command("make").check()`, and `try!` as `try!`.
    private static func checkedCall(_ unit: Unit) -> Expr? {
        guard let (node, words) = plain(unit), let kind = node.node.throwing else { return nil }
        let command = Expr.call(.variable("Command"), words.map { Argument(label: nil, value: .literal(.string($0))) })
        let check = Expr.call(.member(command, "check"), [])
        return .attempt(check, kind ?? .plain)
    }

    /// A single command of plain words, if the unit is one.
    private static func plain(_ unit: Unit) -> (command: (node: PipelineNode, environment: [(String, String)]), words: [String])? {
        guard case .extended(let box) = unit, let pipeline = box.node as? PipelineUnit else { return nil }
        let node = pipeline.node
        guard node.commands.count == 1, node.input == nil else { return nil }
        let command = node.commands[0]
        guard !command.external, command.redirects.isEmpty, command.call == nil, command.notAnExpression == nil else { return nil }
        func text(_ parts: [WordPart]) -> String? {
            var text = ""
            for part in parts {
                guard case .literal(let literal) = part else { return nil }
                text += literal
            }
            return text
        }
        var environment: [(String, String)] = []
        for assignment in command.environment {
            guard let value = text(assignment.value) else { return nil }
            environment.append((assignment.name, value))
        }
        var words: [String] = []
        for word in command.words {
            guard case .text(let parts) = word, let word = text(parts) else { return nil }
            words.append(word)
        }
        guard let first = words.first, first != "exit" else { return nil }
        return ((node, environment), words)
    }

    /// `Command("git", "status").run()`, or `runQuietly()`.
    private static func run(_ words: [String], environment: [(String, String)], display: Bool) -> Expr {
        let command = Expr.call(.variable("Command"), words.map { Argument(label: nil, value: .literal(.string($0))) })
        let call = Expr.call(.member(command, display ? "run" : "runQuietly"), [])
        guard !environment.isEmpty else { return call }
        // `X=1 cmd` sets X for the command: `with(env: ["X": "1"]) { cmd }`.
        let variables = Expr.record(environment.map {
            RecordEntry(key: .literal(.string($0.0)), value: .literal(.string($0.1)))
        })
        let body = Program(statements: [.chain(Chain(first: .expression(call)))])
        return .call(.variable("with"), [
            Argument(label: "env", value: variables),
            Argument(label: nil, value: .closure(ClosureLiteral(parameters: [], body: body))),
        ])
    }

    // MARK: What is inside a command

    private func pipeline(_ node: PipelineNode) -> PipelineNode {
        var node = node
        node.input = node.input.map(rewriter.expression)
        node.commands = node.commands.map(command)
        return node
    }

    private func command(_ command: CommandNode) -> CommandNode {
        var command = command
        command.words = command.words.map { word in
            switch word {
            case .text(let parts): .text(parts.map(part))
            case .closure(let closure): .closure(rewriter.closure(closure))
            }
        }
        command.redirects = command.redirects.map { redirect in
            guard case .file(let parts, let mode) = redirect.target else { return redirect }
            return Redirect(fd: redirect.fd, target: .file(parts.map(part), mode))
        }
        command.environment = command.environment.map { EnvironmentAssignment(name: $0.name, value: $0.value.map(part)) }
        command.call = command.call.map(rewriter.arguments)
        return command
    }

    private func part(_ part: WordPart) -> WordPart {
        switch part {
        case .expression(let expr): .expression(rewriter.expression(expr))
        case .spread(let expr): .spread(rewriter.expression(expr))
        case .literal, .glob: part
        }
    }
}
