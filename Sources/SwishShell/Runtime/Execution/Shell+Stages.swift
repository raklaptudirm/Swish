@_spi(Shell) import Swiit
import Foundation
import SwishKit

extension Shell {
    /// A pipeline's stages, with words expanded and redirects resolved.
    func stages(for node: PipelineNode) throws -> [Stage] {
        var stages: [Stage] = []
        if let input = node.input {
            stages.append(.value(try interpreter.evaluate(input)))
        }
        for (index, command) in node.commands.enumerated() {
            // After a `|`, a name can be a method of what's piped in.
            let piped = index > 0 || node.input != nil
            var arguments: [CommandArgument] = []
            for word in command.words {
                switch word {
                case .text(let parts): arguments += try interpreter.expandWord(parts).map(CommandArgument.text)
                case .closure(let literal): arguments.append(.value(try interpreter.evaluate(.closure(literal))))
                }
            }
            guard case .text(let name) = arguments[0] else {
                throw RuntimeError("a closure can't be a command name")
            }
            if let call = command.call {
                guard !command.external else { throw RuntimeError("a program can't be called with (…)") }
                // `.case` arguments wait for their parameter's type.
                arguments += try call.map { argument in
                    if case .caseLiteral = argument.value { return .call(argument) }
                    return .call(Argument(label: argument.label, value: .literal(try interpreter.evaluate(argument.value))))
                }
            }
            let redirects = try command.redirects.map(interpreter.resolve)
            let environment = try command.environment.map { ($0.name, try interpreter.join($0.value)) }
            let rest = Array(arguments.dropFirst())
            // Methods of the input first (the sequence's, then its items'),
            // then functions, then programs; `foreign` skips to programs.
            // What the checker found, from the input's type, decides; without
            // that, the interpreter looks.
            let resolution = command.resolution
            if !command.external, piped, case .bridged(let type, let receiver, let bindings)? = resolution,
               let members = bridgedStage(type, name, receiver: receiver, bindings: bindings) {
                // `xs | max`: a Swift member, as the checker found it.
                stages.append(.function(narrowed(members, command.overload), rest, redirects: redirects, environment: environment))
            } else if !command.external, piped, resolution == .sequenceMethod, let methods = interpreter.sequenceMethods[name] {
                stages.append(.function(narrowed(methods, command.overload), rest, redirects: redirects, environment: environment))
            } else if !command.external, piped, resolution == .itemMethod {
                stages.append(.method(name, rest, redirects: redirects, environment: environment))
            } else if !command.external, let functions = interpreter.commandFunctions(named: name) {
                stages.append(.function(narrowed(functions, command.overload), rest, redirects: redirects, environment: environment))
            } else if !command.external, !piped, isStageMethod(name), findExecutable(name) == nil {
                throw RuntimeError("\(name) is a method: pipe something into it, as in `ls | \(name)`, or call it on a value, as in `xs.\(name)(…)`")
            } else {
                let argv = try arguments.map { argument -> String in
                    guard case .text(let text) = argument else {
                        throw RuntimeError("\(name) is an external command, so it can't take a closure")
                    }
                    return text
                }
                // Not a program after all, and it was only a command because it
                // isn't an expression: that's the error to show (`1...2...3`).
                if let why = command.notAnExpression, Shell.shellBuiltins[name] == nil, !name.contains("/"),
                   findExecutable(name) == nil {
                    throw RuntimeError("\(name) isn't a command, and as an expression: \(why)")
                }
                // `run test`: the task file, in a Swish of its own.
                // A builtin that becomes a program, as `run` becomes Swish on a task file.
                if !command.external, case .program(let make)? = Shell.shellBuiltins[name]?.action {
                    stages.append(.external(try make(self, Array(argv.dropFirst())), skipBuiltins: true, redirects: redirects, environment: environment))
                } else {
                    stages.append(.external(argv, skipBuiltins: command.external, redirects: redirects, environment: environment))
                }
            }
        }
        return stages
    }
}
