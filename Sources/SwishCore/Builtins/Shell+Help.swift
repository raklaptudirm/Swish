import Foundation
import SwishKit
import SystemPackage

extension Shell {
    // MARK: Help

    /// `--help` or `-h`, unless a function claims them for itself.
    func helpRequested(_ args: [CommandArgument], for set: OverloadSet) -> Bool {
        guard !helpClaimed(by: set) else { return false }
        for case .text(let arg) in args {
            if arg == "--" { return false }
            if arg == "--help" || arg == "-h" { return true }
        }
        return false
    }

    func helpClaimed(by set: OverloadSet) -> Bool {
        set.candidates.contains { $0.parameters.contains { $0.label == "help" || $0.shortFlag == "h" } }
    }

    /// Section titles stand out when `styled`, and flags are colored as
    /// the highlighter colors them.
    func helpText(for set: OverloadSet, styled: Bool = false) -> String {
        var lines: [String] = []
        if let summary = set.candidates.compactMap({ $0.documentation?.summary }).first(where: { !$0.isEmpty }) {
            lines += [summary, ""]
        }
        lines.append("Usage:".styled(Style.label, styled))
        lines += set.candidates.map { "  " + usage(of: $0, named: set.name) }

        var arguments: [(String, String)] = []
        var options: [(String, String)] = []
        var seen: Set<String> = []
        for function in set.candidates {
            for parameter in function.parameters {
                var details: [String] = []
                if let help = function.documentation?.parameters[parameter.name] { details.append(help) }
                if parameter.isInput {
                    details.append(parameter.type.isList ? "(or the whole pipeline input)" : "(or each pipeline input item)")
                }
                if let defaultValue = parameter.defaultValue, defaultValue != .literal(.nothing) {
                    details.append("(default: \(describe(defaultValue)))")
                } else if let source = parameter.externalDefault {
                    details.append("(default: \(source))")
                }
                if let label = parameter.label {
                    let short = parameter.shortFlag.map { "-\($0), " } ?? "    "
                    let negatable = parameter.type == .bool && parameter.defaultValue == .literal(.bool(true))
                    let long = "--" + (negatable ? "[no-]" : "") + kebabCase(label)
                    let key = short + long + valuePlaceholder(for: parameter)
                    if parameter.type.isList { details.append("(repeatable)") }
                    if seen.insert(key).inserted { options.append((key, details.joined(separator: " "))) }
                } else {
                    let key = "<\(parameter.name)>" + (parameter.variadic ? "..." : "")
                    if seen.insert(key).inserted {
                        arguments.append((key, (details + ["(\(parameter.type))"]).joined(separator: " ")))
                    }
                }
            }
        }
        options.append(("-h, --help", "Show this help"))

        let width = (arguments + options).map(\.0.count).max()! + 2
        func rows(_ title: String, _ entries: [(String, String)]) {
            guard !entries.isEmpty else { return }
            lines += ["", title.styled(Style.label, styled)]
            lines += entries.map { key, detail in
                let color: Style? = key.hasPrefix("-") ? Style.flag : nil
                return detail.isEmpty ? "  " + key.styled(color, styled)
                    : "  " + key.styled(color, styled) + String(repeating: " ", count: width - key.count) + detail
            }
        }
        rows("Arguments:", arguments)
        rows("Options:", options)
        return lines.joined(separator: "\n") + "\n"
    }

    private func usage(of function: Function, named name: String) -> String {
        var parts = [name]
        for parameter in function.parameters where parameter.label != nil {
            var flag = commandLineName(of: parameter) + valuePlaceholder(for: parameter)
            if parameter.type == .bool && parameter.defaultValue == .literal(.bool(true)) {
                flag = "--no-" + flag.dropFirst(2)
            }
            let optional = parameter.hasDefault || parameter.type == .bool || parameter.type.isList
            parts.append(optional ? "[\(flag)]" : flag)
        }
        for parameter in function.parameters where parameter.label == nil {
            var argument = "<\(parameter.name)>"
            if parameter.variadic || (parameter.isInput && parameter.type.isList) {
                argument = "[\(argument)...]"
            } else if parameter.hasDefault || parameter.isInput {
                argument = "[\(argument)]"
            }
            parts.append(argument)
        }
        return parts.joined(separator: " ")
    }

    /// ` <Int>` after a flag that takes a value; a list flag takes one
    /// element per use.
    private func valuePlaceholder(for parameter: Parameter) -> String {
        switch parameter.type {
        case .bool: ""
        case .list(let element): " <\(placeholder(element))>"
        default: " <\(placeholder(parameter.type))>"
        }
    }

    /// A type as `--help` shows it: an enum as its choices.
    private func placeholder(_ type: TypeAnnotation) -> String {
        if case .named(let name) = type, let enumType = enumType(named: name) {
            return enumType.cases.filter(\.labels.isEmpty).map(\.name).joined(separator: "|")
        }
        return type.description
    }

    private func describe(_ defaultValue: Expr) -> String {
        switch defaultValue {
        case .literal(.string(let text)): "\"\(text)\""
        case .literal(.nothing): "nil"
        // As Swift writes it: `"/tmp"` for a FilePath made from a literal.
        case .literal(let value): value.debugDescription
        default: "computed"
        }
    }
}

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
