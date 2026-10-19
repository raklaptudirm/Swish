@_spi(Layer) import Swiit
import Foundation

/// A command as it runs: its words expanded, its redirects resolved.
struct CommandSpec {
    /// The name, then its arguments.
    var arguments: [CommandArgument]
    var external = false
    var redirects: [ResolvedRedirect] = []
    var environment: [(String, String)] = []
    /// Arguments written as a call, `sorted(by: "size")`; a `.case` waits for its parameter's type.
    var call: [Argument]? = nil
}

extension Shell {
    /// The stages of commands fed `input`, if any.
    func stages(input: Value?, commands: [CommandSpec]) throws -> [Stage] {
        var stages: [Stage] = []
        if let input { stages.append(.value(input)) }
        for command in commands {
            var arguments = command.arguments
            guard case .text(let name)? = arguments.first else {
                throw RuntimeError("a closure can't be a command name")
            }
            if let call = command.call {
                guard !command.external else { throw RuntimeError("a program can't be called with (…)") }
                arguments += call.map(CommandArgument.call)
            }
            let redirects = command.redirects
            let environment = command.environment
            let rest = Array(arguments.dropFirst())
            // A function if one has that name, else a program; or a method of what flows in, which is found when the
            // first item arrives (Shell+Resolving.swift).
            func function(_ set: OverloadSet?) throws -> Stage {
                guard let set else { throw RuntimeError("\(name): not found") }
                return .function(set, rest, redirects: redirects, environment: environment)
            }
            func fallback() throws -> Stage {
                if !command.external, let set = interpreter.commandFunctions(named: name) { return try function(set) }
                return try program(arguments, name, command, redirects, environment)
            }
            if !command.external, (input != nil || !stages.isEmpty), isMemberName(name) || isStageMethod(name) {
                stages.append(.deferred(DeferredStage(name: name, arguments: rest, redirects: redirects, environment: environment, fallback: fallback)))
            } else {
                stages.append(try fallback())
            }
        }
        return stages
    }

    /// A builtin or a program on the path.
    private func program(
        _ arguments: [CommandArgument], _ name: String, _ command: CommandSpec,
        _ redirects: [ResolvedRedirect], _ environment: [(String, String)]
    ) throws -> Stage {
        let argv = try arguments.map { argument -> String in
            guard case .text(let text) = argument else {
                throw RuntimeError("\(name) isn't a method or a function, and a program can't take a closure or (…)")
            }
            return text
        }
        // A builtin that becomes a program, as `run` becomes Swish on a task file.
        if !command.external, case .program(let make)? = Shell.shellBuiltins[name]?.action {
            return .external(try make(self, Array(argv.dropFirst())), skipBuiltins: true, redirects: redirects, environment: environment)
        }
        return .external(argv, skipBuiltins: command.external, redirects: redirects, environment: environment)
    }
}
