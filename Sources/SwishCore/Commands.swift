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
        // A Swift member's receiver, as a stage's input, isn't written.
        let parameters = parameters.filter { !($0.isInput && $0.name == "self") }.map { p in
            let names = p.label == p.name ? p.name : "\(p.label ?? "_") \(p.name)"
            return "\(p.isInput ? "@input " : "")\(names): \(p.type)\(p.variadic ? "..." : "")"
        }
        return "\(name ?? "closure")(\(parameters.joined(separator: ", ")))" + (returnType.map { " -> \($0)" } ?? "")
    }
}

/// `\.size` or `\.status.code`: reads the path of members from a value.
/// Where a function is wanted it's one, as in Swift: `xs.map(\.name)`.
final class KeyPathValue: Callable, @unchecked Sendable {
    let path: [String]

    init(path: [String]) {
        self.path = path
    }

    var description: String { "\\." + path.joined(separator: ".") }

    func read(from value: Value, in shell: Shell) throws -> Value {
        try path.reduce(value) { try shell.member($1, of: $0) }
    }
}

/// One argument to a command: text, or a value like the closure in
/// `where { $0.size > 1.mb }`.
enum CommandArgument: CustomStringConvertible {
    case text(String)
    case value(Value)
    /// From a stage written as a call, `ls | sorted(by: "size")`: bound by
    /// Swift's rules instead of as a command line.
    case call(Argument)

    var description: String {
        switch self {
        case .text(let text): text
        case .value(let value): value.description
        case .call(let argument): (argument.label.map { "\($0): " } ?? "") + "…"
        }
    }
}

extension TypeAnnotation {
    var isList: Bool {
        if case .list = self { true } else { false }
    }

    /// Whether a closure can be passed for it.
    var acceptsFunction: Bool {
        switch self {
        case .function, .functionType, .any: true
        case .optional(let wrapped): wrapped.acceptsFunction
        default: false
        }
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
    func callCommand(_ set: OverloadSet, _ args: [CommandArgument], display shouldDisplay: Bool) throws -> Int32 {
        if helpRequested(args, for: set) {
            writeAll(stdoutFD, helpText(for: set, styled: Style.enabled(for: stdoutFD)))
            return 0
        }
        let (function, bindings) = try resolve(set) { try self.bind(commandLine: args, to: $0, excludingInput: false) }
        let result = try invoke(function, with: bindings)
        // A command that found nothing (`ls` of an empty directory) shows nothing.
        if shouldDisplay && result != .list([]) {
            show(result)
        }
        if case .bool(let truth) = result { return truth ? 0 : 1 }
        return 0
    }

    /// Derives a command-line interface from the signature (see
    /// Docs/Design/callables.md): unlabeled parameters are positional,
    /// labeled ones are `--kebab-case` flags, Bools are switches.
    ///
    /// The penalty counts arguments taken as text by String or untyped
    /// parameters, so an Int overload beats a String one for `f 5`.
    func bind(
        commandLine args: [CommandArgument], to function: Function, excludingInput: Bool
    ) throws -> (bindings: [String: Value], penalty: Int) {
        let name = function.name ?? "closure"
        let parameters = function.parameters.filter { !(excludingInput && $0.isInput) }
        // A stage written as a call binds as a call does, without the input.
        let callArguments = args.compactMap { argument -> Argument? in
            if case .call(let call) = argument { call } else { nil }
        }
        if !callArguments.isEmpty {
            let stripped = Function(
                name: function.name, parameters: parameters, returnType: function.returnType, body: function.body,
                captured: function.captured, documentation: function.documentation
            )
            return try bind(callArguments, to: stripped)
        }
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
        func take(_ argument: CommandArgument, as type: TypeAnnotation, for what: String) throws -> Value {
            switch argument {
            case .text(let text):
                if type == .string || type == .any { penalty += 1 }
                return try converted(text, to: type, for: what, of: name)
            case .value(let value):
                guard let conforming = conform(value, to: type) else {
                    throw RuntimeError("\(name): \(what) must be \(type), not \(value.typeName)")
                }
                return conforming
            case .call:
                preconditionFailure("call arguments are bound as a call")
            }
        }
        // A collection's items, from repeated flags, made into it at the end.
        var collected: [String: [Value]] = [:]
        func assign(_ parameter: Parameter, _ text: CommandArgument, flag: String) throws {
            if let (element, _) = Shell.collection(parameter.type) {
                // Repeated flags accumulate: --include a --include b.
                collected[parameter.name, default: []].append(try take(text, as: element, for: flag))
            } else {
                guard bound[parameter.name] == nil else { throw RuntimeError("\(name): \(flag) given twice") }
                bound[parameter.name] = try take(text, as: parameter.type, for: flag)
            }
        }

        var positionals: [CommandArgument] = []
        var index = 0
        var flagsEnded = false
        while index < args.count {
            let argument = args[index]
            index += 1
            guard case .text(let arg) = argument, !flagsEnded, arg.hasPrefix("-"), arg != "-" else {
                positionals.append(argument)
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
                    // `--verbose false`: a word Bool's own parser takes is its value.
                    if !negated, index < args.count, case .text(let next) = args[index],
                       let value = try? converted(next, to: parameter.type, for: "", of: name) {
                        bound[parameter.name] = value
                        index += 1
                    } else {
                        bound[parameter.name] = .bool(!negated)
                    }
                } else if let inline {
                    try assign(parameter, .text(inline), flag: "--\(flagName)")
                } else {
                    guard index < args.count else { throw RuntimeError("\(name): --\(flagName) needs a value") }
                    try assign(parameter, args[index], flag: "--\(flagName)")
                    index += 1
                }
                continue
            }

            // Short flags: `-n 3`, `-n3`, bundled switches like `-lv`, and
            // a bundle ending in one that takes a value, like `-rb size`. A
            // dash and a number that isn't a flag is a negative number.
            let letters = Array(arg.dropFirst())
            if shortFlags[letters[0]] == nil, Double(arg) != nil {
                positionals.append(argument)
                continue
            }
            var position = 0
            while position < letters.count {
                let letter = letters[position]
                guard let parameter = shortFlags[letter] else {
                    throw RuntimeError("\(name): unknown option -\(letter)\(letters.count > 1 ? " in \(arg)" : "")")
                }
                position += 1
                if parameter.type == .bool {
                    bound[parameter.name] = .bool(true)
                    continue
                }
                var value = String(letters[position...])
                if value.hasPrefix("=") { value.removeFirst() }
                if value.isEmpty {
                    guard index < args.count else { throw RuntimeError("\(name): -\(letter) needs a value") }
                    try assign(parameter, args[index], flag: "-\(letter)")
                    index += 1
                } else {
                    try assign(parameter, .text(value), flag: "-\(letter)")
                }
                break
            }
        }

        var remaining = positionals[...]
        for parameter in parameters where parameter.label == nil {
            let what = "<\(parameter.name)>"
            // A whole-stream @input parameter given on the command line
            // collects the rest, like a variadic.
            if parameter.variadic {
                bound[parameter.name] = .list(try remaining.map { try take($0, as: parameter.type, for: what) })
                remaining = []
            } else if let (element, make) = Shell.collection(parameter.type) {
                // A collection takes the rest of the words, as a variadic does.
                bound[parameter.name] = make(try remaining.map { try take($0, as: element, for: what) })
                remaining = []
            } else if let text = remaining.popFirst() {
                bound[parameter.name] = try take(text, as: parameter.type, for: what)
            }
        }
        // A closure left over goes to a labeled parameter that takes one, as
        // a trailing closure does in Swift: `ls | sorted { $0.size < $1.size }`.
        if remaining.count == 1, case .value(let closure) = remaining.first!, case .function = closure,
           let parameter = parameters.first(where: { $0.label != nil && bound[$0.name] == nil && $0.type.acceptsFunction }) {
            bound[parameter.name] = closure
            remaining = []
        }
        if let extra = remaining.first {
            throw RuntimeError("\(name): unexpected argument '\(extra.description)'")
        }

        for (name, items) in collected {
            guard let parameter = parameters.first(where: { $0.name == name }), let (_, make) = Shell.collection(parameter.type) else { continue }
            bound[name] = make(items)
        }
        for parameter in parameters where bound[parameter.name] == nil {
            if let defaultValue = parameter.defaultValue {
                bound[parameter.name] = try defaultArgument(defaultValue, for: parameter, of: function)
            } else if parameter.externalDefault != nil {
                continue // The plugin fills it in.
            } else if parameter.type == .bool && parameter.label != nil {
                bound[parameter.name] = .bool(false)
            } else if parameter.label != nil, let (_, make) = Shell.collection(parameter.type) {
                bound[parameter.name] = make([])
            } else if case .optional = parameter.type {
                // An optional flag or argument not given is nil.
                bound[parameter.name] = .nothing
            } else {
                throw RuntimeError("\(name): missing \(commandLineName(of: parameter))")
            }
        }
        return (bound, penalty)
    }

    /// What a parameter given several words is made of, and how: a
    /// collection an array literal can be (`[Int]`, `Set<String>`).
    static func collection(_ type: TypeAnnotation) -> (element: TypeAnnotation, make: ([Value]) -> Value)? {
        guard let (bridged, bindings) = Bridge.type(of: type), let make = bridged.arrayLiteral,
              let parameter = bridged.genericParameters.first, let element = bindings[parameter] else { return nil }
        return (element, make)
    }

    /// Whether a word can be a value of `type` at all: a Swift type text
    /// can be, an enum, or one of Swish's own that's read from text.
    func takesWords(_ type: TypeAnnotation) -> Bool {
        switch type {
        case .any, .unknown, .parameter, .keyPath, .filesize, .output, .date: return true
        case .optional(let wrapped): return takesWords(wrapped)
        case .named(let name) where enumType(named: name) != nil: return true
        default:
            guard let (bridged, _) = Bridge.type(of: type) else { return false }
            return bridged.parse != nil || bridged.literal != nil
        }
    }

    func converted(_ text: String, to type: TypeAnnotation, for what: String, of function: String) throws -> Value {
        let value: Value?
        if case .named(let name) = type, let enumType = enumType(named: name) {
            value = enumCase(fromText: text, enumType)
        } else if let (bridgedType, _) = Bridge.type(of: type), let made = Bridge.value(of: bridgedType.name, from: text) {
            // A Swift type text can be, by its own declarations: `--n 3` for
            // an Int, `--separator " "` for a Character, a FilePath.
            value = made
        } else {
            value = switch type {
            case .any, .unknown, .parameter: .string(text)
            // `sorted --by size`: a field's name is its key path.
            case .keyPath: .function(KeyPathValue(path: text.split(separator: ".").map(String.init)))
            case .optional(let wrapped): try converted(text, to: wrapped, for: what, of: function)
            case .filesize: parseFileSize(text).map(Value.filesize)
            case .output: .output(CommandOutput(text: text, code: 0))
            case .date: (try? Date(text, strategy: .iso8601)).map(Value.date)
            default: nil
            }
        }
        guard let value else {
            guard takesWords(type) else {
                throw RuntimeError("\(function): \(what) is \(type), which a word can't be: call it with parentheses, as in \(function)(…)")
            }
            throw RuntimeError("\(function): \(what) must be \(type), got '\(text)'")
        }
        return value
    }

    /// `1024`, `1.5mb`, `1.5 MB`, `2kib`.
    private func parseFileSize(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        let number = trimmed.prefix { $0.isNumber || $0 == "." }
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        guard let value = Double(number), let multiplier = unit.isEmpty ? 1 : Parser.fileSizeUnits[unit] else { return nil }
        return Int64(exactly: (value * Double(multiplier)).rounded())
    }

    func kebabCase(_ label: String) -> String {
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
