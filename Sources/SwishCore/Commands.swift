import Foundation
import SwishKit

/// Every function declared under one name. A name declared with `func` is
/// always bound to one of these, even with a single candidate.
final class OverloadSet: Callable, @unchecked Sendable {
    let name: String
    let candidates: [Function]

    init(name: String, candidates: [Function]) {
        self.name = name
        self.candidates = candidates
    }

    var description: String {
        candidates.count == 1 ? candidates[0].description : "<func \(name) (\(candidates.count) overloads)>"
    }
}

extension Function {
    /// Like a Swift declaration: `greet(_ name: String, times: Int) -> String`.
    var signature: String {
        let parameters = parameters.map { p in
            let names = p.label == p.name ? p.name : "\(p.label ?? "_") \(p.name)"
            return "\(p.isInput ? "@input " : "")\(names): \(p.type)\(p.variadic ? "..." : "")"
        }
        return "\(name ?? "closure")(\(parameters.joined(separator: ", ")))" + (returnType.map { " -> \($0)" } ?? "")
    }
}

extension TypeAnnotation {
    var isList: Bool {
        if case .list = self { true } else { false }
    }
}

extension Shell {
    // MARK: Overloads

    /// Picks the overload that `bind` accepts with the lowest penalty, the
    /// most specific match. Ties are an error, never a guess.
    func resolve(
        _ set: OverloadSet, _ bind: (Function) throws -> (bindings: [String: Value], penalty: Int)
    ) throws -> (Function, [String: Value]) {
        if set.candidates.count == 1 {
            return (set.candidates[0], try bind(set.candidates[0]).bindings)
        }
        var matches: [(function: Function, bindings: [String: Value], penalty: Int)] = []
        for candidate in set.candidates {
            do {
                let (bindings, penalty) = try bind(candidate)
                matches.append((candidate, bindings, penalty))
            } catch is RuntimeError {
                continue
            }
        }
        guard let best = matches.map(\.penalty).min() else {
            throw RuntimeError("\(set.name): no overload accepts these arguments; candidates:\n"
                + set.candidates.map { "  " + $0.signature }.joined(separator: "\n"))
        }
        let bestMatches = matches.filter { $0.penalty == best }
        guard bestMatches.count == 1 else {
            throw RuntimeError("\(set.name): ambiguous call; these overloads all match:\n"
                + bestMatches.map { "  " + $0.function.signature }.joined(separator: "\n"))
        }
        return (bestMatches[0].function, bestMatches[0].bindings)
    }

    // MARK: Command-mode calls

    /// Calls a function with command-line arguments, displaying its result if
    /// asked. The status is 1 for a false result and 0 otherwise.
    func callCommand(_ set: OverloadSet, _ args: [String], display shouldDisplay: Bool) throws -> Int32 {
        if helpRequested(args, for: set) {
            writeAll(stdoutFD, helpText(for: set))
            return 0
        }
        let (function, bindings) = try resolve(set) { try self.bind(commandLine: args, to: $0, excludingInput: false) }
        let result = try invoke(function, with: bindings)
        if shouldDisplay && result != .nothing {
            writeAll(stdoutFD, result.description + "\n")
        }
        if case .bool(let truth) = result { return truth ? 0 : 1 }
        return 0
    }

    /// Derives a command-line interface from the signature (see
    /// docs/design/callables.md): unlabeled parameters are positional,
    /// labeled ones are `--kebab-case` flags, Bools are switches.
    ///
    /// The penalty counts arguments taken as text by String or untyped
    /// parameters, so an Int overload beats a String one for `f 5`.
    func bind(
        commandLine args: [String], to function: Function, excludingInput: Bool
    ) throws -> (bindings: [String: Value], penalty: Int) {
        let name = function.name ?? "closure"
        let parameters = function.parameters.filter { !(excludingInput && $0.isInput) }
        var longFlags: [String: (parameter: Parameter, negated: Bool)] = [:]
        var shortFlags: [Character: Parameter] = [:]
        for parameter in parameters {
            guard let label = parameter.label else { continue }
            longFlags[kebabCase(label)] = (parameter, false)
            if parameter.type == .bool, case .literal(.bool(true)) = parameter.defaultValue {
                longFlags["no-" + kebabCase(label)] = (parameter, true)
            }
            if let flag = parameter.shortFlag { shortFlags[flag] = parameter }
        }

        var bound: [String: Value] = [:]
        var penalty = 0
        func take(_ text: String, as type: TypeAnnotation, for what: String) throws -> Value {
            if type == .string || type == .any { penalty += 1 }
            return try converted(text, to: type, for: what, of: name)
        }
        func assign(_ parameter: Parameter, _ text: String, flag: String) throws {
            if case .list(let elementType) = parameter.type {
                // Repeated flags accumulate: --include a --include b.
                let element = try take(text, as: elementType, for: flag)
                if case .list(let existing) = bound[parameter.name] {
                    bound[parameter.name] = .list(existing + [element])
                } else {
                    bound[parameter.name] = .list([element])
                }
            } else {
                guard bound[parameter.name] == nil else { throw RuntimeError("\(name): \(flag) given twice") }
                bound[parameter.name] = try take(text, as: parameter.type, for: flag)
            }
        }

        var positionals: [String] = []
        var index = 0
        var flagsEnded = false
        while index < args.count {
            let arg = args[index]
            index += 1
            if flagsEnded || !arg.hasPrefix("-") || arg == "-" {
                positionals.append(arg)
                continue
            }
            if arg == "--" {
                flagsEnded = true
                continue
            }

            if arg.hasPrefix("--") {
                let body = arg.dropFirst(2)
                let flagName = String(body.prefix { $0 != "=" })
                let inline = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
                guard let (parameter, negated) = longFlags[flagName] else {
                    throw RuntimeError("\(name): unknown option --\(flagName)")
                }
                if parameter.type == .bool && (inline == nil || negated) {
                    guard inline == nil else { throw RuntimeError("\(name): --\(flagName) doesn't take a value") }
                    bound[parameter.name] = .bool(!negated)
                } else if let inline {
                    try assign(parameter, inline, flag: "--\(flagName)")
                } else {
                    guard index < args.count else { throw RuntimeError("\(name): --\(flagName) needs a value") }
                    try assign(parameter, args[index], flag: "--\(flagName)")
                    index += 1
                }
                continue
            }

            // Short flags: `-n 3`, `-n3`, or bundled switches like `-lv`. A
            // dash and a number that isn't a flag is a negative number.
            let letters = Array(arg.dropFirst())
            guard let first = shortFlags[letters[0]] else {
                if Double(arg) != nil {
                    positionals.append(arg)
                    continue
                }
                throw RuntimeError("\(name): unknown option \(arg)")
            }
            if first.type == .bool {
                for letter in letters {
                    guard let parameter = shortFlags[letter], parameter.type == .bool else {
                        throw RuntimeError("\(name): unknown option -\(letter) in \(arg)")
                    }
                    bound[parameter.name] = .bool(true)
                }
            } else if letters.count > 1 {
                var value = String(letters.dropFirst())
                if value.hasPrefix("=") { value.removeFirst() }
                try assign(first, value, flag: "-\(letters[0])")
            } else {
                guard index < args.count else { throw RuntimeError("\(name): -\(letters[0]) needs a value") }
                try assign(first, args[index], flag: "-\(letters[0])")
                index += 1
            }
        }

        var remaining = positionals[...]
        for parameter in parameters where parameter.label == nil {
            let what = "<\(parameter.name)>"
            // A whole-stream @input parameter given on the command line
            // collects the rest, like a variadic.
            if parameter.variadic || (parameter.isInput && parameter.type.isList) {
                let elementType = parameter.variadic ? parameter.type : { if case .list(let t) = parameter.type { t } else { .any } }()
                bound[parameter.name] = .list(try remaining.map { try take($0, as: elementType, for: what) })
                remaining = []
            } else if let text = remaining.popFirst() {
                bound[parameter.name] = try take(text, as: parameter.type, for: what)
            }
        }
        if let extra = remaining.first {
            throw RuntimeError("\(name): unexpected argument '\(extra)'")
        }

        for parameter in parameters where bound[parameter.name] == nil {
            if let defaultValue = parameter.defaultValue {
                bound[parameter.name] = try defaultArgument(defaultValue, for: parameter, of: function)
            } else if parameter.type == .bool && parameter.label != nil {
                bound[parameter.name] = .bool(false)
            } else if parameter.type.isList && parameter.label != nil {
                bound[parameter.name] = .list([])
            } else {
                throw RuntimeError("\(name): missing \(commandLineName(of: parameter))")
            }
        }
        return (bound, penalty)
    }

    func converted(_ text: String, to type: TypeAnnotation, for what: String, of function: String) throws -> Value {
        let value: Value? = switch type {
        case .any, .string: .string(text)
        case .int: Int(text).map(Value.int)
        case .double: Double(text).map(Value.double)
        case .bool: ["true": true, "false": false][text].map(Value.bool)
        case .optional(let wrapped): try converted(text, to: wrapped, for: what, of: function)
        case .list, .function: nil
        }
        guard let value else {
            throw RuntimeError("\(function): \(what) must be \(type), got '\(text)'")
        }
        return value
    }

    private func kebabCase(_ label: String) -> String {
        label.reduce(into: "") { result, c in
            if c.isUppercase {
                result += "-" + c.lowercased()
            } else {
                result.append(c)
            }
        }
    }

    private func commandLineName(of parameter: Parameter) -> String {
        parameter.label.map { "--\(kebabCase($0))" } ?? "<\(parameter.name)>"
    }

    // MARK: Help

    /// `--help` or `-h`, unless a function claims them for itself.
    func helpRequested(_ args: [String], for set: OverloadSet) -> Bool {
        let claimed = set.candidates.contains { $0.parameters.contains { $0.label == "help" || $0.shortFlag == "h" } }
        guard !claimed else { return false }
        for arg in args {
            if arg == "--" { return false }
            if arg == "--help" || arg == "-h" { return true }
        }
        return false
    }

    func helpText(for set: OverloadSet) -> String {
        var lines: [String] = []
        if let summary = set.candidates.compactMap({ $0.documentation?.summary }).first(where: { !$0.isEmpty }) {
            lines += [summary, ""]
        }
        lines.append("Usage:")
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
                if let defaultValue = parameter.defaultValue {
                    details.append("(default: \(describe(defaultValue)))")
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
            lines += ["", title]
            lines += entries.map { key, detail in
                detail.isEmpty ? "  " + key : "  " + key.padding(toLength: width, withPad: " ", startingAt: 0) + detail
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
            let optional = parameter.defaultValue != nil || parameter.type == .bool || parameter.type.isList
            parts.append(optional ? "[\(flag)]" : flag)
        }
        for parameter in function.parameters where parameter.label == nil {
            var argument = "<\(parameter.name)>"
            if parameter.variadic || (parameter.isInput && parameter.type.isList) {
                argument = "[\(argument)...]"
            } else if parameter.defaultValue != nil || parameter.isInput {
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
        case .list(let element): " <\(element)>"
        default: " <\(parameter.type)>"
        }
    }

    private func describe(_ defaultValue: Expr) -> String {
        switch defaultValue {
        case .literal(.string(let text)): "\"\(text)\""
        case .literal(.nothing): "nil"
        case .literal(let value): value.description
        default: "computed"
        }
    }
}
