@_spi(Shell) import Swiit
import Foundation
import SwishKit

/// Rewrites the shell's constructs in a checked program into Swift: what each
/// means is in Docs/Design/desugaring.md. It runs after the checker, which
/// has decided what it needs to know (whether `$name` is a variable, what
/// each stage of a pipeline is), and before the program runs; what it leaves
/// is the core's own tree, with no shell node in it, which the Swift printer
/// can print.
final class Desugarer {
    /// Whether a pipeline of Swift's own calls is those calls (`xs.sorted()`)
    /// rather than a `Pipeline`; off, to compare the two.
    private let directCalls: Bool

    init(directCalls: Bool = true) {
        self.directCalls = directCalls
    }

    private lazy var rewriter = TreeRewriter(
        expr: { [unowned self] in expression($0) },
        statement: { [unowned self] in statement($0) }
    )

    func program(_ program: Program) -> Program {
        rewriter.program(program)
    }

    // MARK: Expressions

    private func expression(_ expr: Expr) -> Expr {
        guard case .extended(let box) = expr else { return expr }
        switch box.node {
        case let node as DollarExpr:
            return dollar(node)
        case let node as SubstitutionExpr:
            return substitution(node)
        case let node as CommandChainExpr:
            return commands(node)
        case let node as AsyncExpr:
            // `async cmd` starts it; `async $(cmd)` keeps its output too.
            switch node.target {
            case .command(let node): return call(pipeline(node), "start")
            case .capture(let node): return call(pipeline(node), "startCapturing")
            }
        default:
            return expr
        }
    }

    /// `$name` is the variable `name` if one is in scope, else the
    /// environment's: `env["name"]!`, which stops with a plain error when it
    /// isn't set.
    private func dollar(_ node: DollarExpr) -> Expr {
        if node.isVariable { return .variable(node.name) }
        return .forceUnwrap(.index(.variable("env"), .literal(.string(node.name))))
    }

    /// `$(…)` is `capture { … }`, the block run with its output gathered;
    /// under `try`, `capture(throwing: true) { … }`.
    private func substitution(_ node: SubstitutionExpr) -> Expr {
        let body = Argument(label: nil, value: .closure(ClosureLiteral(parameters: [], body: rewriter.program(node.program))))
        let throwing = node.throwing ? [Argument(label: "throwing", value: .literal(.bool(true)))] : []
        return .call(.variable("capture"), throwing + [body])
    }

    // MARK: Statements

    /// `import Tools from "./Tools"` is `importPlugin("Tools", from: "./Tools")`.
    private func statement(_ statement: Statement) -> Statement {
        guard case .extended(let box) = statement, let node = box.node as? ImportPluginStatement else { return statement }
        return .expression(.call(.variable("importPlugin"), [
            Argument(label: nil, value: .literal(.string(node.name))),
            Argument(label: "from", value: rewriter.expression(node.path)),
        ]))
    }

    // MARK: Command statements, chains and conditions

    /// Commands, as the Swift they mean. A command statement is the `Status`
    /// of `run()`; in a chain or a condition, of `runQuietly()`, where a
    /// function used as a command shows nothing; under `try`, of `check()`,
    /// which throws. Joined, `a && b || c` is `a.and { b }.or { c }` over
    /// their statuses, a Swift expression among them its `exitStatus(of:)`; a
    /// condition asks whether that `succeeded`.
    private func commands(_ node: CommandChainExpr) -> Expr {
        let display = !node.isCondition && node.links.isEmpty
        // `xs | sorted` alone, when it is Swift's own calls: shown as a
        // pipeline at the end of a statement shows what it gives.
        if display, directCalls, case .command(let pipeline) = node.first, let calls = self.calls(pipeline) {
            return .call(.variable("displayItems"), [Argument(label: nil, value: calls)])
        }
        func status(_ operand: CommandChainExpr.Operand) -> Expr {
            switch operand {
            case .command(let pipeline):
                if case .some(let kind) = pipeline.throwing { return .attempt(call(self.pipeline(pipeline), "check"), kind ?? .plain) }
                return call(self.pipeline(pipeline), display ? "run" : "runQuietly")
            case .expression(let expr):
                let expr = rewriter.expression(expr)
                // `try? build() && …`: whether it caught an error.
                let value = if case .attempt(_, .optional) = expr { Expr.binary(.notEqual, expr, .literal(.nothing)) } else { expr }
                return .call(.variable("exitStatus"), [Argument(label: "of", value: value)])
            }
        }
        var result = status(node.first)
        for link in node.links {
            let body = Program(statements: [.expression(status(link.operand))])
            result = .call(.member(result, link.isAnd ? "and" : "or"), [
                Argument(label: nil, value: .closure(ClosureLiteral(parameters: [], body: body))),
            ])
        }
        return node.isCondition ? .member(result, "succeeded") : result
    }

    private func call(_ target: Expr, _ method: String) -> Expr {
        .call(.member(target, method), [])
    }

    // MARK: Commands and pipelines

    /// A pipeline fed a value whose stages are each a Swift member of what it
    /// is fed, collected (`xs | sorted | prefix(2)`) or the one value (`"a b"
    /// | split(separator: " ")`), with Swift's arguments or none: the calls
    /// themselves, `xs.sorted().prefix(2)`. Nil for any other, which runs
    /// through `Pipeline`: a stage that works item by item, a method of the
    /// prelude's, a function, a program, or words to convert.
    private func calls(_ node: PipelineNode) -> Expr? {
        guard var expr = node.input.map(rewriter.expression), node.throwing == nil else { return nil }
        // What the next stage gets: a list (an Array of the items), or one value.
        var isList = node.inputIsList
        for (index, command) in node.commands.enumerated() {
            guard !command.external, command.redirects.isEmpty, command.environment.isEmpty, command.words.count == 1,
                  case .text(let parts) = command.words[0], parts.count == 1, case .literal(let name) = parts[0],
                  case .bridged(let type, let receiver, _)? = command.resolution,
                  receiver == .collected && isList || receiver == .value && index == 0 else { return nil }
            var members = Bridge.stageMembers(type, name)
            // With no arguments, it is the member that needs none.
            if command.call == nil { members = members.filter { $0.member.parameters.allSatisfy(\.hasDefault) } }
            guard let member = command.overload.map({ Bridge.stageMembers(type, name)[$0] }) ?? (members.count == 1 ? members[0] : nil) else {
                return nil
            }
            expr = .bridged(type: type, member: member.index, receiver: expr, arguments: command.call.map(rewriter.arguments) ?? [])
            if case .list = member.member.returns { isList = true } else { isList = false }
        }
        return expr
    }

    /// `Command(…)` alone, or `Pipeline(from: input, …)` for more than one or
    /// a value fed in.
    private func pipeline(_ node: PipelineNode) -> Expr {
        let commands = node.commands.map(command)
        if commands.count == 1, node.input == nil { return commands[0] }
        let input = node.input.map { [Argument(label: "from", value: rewriter.expression($0))] } ?? []
        return .call(.variable("Pipeline"), input + commands.map { Argument(label: nil, value: $0) })
    }

    /// `Command(words…)`, with what else the command has as methods:
    /// `^name` is `external()`, `X=1` is `environment(["X": "1"])`, a
    /// redirect `reading`, `writing`, `appending` or `sending`, a call's
    /// arguments `calling((…))`, and what the checker decided `checked(…)`.
    private func command(_ node: CommandNode) -> Expr {
        var expr = Expr.call(.variable("Command"), node.words.map { word in
            switch word {
            case .text(let parts): Argument(label: nil, value: self.word(parts))
            case .closure(let closure): Argument(label: nil, value: .closure(rewriter.closure(closure)))
            }
        })
        func method(_ name: String, _ arguments: [Argument]) {
            expr = .call(.member(expr, name), arguments)
        }
        if node.external { method("external", []) }
        if !node.environment.isEmpty {
            method("environment", [Argument(label: nil, value: .record(node.environment.map {
                RecordEntry(key: .literal(.string($0.name)), value: text($0.value))
            }))])
        }
        for redirect in node.redirects {
            let fd = Argument(label: nil, value: .literal(.int(Int(redirect.fd))))
            switch redirect.target {
            case .file(let parts, .read): method("reading", [fd, Argument(label: "from", value: word(parts))])
            case .file(let parts, .write): method("writing", [fd, Argument(label: "to", value: word(parts))])
            case .file(let parts, .append): method("appending", [fd, Argument(label: "to", value: word(parts))])
            case .descriptor(let other): method("sending", [fd, Argument(label: "to", value: .literal(.int(Int(other))))])
            }
        }
        if let call = node.call { method("calling", [Argument(label: nil, value: .tuple(rewriter.arguments(call)))]) }
        let hint = StageHint(resolution: node.resolution, overload: node.overload, notAnExpression: node.notAnExpression)
        if !hint.isEmpty { method("checked", [Argument(label: nil, value: .literal(.object(hint)))]) }
        return expr
    }

    /// A command's word: a String; `Glob("*.swift")` where it has an unquoted
    /// wildcard; `Spread(xs)` for an unquoted value alone, a word per item.
    private func word(_ parts: [WordPart]) -> Expr {
        let parts = parts.map(part)
        if parts.count == 1, case .spread(let value) = parts[0] { return .call(.variable("Spread"), [Argument(label: nil, value: value)]) }
        guard parts.contains(where: { if case .glob = $0 { true } else { false } }) else { return text(parts) }
        // In a pattern, the text that isn't a wildcard stands for itself.
        let pattern = parts.map { part -> StringPart in
            switch part {
            case .literal(let text): .literal(Glob.escape(text))
            // `?` isn't a wildcard in Swish, so URLs need no quoting.
            case .glob(let text): .literal(text.replacingOccurrences(of: "?", with: "\\?"))
            case .expression(let value), .spread(let value):
                .expression(.call(.variable("escapingWildcards"), [Argument(label: nil, value: .string([.expression(value)]))]))
            }
        }
        return .call(.variable("Glob"), [Argument(label: nil, value: string(pattern))])
    }

    /// A word's parts joined into one String, as an environment variable's value is.
    private func text(_ parts: [WordPart]) -> Expr {
        string(parts.map(part).map { part in
            switch part {
            case .literal(let text), .glob(let text): .literal(text)
            case .expression(let value), .spread(let value): .expression(value)
            }
        })
    }

    /// A string literal, or an interpolation where it has values in it.
    private func string(_ parts: [StringPart]) -> Expr {
        var merged: [StringPart] = []
        for part in parts {
            if case .literal(let text) = part, case .literal(let before)? = merged.last {
                merged[merged.count - 1] = .literal(before + text)
            } else {
                merged.append(part)
            }
        }
        if merged.isEmpty { return .literal(.string("")) }
        if merged.count == 1, case .literal(let text) = merged[0] { return .literal(.string(text)) }
        return .string(merged)
    }

    private func part(_ part: WordPart) -> WordPart {
        switch part {
        case .expression(let expr): .expression(rewriter.expression(expr))
        case .spread(let expr): .spread(rewriter.expression(expr))
        case .literal, .glob: part
        }
    }
}
