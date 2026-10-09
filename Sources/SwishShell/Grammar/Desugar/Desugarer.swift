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
        statement: { [unowned self] in statement($0) }
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
        if case .chain(let chain) = statement, chain.links.isEmpty, case .extended(let box) = chain.first,
           let node = box.node as? PipelineUnit, let words = Desugarer.plainWords(of: node.node) {
            // A command statement: its words run, and its status is the statement's.
            return .chain(Chain(first: .expression(Desugarer.commandRun(words))))
        }
        guard case .extended(let box) = statement, var node = box.node as? ImportPluginStatement else { return statement }
        node.path = rewriter.expression(node.path)
        return .extended(StatementExtensionBox(node))
    }

    /// The words of a command that is only words (no `~`, `$name`, glob,
    /// redirect, environment, closure or call, and not `exit`, which ends the
    /// program), when it is the one command of a pipeline. These are what
    /// `Command(…)` takes as they are.
    private static func plainWords(of node: PipelineNode) -> [String]? {
        guard node.commands.count == 1, node.input == nil, node.throwing == nil else { return nil }
        let command = node.commands[0]
        guard !command.external, command.redirects.isEmpty, command.environment.isEmpty, command.call == nil,
              command.notAnExpression == nil else { return nil }
        var words: [String] = []
        for word in command.words {
            guard case .text(let parts) = word else { return nil }
            var text = ""
            for part in parts {
                guard case .literal(let literal) = part else { return nil }
                text += literal
            }
            words.append(text)
        }
        guard let first = words.first, first != "exit" else { return nil }
        return words
    }

    /// `Command("git", "status").run()`.
    private static func commandRun(_ words: [String]) -> Expr {
        let command = Expr.call(.variable("Command"), words.map { Argument(label: nil, value: .literal(.string($0))) })
        return .call(.member(command, "run"), [])
    }

    /// `$name` is the variable `name` if one is in scope, else the
    /// environment's: `env["name"]!`, which stops with a plain error when it
    /// isn't set.
    private func dollar(_ node: DollarExpr) -> Expr {
        if node.isVariable { return .variable(node.name) }
        return .forceUnwrap(.index(.variable("env"), .literal(.string(node.name))))
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
