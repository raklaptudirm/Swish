@_spi(Layer) import Swiit
import Foundation

/// A command as it runs: its words expanded, its redirects resolved, and
/// what the checker decided about it.
struct CommandSpec {
    /// The name, then its arguments.
    var arguments: [CommandArgument]
    var external = false
    var redirects: [ResolvedRedirect] = []
    var environment: [(String, String)] = []
    /// Arguments written as a call, `sorted(by: "size")`; a `.case` waits for its parameter's type.
    var call: [Argument]? = nil
    var resolution: StageResolution? = nil
    var overload: Int? = nil
    var notAnExpression: String? = nil
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
            // The checker decided when the name is a method of what flows in;
            // any other is a function if one has that name, else a program.
            func function(_ set: OverloadSet?) throws -> Stage {
                guard let set else { throw RuntimeError("\(name): not found") }
                return .function(narrowed(set, command.overload), rest, redirects: redirects, environment: environment)
            }
            switch command.resolution {
            case .bridged(let type, let receiver, let bindings)?:
                // `xs | max`: a Swift member, as the checker found it.
                stages.append(try function(bridgedStage(type, name, receiver: receiver, bindings: bindings.mapValues(\.raw))))
            case .sequenceMethod?:
                stages.append(try function(interpreter.sequenceMethods[name]))
            case .itemMethod?:
                stages.append(.method(name, rest, redirects: redirects, environment: environment))
            case nil:
                if !command.external, let set = interpreter.commandFunctions(named: name) {
                    stages.append(try function(set))
                } else {
                    stages.append(try program(arguments, name, command, redirects, environment))
                }
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
                throw RuntimeError("\(name) is an external command, so it can't take a closure")
            }
            return text
        }
        // Not a program after all, and it was only a command because it
        // isn't an expression: that's the error to show (`1...2...3`).
        if let why = command.notAnExpression, Shell.shellBuiltins[name] == nil, !name.contains("/"), findExecutable(name) == nil {
            throw RuntimeError("\(name) isn't a command, and as an expression: \(why)")
        }
        // A builtin that becomes a program, as `run` becomes Swish on a task file.
        if !command.external, case .program(let make)? = Shell.shellBuiltins[name]?.action {
            return .external(try make(self, Array(argv.dropFirst())), skipBuiltins: true, redirects: redirects, environment: environment)
        }
        return .external(argv, skipBuiltins: command.external, redirects: redirects, environment: environment)
    }
}
