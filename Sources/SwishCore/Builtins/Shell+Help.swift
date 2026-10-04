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

    /// What a table of `help` entries starts with.
    static let helpColumns: [DisplayColumn] = [DisplayColumn("name", style: .green), "source", "summary"]

    /// Whether a function has a `--help` or `-h` of its own; if not, the
    /// shell answers them with the function's help, as programs do.
    /// Whether an unlabeled parameter is given every remaining word: a
    /// variadic one, or one that's a collection (`_ paths: [FilePath]`).
    func takesRemainingWords(_ parameter: Parameter) -> Bool {
        parameter.variadic || (parameter.label == nil && !parameter.isInput && Shell.collection(parameter.type) != nil)
    }

    func helpClaimed(by set: OverloadSet) -> Bool {
        set.candidates.contains { $0.parameters.contains { $0.label == "help" || $0.shortFlag == "h" } }
    }

    /// What `--help` shows: usage, arguments and options, in color on a terminal.
    func helpText(for set: OverloadSet, styled: Bool = false) -> String {
        helpLines(for: set).map { $0.rendered(styled) }.joined(separator: "\n") + "\n"
    }

    /// A function's help, a line at a time, each piece colored as the
    /// highlighter would color it in code.
    func helpLines(for set: OverloadSet) -> [StyledText] {
        typealias Row = (key: [StyledText.Segment], detail: [StyledText.Segment])
        var lines: [StyledText] = []
        if let summary = set.candidates.compactMap({ $0.documentation?.summary }).first(where: { !$0.isEmpty }) {
            lines += [StyledText(plain: summary), StyledText(plain: "")]
        }
        lines.append(HelpStyle.heading("Usage:"))
        lines += set.candidates.map { StyledText([.init("  ")] + HelpStyle.usage(usage(of: $0, named: set.name))) }

        var arguments: [Row] = []
        var options: [Row] = []
        var seen: Set<String> = []
        for function in set.candidates {
            for parameter in function.parameters {
                var details: [[StyledText.Segment]] = []
                if let help = function.documentation?.parameters[parameter.name] { details.append([.init(help)]) }
                if parameter.isInput {
                    details.append([.init(parameter.type.isList ? "(or the whole pipeline input)" : "(or each pipeline input item)", HelpStyle.secondary)])
                }
                if let defaultValue = parameter.defaultValue, defaultValue != .literal(.nothing) {
                    details.append(defaultDetail(describe(defaultValue)))
                } else if let source = parameter.externalDefault, source != "[]" {
                    // An empty array as the default says "none", which is no news.
                    details.append(defaultDetail(source))
                }
                if let label = parameter.label {
                    let negatable = parameter.type == .bool && parameter.defaultValue == .literal(.bool(true))
                    let long = "--" + (negatable ? "[no-]" : "") + kebabCase(label)
                    var key: [StyledText.Segment] = parameter.shortFlag.map { [.init("-\($0)", HelpStyle.flag), .init(", ")] } ?? [.init("    ")]
                    key.append(.init(long, HelpStyle.flag))
                    key += valuePlaceholder(for: parameter)
                    if parameter.type.isList { details.append([.init("(repeatable)", HelpStyle.secondary)]) }
                    if seen.insert(StyledText(key).text).inserted { options.append((key, joined(details))) }
                } else {
                    let key: [StyledText.Segment] = [.init("<\(parameter.name)>", HelpStyle.parameter)]
                        + (takesRemainingWords(parameter) ? [.init("...")] : [])
                    if seen.insert(StyledText(key).text).inserted {
                        arguments.append((key, joined(details + [typeDetail(parameter.type.description)])))
                    }
                }
            }
        }
        options.append(([.init("-h, --help", HelpStyle.flag)], [.init("Show this help")]))

        let width = (arguments + options).map { StyledText($0.key).width }.max()! + 2
        func rows(_ title: String, _ entries: [Row]) {
            guard !entries.isEmpty else { return }
            lines += [StyledText(plain: ""), HelpStyle.heading(title)]
            lines += entries.map { row in
                let key = StyledText(row.key)
                let padding = row.detail.isEmpty ? [] : [StyledText.Segment(String(repeating: " ", count: width - key.width))]
                return StyledText([.init("  ")] + row.key + padding + row.detail)
            }
        }
        rows("Arguments:", arguments)
        rows("Options:", options)
        return lines
    }

    /// `(default: 1)`, the value as a constant.
    private func defaultDetail(_ value: String) -> [StyledText.Segment] {
        [.init("(default: ", HelpStyle.secondary), .init(value, HelpStyle.constant), .init(")", HelpStyle.secondary)]
    }

    /// `(Int)`, the type as a type.
    private func typeDetail(_ type: String) -> [StyledText.Segment] {
        [.init("("), .init(type, HelpStyle.type), .init(")")]
    }

    private func joined(_ pieces: [[StyledText.Segment]]) -> [StyledText.Segment] {
        pieces.enumerated().flatMap { index, piece in (index > 0 ? [StyledText.Segment(" ")] : []) + piece }
    }

    private func usage(of function: Function, named name: String) -> String {
        var parts = [name]
        for parameter in function.parameters where parameter.label != nil {
            var flag = commandLineName(of: parameter) + StyledText(valuePlaceholder(for: parameter)).text
            if parameter.type == .bool && parameter.defaultValue == .literal(.bool(true)) {
                flag = "--no-" + flag.dropFirst(2)
            }
            let optional = parameter.hasDefault || parameter.type == .bool || parameter.type.isList
            parts.append(optional ? "[\(flag)]" : flag)
        }
        for parameter in function.parameters where parameter.label == nil {
            var argument = "<\(parameter.name)>"
            if takesRemainingWords(parameter) || (parameter.isInput && parameter.type.isList) {
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
    private func valuePlaceholder(for parameter: Parameter) -> [StyledText.Segment] {
        let type: TypeAnnotation
        switch parameter.type {
        case .bool: return []
        case .list(let element): type = element
        default: type = parameter.type
        }
        return [.init(" <"), .init(placeholder(type), HelpStyle.type), .init(">")]
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
    func help() -> Function {
        Function(
            name: "help",
            parameters: [Parameter(label: nil, name: "name", type: .optional(.string), defaultValue: .literal(.nothing))],
            returnType: nil,
            body: .native { shell, args in
                guard case .string(let name)? = args["name"] else { return .list(shell.helpIndex()) }
                return .list(try shell.helpOutput(for: name).map(Value.styledText))
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
        for builtin in Shell.shellBuiltins.values where builtin.works && !seen.contains(builtin.name) {
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
    func helpOutput(for name: String) throws -> [StyledText] {
        if let set = commandFunctions(named: name) ?? sequenceMethods[name] ?? functionSet(named: name) {
            return helpLines(for: set)
        } else if let builtin = Shell.shellBuiltins[name], builtin.works {
            return [
                StyledText(plain: builtin.summary), StyledText(plain: ""), HelpStyle.heading("Usage:"),
                StyledText([.init("  ")] + HelpStyle.usage(builtin.usage)),
            ]
        } else if let type = typeDescription(named: name) {
            // `help String`: what the type has.
            return helpLines(for: type)
        } else if let path = findExecutable(name) {
            return [StyledText([.init(name, HelpStyle.name), .init(" is a program, "), .init(path, HelpStyle.name), .init(": try `")]
                + HelpStyle.usage("\(name) --help") + [.init("` or `")] + HelpStyle.usage("man \(name)") + [.init("`.")])]
        }
        throw RuntimeError("help: no function, shell builtin, type or program named '\(name)'; `help` lists them all")
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

extension HelpStyle {
    /// A section's title.
    static func heading(_ title: String) -> StyledText {
        StyledText([.init(title, heading)])
    }
}
