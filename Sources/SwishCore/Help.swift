import Foundation
import SwishKit

/// `help`: every function you can call, as records (so `help | filter …`
/// works), sequence methods included; `help name`: one of them in full.
extension Shell {
    /// The builtins that aren't functions, since they change the shell
    /// itself: their usage and what they do.
    static let shellBuiltins: [(name: String, usage: String, summary: String)] = [
        ("cd", "cd [<dir> | -]", "Changes the working directory: to <dir>, back to the previous one (-), or home."),
        ("exec", "exec <program> [<argument>...]", "Runs a program in the shell's place."),
        ("exit", "exit [<status>]", "Leaves the shell, with <status> or the last command's."),
        ("run", "run [<task> [<argument>...]]",
         "Runs a task: a function in the nearest Tasks.swish, here or in a parent directory, in a Swish of its own. Alone, lists the tasks."),
        ("source", "source <file> [<argument>...]", "Runs a Swish file in this shell, so what it declares stays declared."),
        ("ulimit", "ulimit [-a] [-S|-H] [-c|-d|-f|-n|-s|-t|-u|-v] [<limit>|unlimited]",
         "Shows or sets a resource limit for the shell and what it runs: file size (-f) unless another is named."),
        ("umask", "umask [<mask>]", "Shows or sets, in octal, the permissions new files are made without."),
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
                summary: "Lists every function you can call, or shows one in full, or what a type has.",
                parameters: ["name": "a function, shell builtin, type or program"]
            )
        )
    }

    /// One record per function (its overloads together), sorted by name: the
    /// builtins, yours, and imported ones, whose source is their module.
    func helpIndex() -> [Value] {
        var rows: [(String, Record)] = []
        var seen: Set<String> = []
        for scope in scopes.reversed() {
            for (name, binding) in scope.bindings where seen.insert(name).inserted {
                // A name you can't write, like `$json`, is the shell's own.
                guard Parser.isIdentifier(name), case .function(let set as OverloadSet) = binding.value,
                      let first = set.candidates.first else { continue }
                // One row a name: its overloads' usages, and what each says it does.
                let source = first.plugin ?? (first.isBuiltin ? "builtin" : "yours")
                var summaries: [String] = []
                for candidate in set.candidates {
                    let summary = candidate.documentation?.summary ?? ""
                    if !summary.isEmpty && !summaries.contains(summary) { summaries.append(summary) }
                }
                rows.append((name, helpRecord(name, source: source, usage: set.candidates.map(\.signature).joined(separator: " or "),
                                              descriptions: summaries)))
            }
        }
        for builtin in Shell.shellBuiltins where !seen.contains(builtin.name) {
            rows.append((builtin.name, helpRecord(builtin.name, source: "shell", usage: builtin.usage, descriptions: [builtin.summary])))
        }
        return rows.sorted { $0.0 < $1.0 }.map { .record($0.1) }
    }

    /// `descriptions`: each overload's doc comment, the distinct ones.
    private func helpRecord(_ name: String, source: String, usage: String, descriptions: [String]) -> Record {
        // Each one's first sentence, for the table.
        let summary = descriptions.map(\.firstSentence).joined(separator: " ")
        return Record([
            "name": .string(name), "source": .string(source), "summary": .string(summary),
            "usage": .string(usage), "description": .string(descriptions.joined(separator: "\n\n")),
        ], typeName: "Help")
    }

    /// What `name --help` shows, or what a shell builtin or program is.
    func helpLines(for name: String) throws -> [String] {
        var text: String
        if let set = commandFunctions(named: name) ?? sequenceMethods[name] ?? functionSet(named: name) {
            text = helpText(for: set)
        } else if let builtin = Shell.shellBuiltins.first(where: { $0.name == name }) {
            text = "\(builtin.summary)\n\nUsage:\n  \(builtin.usage)\n"
        } else if let type = typeDescription(named: name) {
            // `help String`: what the type has.
            text = helpText(for: type)
        } else if let path = findExecutable(name) {
            text = "\(name) is a program, \(path): try `\(name) --help` or `man \(name)`.\n"
        } else {
            throw RuntimeError("help: no function, shell builtin, type or program named '\(name)'; `help` lists them all")
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

extension String {
    /// A doc comment's first sentence, on one line, for a list: up to the
    /// first ". " of its first paragraph.
    var firstSentence: String {
        let paragraph = components(separatedBy: "\n\n").first?.replacingOccurrences(of: "\n", with: " ") ?? ""
        return paragraph.range(of: ". ").map { String(paragraph[..<$0.lowerBound]) + "." } ?? paragraph
    }
}
