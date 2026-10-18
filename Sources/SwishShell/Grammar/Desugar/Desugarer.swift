import Foundation
import SwishShellLibrary

/// Rewrites the shell's constructs into Swift: what each means is in
/// Docs/Design/desugaring.md. The checker calls it on each construct as soon
/// as that construct is checked, when it has decided what the rewrite needs
/// (whether `$name` is a variable, what each stage of a pipeline is); what
/// the program is left with is the core's own tree, with no shell node in it,
/// which the Swift printer can print.
final class Desugarer {
    /// Whether a pipeline of Swift's own calls is those calls (`xs.sorted()`)
    /// rather than a `Pipeline`; off, to compare the two.
    private let directCalls: Bool

    init(directCalls: Bool = true) {
        self.directCalls = directCalls
    }

    // The Swift inside a form of the shell's, rewritten the same way where its own check did not reach it.
    private func rewritten(_ expression: SwiftExpression) -> SwiftExpression { expression.rewritingNodes { [unowned self] in self.expression($0) } }
    private func rewritten(_ closure: SwiftClosure) -> SwiftClosure { closure.rewritingNodes { [unowned self] in self.expression($0) } }
    private func rewritten(_ block: SwiftBlock) -> SwiftBlock { block.rewritingNodes { [unowned self] in self.expression($0) } }
    private func rewritten(_ arguments: [SwiftArgument]) -> [SwiftArgument] { arguments.rewritingNodes { [unowned self] in self.expression($0) } }

    // MARK: Expressions

    func expression(_ expr: SwiftExpression) -> SwiftExpression {
        if let node = expr.node(as: DollarExpr.self) { return dollar(node) }
        if let node = expr.node(as: SubstitutionExpr.self) { return substitution(node) }
        if let node = expr.node(as: CommandChainExpr.self) { return commands(node) }
        if let node = expr.node(as: AsyncExpr.self) {
            // `async cmd` starts it; `async $(cmd)` keeps its output too.
            switch node.target {
            case .command(let node): return call(pipeline(node), "start")
            case .capture(let node): return call(pipeline(node), "startCapturing")
            // `async f(x)` is `startTask("f(x)") { f(x) }`; `async { … }` runs the closure.
            case .task(let expr, let source):
                let body: SwiftClosure
                if let closure = expr.closure, closure.parameterCount == 0 {
                    body = rewritten(closure)
                } else {
                    let expr = rewritten(expr)
                    body = SwiftClosure(expression: expr, capturing: expr.variableNames)
                }
                return .call("startTask", [SwiftArgument(value: .text(source)), SwiftArgument(value: .closure(body))])
            }
        }
        return expr
    }

    /// `$name` is the variable `name` if one is in scope, else the
    /// environment's: `env["name"]!`, which stops with a plain error when it
    /// isn't set.
    private func dollar(_ node: DollarExpr) -> SwiftExpression {
        if node.isVariable { return .variable(node.name) }
        return SwiftExpression.variable("env").subscripted(by: .text(node.name)).forceUnwrapped()
    }

    /// `$(…)` is `capture { … }`, the block run with its output gathered;
    /// under `try`, `capture(throwing: true) { … }`.
    private func substitution(_ node: SubstitutionExpr) -> SwiftExpression {
        let body = SwiftArgument(value: .closure(SwiftClosure(block: rewritten(node.program))))
        let throwing = node.throwing ? [SwiftArgument(label: "throwing", value: .boolean(true))] : []
        return .call("capture", throwing + [body])
    }

    // MARK: Command statements, chains and conditions

    /// Commands, as the Swift they mean. A command statement is the `Status`
    /// of `run()`; in a chain or a condition, of `runQuietly()`, where a
    /// function used as a command shows nothing; under `try`, of `check()`,
    /// which throws. Joined, `a && b || c` is `a.and { b }.or { c }` over
    /// their statuses, a Swift expression among them its `exitStatus(of:)`; a
    /// condition asks whether that `succeeded`.
    private func commands(_ node: CommandChainExpr) -> SwiftExpression {
        let display = !node.isCondition && node.links.isEmpty
        // `xs | sorted` alone, when it is Swift's own calls: shown as a
        // pipeline at the end of a statement shows what it gives.
        if display, directCalls, case .command(let pipeline) = node.first, let calls = self.calls(pipeline) {
            return .call("displayItems", [SwiftArgument(value: calls)])
        }
        func status(_ operand: CommandChainExpr.Operand) -> SwiftExpression {
            switch operand {
            case .command(let pipeline):
                if case .some(let kind) = pipeline.throwing { return call(self.pipeline(pipeline), "check").attempt(kind ?? .plain) }
                return call(self.pipeline(pipeline), display ? "run" : "runQuietly")
            case .expression(let expr):
                let expr = rewritten(expr)
                // `try? build() && …`: whether it caught an error.
                let value = expr.isOptionalAttempt ? expr.isNotNil() : expr
                return .call("exitStatus", [SwiftArgument(label: "of", value: value)])
            }
        }
        var result = status(node.first)
        for link in node.links {
            let body = SwiftBlock(expressions: [status(link.operand)])
            result = result.calling(link.isAnd ? "and" : "or", [SwiftArgument(value: .closure(SwiftClosure(block: body)))])
        }
        return node.isCondition ? result.member("succeeded") : result
    }

    private func call(_ target: SwiftExpression, _ method: String) -> SwiftExpression {
        target.calling(method)
    }

    // MARK: Commands and pipelines

    /// A pipeline fed a value whose stages are each Swift's own call, with
    /// Swift's arguments or none: the calls themselves. A member of the items
    /// collected or of the one value is called on it (`xs.sorted()`); one that
    /// works on items as they come is a `Flow`'s (`Flow(xs).filter { … }`),
    /// which reads an item through every stage before the next, as the
    /// pipeline does; a member or method of each item is `compactMap { … }` on
    /// that `Flow`, dropping what gives nothing, as a stage does. Nil for any
    /// other, which runs through `Pipeline`: an Array member after items
    /// flow, a method of the prelude's, a function, a program, or words to
    /// convert (`sorted --by size`).
    private func calls(_ node: PipelineNode) -> SwiftExpression? {
        guard var expr = node.input.map(rewritten), node.throwing == nil else { return nil }
        /// What the next stage gets: an Array of the items, a `Flow` of them, or one value.
        enum Flowing { case list, flow, value }
        var flowing: Flowing = node.inputIsList ? .list : .value
        // Items as they come: a `Flow` of the list, made once.
        func asFlow() -> Bool {
            if flowing == .flow { return true }
            guard flowing == .list, let initializer = StageMember.flowInitializer else { return false }
            expr = .nativeCall(initializer, on: nil, [SwiftArgument(value: expr)])
            flowing = .flow
            return true
        }
        // `{ $0.… }`, dropping what gives nothing.
        func compactMap(_ call: SwiftExpression) -> Bool {
            guard asFlow(), let member = StageMember.members(of: "Flow", named: "compactMap").first else { return false }
            let transform = SwiftClosure(parameter: "$0", returning: call)
            expr = .nativeCall(member, on: expr, [SwiftArgument(value: .closure(transform))])
            return true
        }
        for (index, command) in node.commands.enumerated() {
            guard !command.external, command.redirects.isEmpty, command.environment.isEmpty, let name = command.literalName else { return nil }
            // A closure word (`filter { … }`) is a trailing closure; any other word converts as a command line's.
            var closures: [SwiftArgument] = []
            for word in command.words.dropFirst() {
                guard case .closure(let closure) = word else { return nil }
                closures.append(SwiftArgument(value: .closure(rewritten(closure))))
            }
            let arguments = (command.call.map(rewritten) ?? []) + closures
            switch command.resolution {
            case .bridged(let type, let receiver, _)?:
                let all = StageMember.members(of: type, named: name)
                // With no arguments, it is the member that needs none.
                let candidates = arguments.isEmpty ? all.filter(\.needsNoArguments) : all
                guard let member = command.overload.map({ all[$0] }) ?? (candidates.count == 1 ? candidates[0] : nil) else {
                    return nil
                }
                switch receiver {
                case .collected where flowing == .list, .value where index == 0:
                    expr = .nativeCall(member, on: expr, arguments)
                    flowing = member.returnsList ? .list : .value
                case .flow:
                    guard asFlow() else { return nil }
                    expr = .nativeCall(member, on: expr, arguments)
                case .each:
                    guard compactMap(.nativeCall(member, on: .variable("$0"), arguments)) else { return nil }
                default:
                    return nil
                }
            // `points | describe`: the method of each item.
            case .itemMethod?:
                guard compactMap(SwiftExpression.variable("$0").calling(name, arguments)) else { return nil }
            default:
                return nil
            }
        }
        return expr
    }

    /// `Command(…)` alone, or `Pipeline(from: input, …)` for more than one or
    /// a value fed in.
    private func pipeline(_ node: PipelineNode) -> SwiftExpression {
        let commands = node.commands.map(command)
        if commands.count == 1, node.input == nil { return commands[0] }
        let input = node.input.map { [SwiftArgument(label: "from", value: rewritten($0))] } ?? []
        return .call("Pipeline", input + commands.map { SwiftArgument(value: $0) })
    }

    /// `Command(words…)`, with what else the command has as methods:
    /// `^name` is `external()`, `X=1` is `environment(["X": "1"])`, a
    /// redirect `reading`, `writing`, `appending` or `sending`, a call's
    /// arguments `calling((…))`, and what the checker decided `checked(…)`.
    private func command(_ node: CommandNode) -> SwiftExpression {
        var expr = SwiftExpression.call("Command", node.words.map { word in
            switch word {
            case .text(let parts): SwiftArgument(value: self.word(parts))
            case .closure(let closure): SwiftArgument(value: .closure(rewritten(closure)))
            }
        })
        func method(_ name: String, _ arguments: [SwiftArgument]) {
            expr = expr.calling(name, arguments)
        }
        if node.external { method("external", []) }
        if !node.environment.isEmpty {
            method("environment", [SwiftArgument(value: .record(node.environment.map { (key: $0.name, value: text($0.value)) }))])
        }
        for redirect in node.redirects {
            let fd = SwiftArgument(value: .integer(Int(redirect.fd)))
            switch redirect.target {
            case .file(let parts, .read): method("reading", [fd, SwiftArgument(label: "from", value: word(parts))])
            case .file(let parts, .write): method("writing", [fd, SwiftArgument(label: "to", value: word(parts))])
            case .file(let parts, .append): method("appending", [fd, SwiftArgument(label: "to", value: word(parts))])
            case .descriptor(let other): method("sending", [fd, SwiftArgument(label: "to", value: .integer(Int(other)))])
            }
        }
        if let call = node.call { method("calling", [SwiftArgument(value: .tuple(rewritten(call)))]) }
        let hint = StageHint(resolution: node.resolution, overload: node.overload, notAnExpression: node.notAnExpression)
        if !hint.isEmpty { method("checked", [SwiftArgument(value: .call("StageHint", hint.arguments))]) }
        return expr
    }

    /// A command's word: a String; `Glob("*.swift")` where it has an unquoted
    /// wildcard; `Spread(xs)` for an unquoted value alone, a word per item.
    private func word(_ parts: [WordPart]) -> SwiftExpression {
        let parts = parts.map(part)
        if parts.count == 1, case .spread(let value) = parts[0] { return .call("Spread", [SwiftArgument(value: value)]) }
        guard parts.contains(where: { if case .glob = $0 { true } else { false } }) else { return text(parts) }
        // In a pattern, the text that isn't a wildcard stands for itself.
        let pattern = parts.map { part -> StringPiece in
            switch part {
            case .literal(let text): .literal(Glob.escape(text))
            // `?` isn't a wildcard in Swish, so URLs need no quoting.
            case .glob(let text): .literal(text.replacingOccurrences(of: "?", with: "\\?"))
            case .expression(let value), .spread(let value):
                .expression(.call("escapingWildcards", [SwiftArgument(value: .interpolated([.expression(value)]))]))
            }
        }
        return .call("Glob", [SwiftArgument(value: string(pattern))])
    }

    /// A word's parts joined into one String, as an environment variable's value is.
    private func text(_ parts: [WordPart]) -> SwiftExpression {
        string(parts.map(part).map { part in
            switch part {
            case .literal(let text), .glob(let text): .literal(text)
            case .expression(let value), .spread(let value): .expression(value)
            }
        })
    }

    /// A string literal, or an interpolation where it has values in it.
    private func string(_ parts: [StringPiece]) -> SwiftExpression {
        var merged: [StringPiece] = []
        for part in parts {
            if case .literal(let text) = part, case .literal(let before)? = merged.last {
                merged[merged.count - 1] = .literal(before + text)
            } else {
                merged.append(part)
            }
        }
        if merged.isEmpty { return .text("") }
        if merged.count == 1, case .literal(let text) = merged[0] { return .text(text) }
        return .interpolated(merged)
    }

    private func part(_ part: WordPart) -> WordPart {
        switch part {
        case .expression(let expr): .expression(rewritten(expr))
        case .spread(let expr): .spread(rewritten(expr))
        case .literal, .glob: part
        }
    }
}
