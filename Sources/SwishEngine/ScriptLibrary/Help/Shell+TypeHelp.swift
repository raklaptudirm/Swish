import Foundation
import Swiit
import SwishLibrary

/// What `help Type` and `members` list a type's members under, in the order they are shown.
enum MemberKind: String, CaseIterable {
    case `case`, initializer, property, method
    case staticProperty = "static property", staticMethod = "static method"
    case associatedType = "associated type"

    /// The heading `help` lists them under: "Properties", "Static methods".
    var heading: String {
        let plural = rawValue.hasSuffix("y") ? rawValue.dropLast() + "ies" : rawValue + "s"
        return plural.prefix(1).uppercased() + plural.dropFirst()
    }
}

extension Symbol.Nominal {
    /// The keyword a type is declared with, as `help` heads it: `struct`, `enum`, `protocol`.
    var declarationKeyword: String {
        switch kind {
        case .structure: "struct"
        case .enumeration: "enum"
        case .class: "class"
        case .actor: "actor"
        default: "protocol"
        }
    }
}

extension Symbol {
    /// What a member of a type is, or nil for a symbol that is not one.
    var memberKind: MemberKind? {
        switch self {
        case .enumCase: .case
        case .initializer: .initializer
        case .variable: .property
        case .property(let property): property.isStatic ? .staticProperty : .property
        case .function: .method
        case .method(let method): method.isStatic ? .staticMethod : .method
        case .associatedType: .associatedType
        case .type, .genericParameter: nil
        }
    }

    /// Whether it belongs to the type itself (a static member, an initializer, a case of an enum)
    /// and not to a value of it.
    var belongsToType: Bool {
        switch self {
        case .method(let method): method.isStatic
        case .property(let property): property.isStatic
        case .initializer, .enumCase, .associatedType: true
        case .function, .variable, .type, .genericParameter: false
        }
    }
}

extension Symbol {
    /// What the shell's own protocols ask of a library type: `Tabular` says how a table lays it out
    /// (`columns`), and `RecordRepresentable` says its fields, which are not a bridged member.
    /// They are real members a script can call, and not part of what the type offers, so `help` and
    /// `members` leave them out of a library type's.
    var isLayoutPlumbing: Bool { name == "columns" }
}

extension Shell {
    /// What the type called `name` is and has: "struct", "enum", and its members as symbols. Nil
    /// when nothing by that name is a type.
    func typeMembers(named name: String) -> (type: Symbol.Nominal, members: [Symbol])? {
        // A type a script declared or the shell does, or one of Swift's that the core bridges.
        guard let type = TypeRef(named: name, in: interpreter)?.symbol(in: interpreter) else {
            return nil
        }
        let members = heldType(named: name).members(in: interpreter)
        return (type, type.isBuiltin ? members.filter { !$0.isLayoutPlumbing } : members)
    }

    /// The type a value of `name` is held as: a list is an `Array`.
    private func heldType(named name: String) -> TypeExpression {
        guard let reference = TypeRef(named: name, in: interpreter) else { return .any }
        return reference == .array
            ? .list(TypeExpression.parameter("Element")) : .named(reference)
    }

    /// A member as Swift declares it, in pieces by what each is: `init(_ description: String)`,
    /// `count: Int`, `contains(_ element: Element) -> Bool`.
    func declaration(of symbol: Symbol) -> AttributedString {
        // A type as Swift writes it: its names are types, `throws` and `async` keywords, and
        // brackets and arrows plain.
        func type(_ type: TypeExpression) -> AttributedString {
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
            _ function: Symbol.Signature,
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
        func variableDeclaration(
            _ variableType: TypeExpression,
            _ isSettable: Bool
        )
            -> [AttributedString]
        {
            var pieces = [name, .init(": "), type(variableType)]
            if isSettable {
                pieces += [
                    .init(" { "), .init("get", DisplayStyle.keyword), .init(" "),
                    .init("set", DisplayStyle.keyword), .init(" }"),
                ]
            }
            return pieces
        }
        switch symbol {
        case .function(let function):
            return AttributedString(joining: call(name, function.signature))

        case .method(let method):
            let mutating =
                method.isMutating
                ? [AttributedString("mutating", DisplayStyle.keyword), .init(" ")] : []
            return AttributedString(joining: mutating + call(name, method.signature))

        case .initializer(let initializer):
            return AttributedString(
                joining: call(
                    AttributedString("init", DisplayStyle.keyword),
                    initializer.signature,
                    showsResult: false
                )
            )

        case .variable(let variable):
            return AttributedString(
                joining: variableDeclaration(variable.type, variable.isSettable)
            )

        case .property(let property):
            return AttributedString(
                joining: variableDeclaration(property.type, property.isSettable)
            )

        case .enumCase(let enumCase):
            var pieces = [AttributedString("case", DisplayStyle.keyword), .init(" "), name]
            if !enumCase.payload.isEmpty {
                pieces += [.init("(")]
                pieces += enumCase.payload.enumerated()
                    .flatMap { index, element -> [AttributedString] in
                        (index > 0 ? [.init(", ")] : [])
                            + (element.label.map {
                                [.init($0, DisplayStyle.variable), .init(": ")]
                            }
                                ?? []) + [type(element.type)]
                    }
                pieces += [.init(")")]
            }
            if let raw = enumCase.rawValue {
                pieces += [.init(" = "), .init(raw.debugDescription)]
            }
            return AttributedString(joining: pieces)

        case .associatedType(let associatedType):
            var pieces = [
                AttributedString("associatedtype", DisplayStyle.keyword), .init(" "), name,
            ]
            if case .binding(let bound) = associatedType.role {
                pieces += [.init(" = "), type(bound)]
            }
            return AttributedString(joining: pieces)

        case .type, .genericParameter:
            return name
        }
    }
}
