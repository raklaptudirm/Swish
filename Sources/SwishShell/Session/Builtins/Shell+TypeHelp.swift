import Foundation
import Swiit

/// What `help Type` and `members` list a type's members under, in the order they are shown.
enum MemberKind: String, CaseIterable {
    case `case`, initializer, property, method
    case staticProperty = "static property", staticMethod = "static method"

    /// The heading `help` lists them under: "Properties", "Static methods".
    var heading: String {
        let plural = rawValue.hasSuffix("y") ? rawValue.dropLast() + "ies" : rawValue + "s"
        return plural.prefix(1).uppercased() + plural.dropFirst()
    }
}

extension Symbol {
    /// What a member of a type is, or nil for a symbol that is not one.
    var memberKind: MemberKind? {
        switch kind {
        case .enumCase: .case
        case .initializer: .initializer
        case .variable: .property
        case .property(let property): property.isStatic ? .staticProperty : .property
        case .function: .method
        case .method(let method): method.isStatic ? .staticMethod : .method
        case .structure, .enumeration, .class, .actor, .protocol: nil
        }
    }

    /// Whether it belongs to the type itself (a static member, an initializer, a case of an enum)
    /// and not to a value of it.
    var belongsToType: Bool {
        switch kind {
        case .method(let method): method.isStatic
        case .property(let property): property.isStatic
        case .initializer, .enumCase: true
        case .function, .variable: false
        case .structure, .enumeration, .class, .actor, .protocol: false
        }
    }
}

extension Shell {
    /// What the type called `name` is and has: "struct", "enum", and its members as symbols. Nil
    /// when nothing by that name is a type.
    func typeMembers(named name: String) -> (kind: String, members: [Symbol])? {
        // A type a script declared or the shell does, or one of Swift's that the core bridges.
        let named = interpreter.symbols(named: name) + interpreter.types.filter { $0.name == name }
        guard let type = named.first(where: \.isType) else { return nil }
        let word =
            switch type.kind {
            case .structure: "struct"
            case .enumeration: "enum"
            case .class: "class"
            case .actor: "actor"
            default: "protocol"
            }
        return (word, interpreter.symbols(in: heldType(named: name)))
    }

    /// The type a value of `name` is held as: a list is an `Array`.
    private func heldType(named name: String) -> ScriptType {
        name == "Array" ? .list(.named("Element")) : .named(name)
    }

    /// The cases of an enum that carry nothing: what a word for it can be.
    func plainCases(of members: [Symbol]) -> [String] {
        members.compactMap { symbol in
            if case .enumCase(let parameters, _) = symbol.kind, parameters.isEmpty {
                return symbol.name
            }
            return nil
        }
    }

    /// A member as Swift declares it, in pieces by what each is: `init(_ description: String)`,
    /// `count: Int`, `contains(_ element: Element) -> Bool`.
    func declaration(of symbol: Symbol) -> AttributedString {
        // A type as Swift writes it: its names are types, `throws` and `async` keywords, and
        // brackets and arrows plain.
        func type(_ type: ScriptType) -> AttributedString {
            var pieces: [AttributedString] = []
            var word = ""
            func flush() {
                guard !word.isEmpty else { return }
                let isKeyword = word == "throws" || word == "async"
                pieces.append(.init(word, isKeyword ? DisplayStyle.keyword : DisplayStyle.type))
                word = ""
            }
            for character in type.description {
                if character.isLetter || character.isNumber || character == "_" || character == "."
                {
                    word.append(character)
                } else {
                    flush()
                    pieces.append(.init(String(character)))
                }
            }
            flush()
            return AttributedString(joining: pieces)
        }
        func parameters(_ parameters: [Symbol.Parameter]) -> [AttributedString] {
            parameters.enumerated()
                .flatMap { index, parameter -> [AttributedString] in
                    var pieces: [AttributedString] = index > 0 ? [.init(", ")] : []
                    if parameter.label == parameter.name {
                        pieces.append(.init(parameter.name, DisplayStyle.variable))
                    } else {
                        pieces += [
                            .init(parameter.label ?? "_", parameter.label == nil ? nil : .variable),
                            .init(" "), .init(parameter.name, DisplayStyle.variable),
                        ]
                    }
                    pieces += [.init(": "), type(parameter.type)]
                    if parameter.arity == .variadic { pieces.append(.init("...")) }
                    return pieces
                }
        }
        func call(
            _ name: AttributedString,
            _ function: Symbol.Function,
            showsResult: Bool = true
        ) -> [AttributedString] {
            var pieces = [name, .init("(")] + parameters(function.parameters) + [.init(")")]
            if function.isAsync { pieces += [.init(" "), .init("async", DisplayStyle.keyword)] }
            if function.isThrowing {
                pieces += [.init(" "), .init("throws", DisplayStyle.keyword)]
            }
            if showsResult, function.returns != .void {
                pieces += [.init(" -> "), type(function.returns)]
            }
            return pieces
        }
        let name = AttributedString(symbol.name, DisplayStyle.function)
        switch symbol.kind {
        case .function(let function):
            return AttributedString(joining: call(name, function))
        case .method(let method):
            let mutating =
                method.isMutating
                ? [AttributedString("mutating", DisplayStyle.keyword), .init(" ")] : []
            return AttributedString(joining: mutating + call(name, method.function))
        case .initializer(let function):
            return AttributedString(
                joining: call(
                    AttributedString("init", DisplayStyle.keyword),
                    function,
                    showsResult: false
                )
            )
        case .variable, .property:
            let variable = symbol.variable!
            var pieces = [name, .init(": "), type(variable.type)]
            if variable.isSettable {
                pieces += [
                    .init(" { "), .init("get", DisplayStyle.keyword), .init(" "),
                    .init("set", DisplayStyle.keyword), .init(" }"),
                ]
            }
            return AttributedString(joining: pieces)
        case .enumCase(let carried, let raw):
            var pieces = [AttributedString("case", DisplayStyle.keyword), .init(" "), name]
            if !carried.isEmpty {
                pieces += [.init("(")]
                pieces += carried.enumerated()
                    .flatMap { index, parameter -> [AttributedString] in
                        (index > 0 ? [.init(", ")] : [])
                            + (parameter.label.map {
                                [.init($0, DisplayStyle.variable), .init(": ")]
                            }
                                ?? []) + [type(parameter.type)]
                    }
                pieces += [.init(")")]
            }
            if let raw { pieces += [.init(" = "), .init(raw.debugDescription)] }
            return AttributedString(joining: pieces)
        case .structure, .enumeration, .class, .actor, .protocol:
            return name
        }
    }
}
