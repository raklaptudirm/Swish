import Swiit
import Foundation
import SystemPackage

/// A call a command line was bound to: the overload it means, and the values its words made for each parameter.
struct BoundCall {
    var callee: Callee
    var overload: Int
    var penalty: Int
    /// The values each parameter was given, by its name: several for a variadic one.
    var bound: [String: [Value]]
    /// A stage written as a call, `sorted(by: "size")`, is bound by Swift's rules instead: its arguments as written.
    var written: [(label: String?, value: Value)]?

    /// What the call is made with, in the order the parameters are declared. `input` is what a pipe feeds the parameter
    /// that takes it.
    func arguments(input: (name: String, value: Value)? = nil) -> [(label: String?, value: Value)] {
        if let written { return written }
        var made: [(label: String?, value: Value)] = []
        for parameter in callee.parameters[overload] {
            if let input, parameter.name == input.name {
                made.append((parameter.label, input.value))
            } else if let values = bound[parameter.name] {
                for (index, value) in values.enumerated() { made.append((index == 0 ? parameter.label : nil, value)) }
            }
        }
        return made
    }
}

extension Shell {
    // MARK: Command-mode calls

    /// For an option a function doesn't have, when a program of the same name is on PATH: that the function is Swish's,
    /// and how to run the program. (It is never run in its place: a function is what was asked for.)
    func programHint(_ name: String) -> String {
        executableNames().contains(name) ? "; this is Swish's \(name): ^\(name) runs the program" : ""
    }

    /// Calls a function with command-line arguments, displaying its result if
    /// asked. The status is 1 for a false result and 0 otherwise.
    func callCommand(_ callee: Callee, _ args: [CommandArgument], display shouldDisplay: Bool) throws -> Int32 {
        if helpRequested(args, for: callee) {
            interpreter.host.output.write(helpText(for: callee, styled: interpreter.host.output.traits().styled))
            return 0
        }
        let call = try bind(commandLine: args, to: callee, excludingInput: false)
        let result = try invoke(call.callee, call.arguments())
        // A command that found nothing (`ls` of an empty directory) shows nothing.
        if shouldDisplay && result != Value([] as [Value]) {
            show(result)
        }
        if let truth = result.cast(to: Bool.self) { return truth ? 0 : 1 }
        return 0
    }

    /// Calls the function a callee names, or its method on `receiver`. A failure is the shell's own error.
    func invoke(_ callee: Callee, _ arguments: [(label: String?, value: Value)], on receiver: Value? = nil) throws -> Value {
        do {
            return try interpreter.call(callee.name, on: receiver, arguments: arguments)
        } catch {
            throw ScriptError(error.message, status: error.status, isReported: error.isReported)
        }
    }

    /// Derives a command-line interface from the signature (see
    /// Swiit's Docs/callables.md): unlabeled parameters are positional,
    /// labeled ones are `--kebab-case` flags, Bools are switches.
    ///
    /// The penalty counts arguments taken as text by String or untyped
    /// parameters, so an Int overload beats a String one for `f 5`.
    func bind(commandLine args: [CommandArgument], to callee: Callee, excludingInput: Bool) throws -> BoundCall {
        // A stage written as a call binds as a call does, without the input.
        let written = args.compactMap { argument -> (label: String?, value: Value)? in
            if case .call(let call) = argument { call } else { nil }
        }
        if !written.isEmpty {
            return BoundCall(callee: callee, overload: 0, penalty: 0, bound: [:], written: written)
        }
        // Which words each parameter gets is decided without values (CommandLineBinder.swift); here they are made.
        let shapes = args.map { argument -> CommandWordShape in
            if case .text(let text) = argument { .text(text) } else { .closure }
        }
        let binding = try bindCommandLine(shapes, to: callee, excludingInput: excludingInput)
        let name = callee.label
        let parameters = callee.parameters[binding.overload].filter { !(excludingInput && $0.isInput) }

        func take(_ word: Int, text: String?, as type: ValueType, for what: String) throws -> Value {
            if let text { return try converted(text, to: type, for: what, of: name) }
            guard case .value(let value) = args[word], let conforming = interpreter.convert(value, to: type) else {
                throw RuntimeError("\(name): \(what) must be \(type), not \(args[word].description)")
            }
            return conforming
        }
        var bound: [String: [Value]] = [:]
        for parameter in parameters {
            switch binding.assigned[parameter.name] {
            case .words(let pieces)?:
                let what = parameter.commandLineName
                if parameter.isVariadic {
                    bound[parameter.name] = try pieces.map { try take($0.word, text: $0.text, as: parameter.type, for: what) }
                } else if let (element, make) = Shell.collection(parameter.type) {
                    bound[parameter.name] = [make(try pieces.map { try take($0.word, text: $0.text, as: element, for: what) })]
                } else if let piece = pieces.first {
                    bound[parameter.name] = [try take(piece.word, text: piece.text, as: parameter.type, for: what)]
                }
            case .flag(let on)?:
                bound[parameter.name] = [Value(on)]
            case .defaulted?:
                break // The function fills in its own default.
            case .omitted?:
                if parameter.type.isBool {
                    bound[parameter.name] = [Value(false)]
                } else if let (_, make) = Shell.collection(parameter.type) {
                    bound[parameter.name] = [make([])]
                } else {
                    bound[parameter.name] = [Value.null]
                }
            case nil:
                break
            }
        }
        return BoundCall(callee: callee, overload: binding.overload, penalty: binding.penalty, bound: bound, written: nil)
    }

    /// What a parameter given several words is made of, and how: a
    /// collection an array literal can be (`[Int]`, `Set<String>`).
    static func collection(_ type: ValueType) -> (element: ValueType, make: ([Value]) -> Value)? {
        switch type {
        case .named("Array", let arguments) where arguments.count == 1:
            return (arguments[0], { Value($0) })
        case .named("ArraySlice", let arguments) where arguments.count == 1:
            return (arguments[0], { Value(boxing: ArraySlice($0), as: "ArraySlice") })
        case .named("Set", let arguments) where arguments.count == 1:
            return (arguments[0], { Value(boxing: Set($0), as: "Set") })
        default:
            return nil
        }
    }

    /// `text` as a value of `type`, or the error that says why it can't be.
    func converted(_ text: String, to type: ValueType, for what: String, of function: String) throws -> Value {
        // Checking a program before it runs: an enum it declares has no cases yet, so the word is read against what was declared.
        if case .named(let name, _) = type.optionalWrapped ?? type, let declared = staticEnums[name] {
            let bare = text.hasPrefix(".") ? String(text.dropFirst()) : text
            guard declared.cases.contains(bare) || declared.hasRawValues else {
                throw RuntimeError("\(function): \(what) must be \(type), got '\(text)'")
            }
            return Value(text)
        }
        if let value = interpreter.value(fromWord: text, as: type) { return value }
        // A command's output, which is text, is what a word is for it.
        if type == .named("Output") { return .output(Output(text: text, code: 0)) }
        guard takesWords(type) else {
            throw RuntimeError("\(function): \(what) is \(type), which a word can't be: call it with parentheses, as in \(function)(…)")
        }
        throw RuntimeError("\(function): \(what) must be \(type), got '\(text)'")
    }

    /// Whether a word can be a value of `type` at all: a Swift type text can be, an enum, or one of Swish's own that's read
    /// from text.
    func takesWords(_ type: ValueType) -> Bool {
        type == .named("Output") || interpreter.acceptsWords(as: type)
    }
}
