import Foundation
import SwishKit
import SystemPackage

extension Shell {
    // MARK: Command-mode calls

    /// Calls a function with command-line arguments, displaying its result if
    /// asked. The status is 1 for a false result and 0 otherwise.
    func callCommand(_ set: OverloadSet, _ args: [CommandArgument], display shouldDisplay: Bool) throws -> Int32 {
        if helpRequested(args, for: set) {
            interpreter.host.output.write(helpText(for: set, styled: interpreter.host.output.traits().styled))
            return 0
        }
        let (function, bindings) = try interpreter.resolve(set) { try self.bind(commandLine: args, to: $0, excludingInput: false) }
        let result = try interpreter.invoke(function, with: bindings)
        // A command that found nothing (`ls` of an empty directory) shows nothing.
        if shouldDisplay && result != .list([]) {
            interpreter.show(result)
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
            return try interpreter.bind(callArguments, to: stripped)
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
                guard let conforming = interpreter.conform(value, to: type) else {
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
                bound[parameter.name] = try interpreter.defaultArgument(defaultValue, for: parameter, of: function)
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
        case .any, .unknown, .parameter, .keyPath, .output: return true
        case .optional(let wrapped): return takesWords(wrapped)
        case .named(let name) where interpreter.enumType(named: name) != nil: return true
        default:
            guard let (bridged, _) = Bridge.type(of: type) else { return false }
            return bridged.parse != nil || bridged.literal != nil
        }
    }

    func converted(_ text: String, to type: TypeAnnotation, for what: String, of function: String) throws -> Value {
        let value: Value?
        if case .named(let name) = type, let enumType = interpreter.enumType(named: name) {
            value = interpreter.enumCase(fromText: text, enumType)
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
            case .output: .output(Output(text: text, code: 0))
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

    func kebabCase(_ label: String) -> String {
        label.reduce(into: "") { result, c in
            if c.isUppercase {
                result += "-" + c.lowercased()
            } else {
                result.append(c)
            }
        }
    }

    func commandLineName(of parameter: Parameter) -> String {
        parameter.label.map { "--\(kebabCase($0))" } ?? "<\(parameter.name)>"
    }
}
