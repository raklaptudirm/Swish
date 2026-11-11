import Swiit

extension CommandRunner {
    /// A word of text as a value of `type`: an enum's case by its name (`directory` or
    /// `.directory`) or raw value, a Swift type by its own initializer from text (`5` for an `Int`,
    /// a path for a `FilePath`), a key path by the field names (`size`, `owner.name`), and anything
    /// else by being text, as `String`, `Any` and a type parameter are. Nil if the word is not one.
    func word(_ text: String, as type: ScriptType) -> Value? {
        guard case .named(let id, let arguments) = type else { return nil }

        if id == .any { return Value(text) }
        if id == .keyPath { return Value(keyPath: text.split(separator: ".").map(String.init)) }
        if id == .optional, arguments.count == 1 { return word(text, as: arguments[0]) }

        // A type parameter, which text satisfies.
        if id.isGenericParameter { return Value(text) }
        guard let symbol = id.symbol(in: interpreter) else { return nil }
        if case .enumeration = symbol.kind { return enumCase(from: text, of: type, id: id) }

        // A `String`, or a one-letter `Character`, which Swiit holds as one; then an initializer
        // that cannot fail on text.
        if let literal = interpreter.converted(Value(text), to: type) { return literal }
        // The initializer takes the word as its own parameter type is made from it: a `Substring`
        // by its text literal, since Swift does not turn a `String` into one.
        guard let parameter = textInitializer(of: type),
            let argument = word(text, as: parameter.type)
        else { return nil }

        let made = try? interpreter.call(
            id.name,
            arguments: [(label: parameter.label, value: argument)]
        )
        return made == .nothing ? nil : made
    }

    /// Whether a word can be a value of `type` at all: an enum, a Swift type text can be, a key
    /// path, or anything text satisfies. (`word(_:as:)` says whether one word is.)
    func acceptsWords(as type: ScriptType) -> Bool {
        guard case .named(let id, let arguments) = type else { return false }

        if id == .any || id == .keyPath { return true }
        if id == .optional, arguments.count == 1 { return acceptsWords(as: arguments[0]) }

        if id.isGenericParameter { return true }
        guard let symbol = id.symbol(in: interpreter) else { return false }
        if case .enumeration = symbol.kind { return true }

        return hasTextInitializer(type)
    }

    /// The parameter of an initializer a Swift type is made from text with, which cannot trap on
    /// any text: a failable one taking an unlabeled `String` or `Substring`, or Swift's
    /// `init(stringLiteral:)`, for which every text is valid. (`Character("ab")`, not failable,
    /// traps, and a word is tried against many parameters before one takes it.)
    private func textInitializer(of type: ScriptType) -> Symbol.Parameter? {
        let candidates = textInitializers(of: type)
            .filter { function, parameter in
                if parameter.label == "stringLiteral" { return true }
                guard parameter.label == nil, case .named(let result, _) = function.returns else {
                    return false
                }
                return result == .optional
            }

        // `String` before `Substring`: a `String` has the last too, and `init(_: Any)` makes it
        // ambiguous.
        let preferred = candidates.sorted { $0.1.type == .string && $1.1.type != .string }
        return preferred.first?.1
    }

    /// Whether a word can be a value of a Swift type at all: it has one of those initializers, or
    /// is a type Swift writes as a single-character literal (`Character`), which `converted` checks.
    /// The literal protocols are told by their requirements, the initializers named here, as
    /// `conforms(to:)` doesn't yet tell them apart for a Swift type.
    private func hasTextInitializer(_ type: ScriptType) -> Bool {
        textInitializer(of: type) != nil
            || type.members(in: interpreter)
                .contains { symbol in
                    guard case .initializer(let function) = symbol.kind else { return false }
                    return function.parameters.count == 1
                        && ["extendedGraphemeClusterLiteral", "unicodeScalarLiteral"]
                            .contains(
                                function.parameters[0].label
                            )
                }
    }

    /// The initializers of a Swift type that take one `String` or `Substring`, or its literal.
    private func textInitializers(of type: ScriptType) -> [(Symbol.Function, Symbol.Parameter)] {
        type.members(in: interpreter)
            .compactMap { symbol in
                guard case .initializer(let function) = symbol.kind, function.parameters.count == 1
                else { return nil }

                let parameter = function.parameters[0]
                guard
                    parameter.type == .string
                        || (parameter.type == CommandRunner.substring && parameter.label == nil)
                else {
                    return nil
                }
                return (function, parameter)
            }
    }

    /// The case of the enum `id` a word names, by its name or its raw value: `.directory`,
    /// `directory`, or `d` for `case directory = "d"`.
    private func enumCase(from text: String, of type: ScriptType, id: Symbol.ID) -> Value? {
        let name = text.hasPrefix(".") ? String(text.dropFirst()) : text
        let cases = type.members(in: interpreter)
            .compactMap { symbol -> (Symbol, Value?)? in
                guard case .enumCase(let parameters, let raw) = symbol.kind, parameters.isEmpty
                else {
                    return nil
                }
                return (symbol, raw)
            }

        let named = cases.first { $0.0.name == name }
        let chosen = named ?? cases.first { $0.1?.description == text }
        return chosen.flatMap { id.enumCase(named: $0.0.name, in: interpreter) }
    }
}

extension CommandRunner {
    fileprivate static let substring = ScriptType.named(Symbol.ID(hostType: "Substring"))
}
