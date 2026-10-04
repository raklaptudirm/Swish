import Foundation
import SwishKit
import SystemPackage

/// Swift's own types and members, as Swish sees them: read from the
/// standard library's symbol graph (and swift-system's, for FilePath) by
/// `swish-bridge`, which writes StandardLibrary.swift and SystemPackage.swift
/// beside this file (see `run bridge` in Tasks.swish
/// and Docs/Design/swift-interop.md). Each member comes with its signature,
/// for the checker, and its glue, which calls Swift.
enum Bridge {
    /// The bridged types, by the name Swish writes them with.
    nonisolated(unsafe) static let types: [String: BridgedType] = Dictionary(uniqueKeysWithValues: (standardLibrary + system + swishKit + foundation).map { ($0.name, $0) })

    /// Text as a value of the type named, if the type can be text and the
    /// text is one: through its failable initializer from text (`Int`), or
    /// as a text literal (`Character`, `FilePath`). A word on the command
    /// line, or a string literal where the type is wanted, is converted so.
    static func value(of typeName: String, from text: String) -> Value?? {
        guard let type = types[typeName], type.parse != nil || type.literal != nil else { return nil }
        return .some(type.parse?(text) ?? type.literal?(text))
    }

    /// The bridged type Swish's type annotation is, and its generic
    /// parameters' bindings: `[Int]` is `Array` with Element Int.
    static func type(of annotation: TypeAnnotation) -> (BridgedType, [String: TypeAnnotation])? {
        guard let (name, arguments) = annotation.swiftType, let type = types[name],
              type.genericParameters.count == arguments.count else { return nil }
        return (type, Dictionary(uniqueKeysWithValues: zip(type.genericParameters, arguments)))
    }
}

// Swift's rules for what text literals a type can be, picked the way Swift
// picks: by the most specific literal protocol it conforms to. A string
// literal is any text; a grapheme cluster literal, one Character; a
// Unicode scalar literal, one scalar.

func textLiteral<T: ExpressibleByStringLiteral>(_: T.Type, _ text: String) -> T? where T.StringLiteralType == String {
    T(stringLiteral: text)
}

func textLiteral<T: ExpressibleByExtendedGraphemeClusterLiteral>(_: T.Type, _ text: String) -> T?
where T.ExtendedGraphemeClusterLiteralType == Character {
    guard let character = text.first, text.dropFirst().isEmpty else { return nil }
    return T(extendedGraphemeClusterLiteral: character)
}

func textLiteral<T: ExpressibleByUnicodeScalarLiteral>(_: T.Type, _ text: String) -> T?
where T.UnicodeScalarLiteralType == Unicode.Scalar {
    guard let scalar = text.unicodeScalars.first, text.unicodeScalars.dropFirst().isEmpty else { return nil }
    return T(unicodeScalarLiteral: scalar)
}

/// A bridged type's name as a value, as in `String(sub)` or `Int.max`.
final class BridgedTypeName: SwishObject, @unchecked Sendable {
    let name: String
    init(_ name: String) { self.name = name }
    var typeName: String { "type" }
    var memberNames: [String] { [] }
    func member(_ name: String) -> Value? { nil }
    var fields: Record? { nil }
    var description: String { name }
}

struct BridgedType {
    /// `String`, `Substring`, `Array`.
    let name: String
    /// A generic type's parameters: `Element` for Array.
    let genericParameters: [String]
    /// The protocols it conforms to, of those Swish knows, each with what
    /// its generic parameters must be for it: a ClosedRange is a Sequence
    /// when its Bound is Int (`["Bound": ["=Int"]]`).
    let conformances: [String: [String: [String]]]
    /// Its associated types: `Element` is `Character` for String.
    let associatedTypes: [String: TypeAnnotation]
    /// Text as one, through the type's failable initializer from text
    /// (`Int("42")`); nil if the text isn't one.
    var parse: ((String) -> Value?)? = nil
    /// Text as one by Swift's rules for text literals (`Character`,
    /// `FilePath`); nil if the text can't be that literal.
    var literal: ((String) -> Value?)? = nil
    /// Items as one, for a collection an array literal can be (Array, Set):
    /// what a parameter given several words gets.
    var arrayLiteral: (([Value]) -> Value)? = nil
    let members: [BridgedMember]

}

struct BridgedMember {
    /// A setter is a property's other half, for `p.extension = "md"`.
    enum Kind { case method, property, initializer, setter }

    let kind: Kind
    let name: String
    let isStatic: Bool
    let parameters: [Parameter]
    let returns: TypeAnnotation
    let generics: [String: [String]]
    let isThrowing: Bool
    let isRethrowing: Bool
    /// Changes its receiver, like `append`. Its glue gives the result and
    /// the changed receiver, which the shell puts back.
    let isMutating: Bool
    /// `@discardableResult`, like `removeLast()`: a statement that's just
    /// the call doesn't show what it gives.
    let discardableResult: Bool
    /// Its documentation's first paragraph, from Swift's: what `help` shows.
    let summary: String
    /// Converts the arguments (and `self`), calls Swift, and converts back.
    let body: FunctionBody
    /// What each parameter is, from `- Parameter name:` lines: `help`'s flags.
    var parameterDocs: [String: String] = [:]
}

// MARK: Conversions the glue uses
