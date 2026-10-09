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
