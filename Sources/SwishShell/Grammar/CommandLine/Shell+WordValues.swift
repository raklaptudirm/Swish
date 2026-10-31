import Swiit

extension Shell {
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
        guard let symbol = interpreter.symbol(for: id) else { return nil }
        if case .enumeration = symbol.kind { return enumCase(from: text, of: type, id: id) }

        return interpreter.value(from: text, as: type)
    }

    /// Whether a word can be a value of `type` at all: an enum, a Swift type text can be, a key
    /// path, or anything text satisfies. (`word(_:as:)` says whether one word is.)
    func acceptsWords(as type: ScriptType) -> Bool {
        guard case .named(let id, let arguments) = type else { return false }

        if id == .any || id == .keyPath { return true }
        if id == .optional, arguments.count == 1 { return acceptsWords(as: arguments[0]) }

        if id.isGenericParameter { return true }
        guard let symbol = interpreter.symbol(for: id) else { return false }
        if case .enumeration = symbol.kind { return true }

        return hasTextInitializer(type)
    }

    /// Whether a Swift type has an initializer that takes text alone: an unlabeled `String` (`init?(_
    /// description: String)`) or `Substring`, or `init(stringLiteral:)`. (`word(_:as:)` says whether
    /// one word is a value of it: a declaration cannot say which texts are valid.)
    private func hasTextInitializer(_ type: ScriptType) -> Bool {
        interpreter.symbols(in: type)
            .contains { symbol in
                guard case .initializer(let function) = symbol.kind, function.parameters.count == 1
                else { return false }

                let parameter = function.parameters[0]
                let text = parameter.type.description
                return (parameter.label == nil && (text == "String" || text == "Substring"))
                    || (parameter.label == "stringLiteral" && text == "String")
            }
    }

    /// The case of the enum `id` a word names, by its name or its raw value: `.directory`,
    /// `directory`, or `d` for `case directory = "d"`.
    private func enumCase(from text: String, of type: ScriptType, id: Symbol.ID) -> Value? {
        let name = text.hasPrefix(".") ? String(text.dropFirst()) : text
        let cases = interpreter.symbols(in: type)
            .compactMap { symbol -> (Symbol, Value?)? in
                guard case .enumCase(let parameters, let raw) = symbol.kind, parameters.isEmpty
                else {
                    return nil
                }
                return (symbol, raw)
            }

        let named = cases.first { $0.0.name == name }
        let chosen = named ?? cases.first { $0.1?.description == text }
        return chosen.flatMap { interpreter.value(forCase: $0.0.name, in: id) }
    }
}
