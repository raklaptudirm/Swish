import Foundation
import SwishKit

/// `help`: every function you can call, as records (so `help | where …`
/// works); `help name`: one of them in full.
extension Shell {
    /// The builtins that aren't functions, since they change the shell
    /// itself: their usage and what they do.
    static let shellBuiltins: [(name: String, usage: String, summary: String)] = [
        ("cd", "cd [<dir> | -]", "Changes the working directory: to <dir>, back to the previous one (-), or home."),
        ("exit", "exit [<status>]", "Leaves the shell, with <status> or the last command's."),
        ("pwd", "pwd", "Prints the working directory."),
        ("which", "which <name>...", "Says what each name runs: a function, a shell builtin or a program."),
    ]

    func help() -> Function {
        Function(
            name: "help",
            parameters: [Parameter(label: nil, name: "name", type: .optional(.string), defaultValue: .literal(.nothing))],
            returnType: nil,
            body: .native { shell, args in
                guard case .string(let name)? = args["name"] else { return .list(shell.helpIndex()) }
                return .list(try shell.helpLines(for: name).map(Value.string))
            },
            documentation: Documentation(
                summary: "Lists every function you can call, or shows one in full.",
                parameters: ["name": "a function, shell builtin or program"]
            )
        )
    }

    /// One record per function (each overload of one), sorted by name: the
    /// builtins, yours, and imported ones, whose source is their module.
    func helpIndex() -> [Value] {
        var rows: [(String, Record)] = []
        var seen: Set<String> = []
        for scope in scopes.reversed() {
            for (name, binding) in scope.bindings where seen.insert(name).inserted {
                guard case .function(let set as OverloadSet) = binding.value else { continue }
                for function in set.candidates {
                    let source = function.plugin ?? (function.isBuiltin ? "builtin" : "yours")
                    rows.append((name, helpRecord(name, source: source, usage: function.signature,
                                                  summary: function.documentation?.summary ?? "")))
                }
            }
        }
        for builtin in Shell.shellBuiltins where !seen.contains(builtin.name) {
            rows.append((builtin.name, helpRecord(builtin.name, source: "shell", usage: builtin.usage, summary: builtin.summary)))
        }
        return rows.sorted { $0.0 < $1.0 }.map { .record($0.1) }
    }

    private func helpRecord(_ name: String, source: String, usage: String, summary: String) -> Record {
        // The first sentence's line, for the table.
        let firstLine = summary.split(separator: "\n").first.map(String.init) ?? ""
        return Record([
            "name": .string(name), "source": .string(source), "summary": .string(firstLine),
            "usage": .string(usage), "description": .string(summary),
        ], typeName: "Help")
    }

    /// What `name --help` shows, or what a shell builtin or program is.
    func helpLines(for name: String) throws -> [String] {
        var text: String
        if let set = commandFunctions(named: name) ?? functionSet(named: name) {
            text = helpText(for: set)
        } else if let builtin = Shell.shellBuiltins.first(where: { $0.name == name }) {
            text = "\(builtin.summary)\n\nUsage:\n  \(builtin.usage)\n"
        } else if let path = findExecutable(name) {
            text = "\(name) is a program, \(path): try `\(name) --help` or `man \(name)`.\n"
        } else {
            throw RuntimeError("help: no function, shell builtin or program named '\(name)'; `help` lists them all")
        }
        if text.hasSuffix("\n") { text.removeLast() }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// A function that isn't a command, like `with`.
    private func functionSet(named name: String) -> OverloadSet? {
        guard case .function(let set as OverloadSet)? = lookup(name)?.value else { return nil }
        return set
    }
}
