import Swiit
import Foundation
import SystemPackage

extension Shell {
    // MARK: Help

    /// `--help` or `-h`, unless a function claims them for itself.
    func helpRequested(_ args: [CommandArgument], for callee: Callee) -> Bool {
        guard !helpClaimed(by: callee) else { return false }
        for case .text(let arg) in args {
            if arg == "--" { return false }
            if arg == "--help" || arg == "-h" { return true }
        }
        return false
    }

    /// What a table of `help` entries starts with.
    static let helpColumns: [DisplayColumn] = [DisplayColumn("name", style: .green), "source", "summary"]

    /// Whether a function has a `--help` or `-h` of its own; if not, the
    /// shell answers them with the function's help, as programs do.
    /// Whether an unlabeled parameter is given every remaining word: a
    /// variadic one, or one that's a collection (`_ paths: [FilePath]`).
    func takesRemainingWords(_ parameter: CommandParameter) -> Bool {
        parameter.isVariadic || (parameter.label == nil && !parameter.isInput && Shell.collection(parameter.type) != nil)
    }

    func helpClaimed(by callee: Callee) -> Bool {
        callee.parameters.contains { $0.contains { $0.label == "help" || $0.shortFlag == "h" } }
    }

    /// What `--help` shows: usage, arguments and options, in color on a terminal.
    func helpText(for callee: Callee, styled: Bool = false) -> String {
        helpLines(for: callee).map { $0.rendered(styled) }.joined(separator: "\n") + "\n"
    }

    /// A function's help, a line at a time, each piece colored as the
    /// highlighter would color it in code.
    func helpLines(for callee: Callee) -> [AttributedString] {
        typealias Row = (key: [AttributedString], detail: [AttributedString])
        var lines: [AttributedString] = []
        if let summary = callee.overloads.compactMap(\.summary).first(where: { !$0.isEmpty }) {
            lines += [AttributedString(documentation: summary), AttributedString("")]
        }
        lines.append(HelpStyle.heading("Usage:"))
        lines += callee.parameters.indices.map { AttributedString(joining: [.init("  ")] + usage(of: callee.parameters[$0], named: callee.label)) }

        var arguments: [Row] = []
        var options: [Row] = []
        var seen: Set<String> = []
        for parameters in callee.parameters {
            for parameter in parameters {
                var details: [[AttributedString]] = []
                if let help = parameter.documentation { details.append([AttributedString(documentation: help)]) }
                if parameter.isInput {
                    details.append([.init(parameter.type.isList ? "(or the whole pipeline input)" : "(or each pipeline input item)", DisplayStyle.comment)])
                }
                if let defaultValue = parameter.defaultValue, defaultValue.kind != .nothing {
                    details.append(defaultDetail(describe(defaultValue)))
                }
                if let label = parameter.label {
                    let negatable = parameter.type.isBool && parameter.defaultValue == Value(true)
                    let long = "--" + (negatable ? "[no-]" : "") + kebabCase(label)
                    var key: [AttributedString] = parameter.shortFlag.map { [.init("-\($0)", DisplayStyle.flag), .init(", ")] } ?? [.init("    ")]
                    key.append(.init(long, DisplayStyle.flag))
                    key += valuePlaceholder(for: parameter)
                    if parameter.type.isList { details.append([.init("(repeatable)", DisplayStyle.comment)]) }
                    if seen.insert(AttributedString(joining: key).text).inserted { options.append((key, joined(details))) }
                } else {
                    let key: [AttributedString] = [.init("<\(parameter.name)>", DisplayStyle.variable)]
                        + (takesRemainingWords(parameter) ? [.init("...")] : [])
                    if seen.insert(AttributedString(joining: key).text).inserted {
                        arguments.append((key, joined(details + [typeDetail(parameter.type.description)])))
                    }
                }
            }
        }
        options.append(([.init("-h, --help", DisplayStyle.flag)], [.init("Show this help")]))

        let width = (arguments + options).map { AttributedString(joining: $0.key).width }.max()! + 2
        func rows(_ title: String, _ entries: [Row]) {
            guard !entries.isEmpty else { return }
            lines += [AttributedString(""), HelpStyle.heading(title)]
            lines += entries.map { row in
                let key = AttributedString(joining: row.key)
                let padding = row.detail.isEmpty ? [] : [AttributedString(String(repeating: " ", count: width - key.width))]
                return AttributedString(joining: [.init("  ")] + row.key + padding + row.detail)
            }
        }
        rows("Arguments:", arguments)
        rows("Options:", options)
        return lines
    }

    /// `(default: 1)`, the value as a constant.
    private func defaultDetail(_ value: String) -> [AttributedString] {
        [.init("(default: ", DisplayStyle.comment), .init(value, DisplayStyle.constant), .init(")", DisplayStyle.comment)]
    }

    /// `(Int)`, the type as a type.
    private func typeDetail(_ type: String) -> [AttributedString] {
        [.init("("), .init(type, DisplayStyle.type), .init(")")]
    }

    private func joined(_ pieces: [[AttributedString]]) -> [AttributedString] {
        pieces.enumerated().flatMap { index, piece in (index > 0 ? [AttributedString(" ")] : []) + piece }
    }

    /// `ls [--all] [<paths>...]`, in pieces by what each is.
    private func usage(of parameters: [CommandParameter], named name: String) -> [AttributedString] {
        var parts: [AttributedString] = [.init(name, .command)]
        for parameter in parameters where parameter.label != nil {
            var flag = parameter.commandLineName
            if parameter.type.isBool && parameter.defaultValue == Value(true) {
                flag = "--no-" + flag.dropFirst(2)
            }
            let optional = parameter.hasDefault || parameter.type.isBool || parameter.type.isList
            parts += [.init(" ")] + (optional ? [.init("[")] : []) + [.init(flag, .flag)]
                + valuePlaceholder(for: parameter) + (optional ? [.init("]")] : [])
        }
        for parameter in parameters where parameter.label == nil {
            let argument = AttributedString("<\(parameter.name)>", .variable)
            if takesRemainingWords(parameter) || (parameter.isInput && parameter.type.isList) {
                parts += [.init(" "), .init("["), argument, .init("...]")]
            } else if parameter.hasDefault || parameter.isInput {
                parts += [.init(" "), .init("["), argument, .init("]")]
            } else {
                parts += [.init(" "), argument]
            }
        }
        return parts
    }

    /// ` <Int>` after a flag that takes a value; a list flag takes one
    /// element per use.
    private func valuePlaceholder(for parameter: CommandParameter) -> [AttributedString] {
        let type: ValueType
        if parameter.type.isBool { return [] }
        type = parameter.type.listElement ?? parameter.type
        return [.init(" <"), .init(placeholder(type), DisplayStyle.type), .init(">")]
    }

    /// A type as `--help` shows it: an enum as its choices.
    private func placeholder(_ type: ValueType) -> String {
        if case .named(let name, _) = type, let description = interpreter.typeDescription(named: name), description.kind == "enum" {
            return description.members.filter { $0.kind == .case && !$0.hasPayload }.map(\.name).joined(separator: "|")
        }
        return type.description
    }

    private func describe(_ defaultValue: Value) -> String {
        switch defaultValue.kind {
        case .string: "\"\(defaultValue.description)\""
        case .nothing: "nil"
        // As Swift writes it: `"/tmp"` for a FilePath made from a literal.
        default: defaultValue.debugDescription
        }
    }
}

/// `help`: every function you can call, as records (so `help | filter …`
/// works), sequence methods included; `help name`: one of them in full.
extension Shell {
    /// The body of `help`: the index, or one entry in full.
    func helpBody(_ arguments: [String: Value]) throws -> Value {
        guard let name = arguments["name"]?.cast(to: String.self) else { return Value(helpIndex()) }
        return Value(try helpOutput(for: name).map { Value.attributed($0) })
    }

    /// One record per function (its overloads together), sorted by name: the
    /// builtins, yours, and imported ones, whose source is their module.
    func helpIndex() -> [Value] {
        var rows: [(String, Value)] = []
        var seen: Set<String> = []
        let functions = Dictionary(grouping: interpreter.symbols().filter { $0.function != nil }, by: \.name)
        for (name, candidates) in functions where seen.insert(name).inserted {
            // A name you can't write, like `$json`, is the shell's own.
            guard Lex.isIdentifier(name), let first = candidates.first else { continue }
            // One row a name: its overloads' usages, and what each says it does.
            let source = first.isBuiltin ? "builtin" : "yours"
            var summaries: [String] = []
            for candidate in candidates {
                let summary = candidate.summary ?? ""
                if !summary.isEmpty && !summaries.contains(summary) { summaries.append(summary) }
            }
            rows.append((name, helpRecord(name, source: source, usage: candidates.map(signature(of:)).joined(separator: " or "),
                                          descriptions: summaries)))
        }
        for builtin in Shell.shellBuiltins.values where builtin.works && !seen.contains(builtin.name) {
            rows.append((builtin.name, helpRecord(builtin.name, source: "shell", usage: builtin.usage, descriptions: [builtin.summary])))
        }
        return rows.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// `descriptions`: each overload's doc comment, the distinct ones.
    private func helpRecord(_ name: String, source: String, usage: String, descriptions: [String]) -> Value {
        // Each one's first sentence, for the table.
        let summary = descriptions.map(\.firstSentence).joined(separator: " ")
        return Value(struct: "Help", fields: [
            "name": Value(name), "source": Value(source), "summary": Value(summary),
            "usage": Value(usage), "description": Value(descriptions.joined(separator: "\n\n")),
        ])
    }

    /// What `name --help` shows, or what a shell builtin or program is.
    func helpOutput(for name: String) throws -> [AttributedString] {
        if let callee = commandFunctions(named: name) ?? stageMethods(named: name) {
            return helpLines(for: callee)
        } else if let builtin = Shell.shellBuiltins[name], builtin.works {
            return [
                AttributedString(documentation: builtin.summary), AttributedString(""), HelpStyle.heading("Usage:"),
                AttributedString(joining: [.init("  ")] + HelpStyle.usage(builtin.usage)),
            ]
        } else if let type = interpreter.typeDescription(named: name) {
            // `help String`: what the type has.
            return helpLines(for: type)
        } else if let path = findExecutable(name) {
            return [AttributedString(joining: [.init(name, DisplayStyle.command), .init(" is a program, "), .init(path, DisplayStyle.command), .init(": try `")]
                + HelpStyle.usage("\(name) --help") + [.init("` or `")] + HelpStyle.usage("man \(name)") + [.init("`.")])]
        }
        throw RuntimeError("help: no function, shell builtin, type or program named '\(name)'; `help` lists them all")
    }

    /// What `help Type` shows: its members, grouped by kind, each with its
    /// signature (highlighted as Swift) and, on the line below, what its
    /// documentation says.
    func helpLines(for type: TypeDescription) -> [AttributedString] {
        var lines = [AttributedString(joining: [.init(type.kind, DisplayStyle.keyword), .init(" "), .init(type.name, DisplayStyle.type)])]
        let groups = Dictionary(grouping: type.members, by: \.kind)
        for kind in TypeDescription.Kind.allCases {
            guard let members = groups[kind], !members.isEmpty else { continue }
            lines += [AttributedString(""), HelpStyle.heading("\(kind.heading):")]
            for (index, member) in members.sorted(by: { $0.name < $1.name }).enumerated() {
                // A blank line between them, so a signature and its description read as one.
                if index > 0 { lines.append(AttributedString("")) }
                lines.append(AttributedString(joining: [AttributedString("  "), member.signature]))
                if !member.summary.isEmpty { lines.append(AttributedString("    ") + AttributedString(documentation: member.summary)) }
            }
        }
        return lines
    }

    /// A function as Swift declares it: `greet(_ name: String, times: Int) -> String`. What a pipe feeds is marked `@input`.
    func signature(of symbol: Symbol) -> String {
        guard let function = symbol.function else { return symbol.name }
        let parameters = function.parameters.map { parameter -> String in
            let marked = CommandParameter(parameter, of: symbol.name)
            var text = marked.isInput ? "@input " : ""
            if parameter.label == parameter.name {
                text += parameter.name
            } else {
                text += "\(parameter.label ?? "_") \(parameter.name)"
            }
            return text + ": \(parameter.type)" + (parameter.isVariadic ? "..." : "")
        }
        return "\(symbol.name)(\(parameters.joined(separator: ", ")))" + (function.returns.map { " -> \($0)" } ?? "")
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
