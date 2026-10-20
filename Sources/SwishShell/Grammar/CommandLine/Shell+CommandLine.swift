@_spi(Layer) import Swiit
import Foundation
import SystemPackage

extension Shell {
    // MARK: Command-mode calls

    /// For an option a function doesn't have, when a program of the same name is on PATH: that the function is Swish's,
    /// and how to run the program. (It is never run in its place: a function is what was asked for.)
    func programHint(_ name: String) -> String {
        executableNames().contains(name) ? "; this is Swish's \(name): ^\(name) runs the program" : ""
    }

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
    /// Swiit's Docs/callables.md): unlabeled parameters are positional,
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
        // Which words each parameter gets is decided without values (CommandLineBinder.swift); here they are made.
        let shapes = args.map { argument -> CommandWordShape in
            if case .text(let text) = argument { .text(text) } else { .closure }
        }
        let stand = Function(name: nil, parameters: [], returnType: nil, body: .native { _, _ in .nothing })
        let binding = try bindWords(shapes, to: function.parameters, overload: 0, name: name, excludingInput: excludingInput, stand: stand, declaredEnum: nil)

        func take(_ word: Int, text: String?, as type: TypeAnnotation, for what: String) throws -> Value {
            if let text { return try converted(text, to: type, for: what, of: name) }
            guard case .value(let value) = args[word], let conforming = interpreter.conform(value, to: type) else {
                throw RuntimeError("\(name): \(what) must be \(type), not \(args[word].description)")
            }
            return conforming
        }
        var bound: [String: Value] = [:]
        for parameter in parameters {
            switch binding.assigned[parameter.name] {
            case .words(let pieces)?:
                let what = parameter.label.map { "--\(kebabCase($0))" } ?? "<\(parameter.name)>"
                if parameter.variadic {
                    bound[parameter.name] = .list(try pieces.map { try take($0.word, text: $0.text, as: parameter.type, for: what) })
                } else if let (element, make) = Shell.collection(parameter.type) {
                    bound[parameter.name] = make(try pieces.map { try take($0.word, text: $0.text, as: element, for: what) })
                } else if let piece = pieces.first {
                    bound[parameter.name] = try take(piece.word, text: piece.text, as: parameter.type, for: what)
                }
            case .flag(let on)?:
                bound[parameter.name] = .bool(on)
            case .defaulted?:
                // An external default is filled in by the Swift function.
                if let defaultValue = parameter.defaultValue {
                    bound[parameter.name] = try interpreter.defaultArgument(defaultValue, for: parameter, of: function)
                }
            case .omitted?:
                if parameter.type == .bool {
                    bound[parameter.name] = .bool(false)
                } else if let (_, make) = Shell.collection(parameter.type) {
                    bound[parameter.name] = make([])
                } else {
                    bound[parameter.name] = .nothing
                }
            case nil:
                break
            }
        }
        return (bound, binding.penalty)
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
    func takesWords(_ type: TypeAnnotation, declaredEnum: DeclaredEnum? = nil) -> Bool {
        switch type {
        case .any, .unknown, .parameter, .keyPath, .output: return true
        case .optional(let wrapped): return takesWords(wrapped, declaredEnum: declaredEnum)
        case .named(let name) where declaredEnum?(name) != nil || interpreter.enumType(named: name) != nil: return true
        default:
            guard let (bridged, _) = Bridge.type(of: type) else { return false }
            return bridged.parse != nil || bridged.literal != nil
        }
    }

    /// An enum the program being checked declares, which has no `EnumType` to read its cases from yet.
    typealias DeclaredEnum = (String) -> TypeProfile?

    /// `text` as a value of `type`. With `declaredEnum`, a word for an enum is only checked against its declared cases
    /// (a `.string` stands for the value), which is how the checker reads a command line before anything has run.
    func converted(
        _ text: String, to type: TypeAnnotation, for what: String, of function: String, declaredEnum: DeclaredEnum? = nil
    ) throws -> Value {
        let value: Value?
        if case .named(let name) = type, let profile = declaredEnum?(name) {
            let bare = text.hasPrefix(".") ? String(text.dropFirst()) : text
            let isCase = profile.cases.contains { $0.name == bare && $0.payload.isEmpty }
            value = isCase || profile.rawType != nil ? .string(text) : nil
        } else if case .named(let name) = type, let enumType = interpreter.enumType(named: name) {
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
            case .optional(let wrapped): try converted(text, to: wrapped, for: what, of: function, declaredEnum: declaredEnum)
            case .output: .output(Output(text: text, code: 0))
            default: nil
            }
        }
        guard let value else {
            guard takesWords(type, declaredEnum: declaredEnum) else {
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
