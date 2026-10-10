@_spi(Shell) import Swiit
import Foundation
import SwishKit

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
        for (index, command) in commands.enumerated() {
            // After a `|`, a name can be a method of what's piped in.
            let piped = index > 0 || input != nil
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
            // Methods of the input first (the sequence's, then its items'),
            // then functions, then programs; `foreign` skips to programs.
            // What the checker found, from the input's type, decides; without
            // that, the interpreter looks.
            let resolution = command.resolution
            if !command.external, piped, case .bridged(let type, let receiver, let bindings)? = resolution,
               let members = bridgedStage(type, name, receiver: receiver, bindings: bindings) {
                // `xs | max`: a Swift member, as the checker found it.
                stages.append(.function(narrowed(members, command.overload), rest, redirects: redirects, environment: environment))
            } else if !command.external, piped, resolution == .sequenceMethod || resolution == nil,
                      let methods = interpreter.sequenceMethods[name] {
                // A stage written by hand, with no checker to decide, is a
                // method of the sequence when there is one.
                stages.append(.function(narrowed(methods, command.overload), rest, redirects: redirects, environment: environment))
            } else if !command.external, piped, resolution == nil, let members = bridgedStage("Array", name, receiver: .collected) {
                // By hand, too: a Swift member of the items collected, `xs | sorted`.
                stages.append(.function(narrowed(members, command.overload), rest, redirects: redirects, environment: environment))
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
