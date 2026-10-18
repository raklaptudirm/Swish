@_spi(Layer) import Swiit
import Foundation

// Spike: a type, as the checker names it, and the signatures it gives to functions and members.

/// A type: `Int`, `[String]`, `Flow<Int>`, `(Int) -> Bool`, or one the checker can't tell (`unknown`).
struct ValueType: Equatable, Sendable, CustomStringConvertible {
    var raw: TypeAnnotation
    init(_ raw: TypeAnnotation) { self.raw = raw }
    var description: String { raw.description }

    static let unknown = ValueType(.unknown)
    static let any = ValueType(.any)
    static let string = ValueType(.string)
    static let int = ValueType(.int)
    static let bool = ValueType(.bool)
    static let void = ValueType(.void)
    /// What `$(…)` gives.
    static let output = ValueType(.output)
    static func named(_ name: String) -> ValueType { ValueType(.named(name)) }
    static func list(_ element: ValueType) -> ValueType { ValueType(.list(element.raw)) }
    static func generic(_ name: String, _ arguments: [ValueType]) -> ValueType { ValueType(.generic(name, arguments.map(\.raw))) }
    static func job(of result: ValueType?) -> ValueType { result.map { ValueType(.generic("Job", [$0.raw])) } ?? ValueType(.named("Job")) }

    /// The item type, if this is a list.
    var listElement: ValueType? {
        if case .list(let element) = raw { ValueType(element) } else { nil }
    }
    var isList: Bool { listElement != nil }
    /// Whether the checker knows nothing of it, so anything fits.
    var isUnknownOrAny: Bool { raw == .unknown || raw == .any }
    var isUnknown: Bool { raw == .unknown }
    /// The name, if this is a plain named type (a struct's, an enum's).
    var plainName: String? {
        if case .named(let name) = raw { name } else { nil }
    }
    /// A function type's result.
    var functionResult: ValueType? {
        if case .functionType(_, let result, _, _) = raw { ValueType(result) } else { nil }
    }
    /// Whether a closure can be given where this type is wanted.
    var acceptsFunction: Bool { raw.acceptsFunction }
    /// A type parameter of a generic signature (`Element`).
    var isTypeParameter: Bool { if case .parameter = raw { true } else { false } }
    /// A key path from `root` to `value`.
    static func keyPath(_ root: ValueType, _ value: ValueType) -> ValueType { ValueType(.keyPath(root.raw, value.raw)) }
    /// The root and value of a key path type.
    var keyPathParts: (root: ValueType, value: ValueType)? {
        if case .keyPath(let root, let value) = raw { (ValueType(root), ValueType(value)) } else { nil }
    }
}

/// A parameter of a signature, as the checker sees it.
struct ParameterShape: Sendable {
    var raw: Parameter
    init(_ raw: Parameter) { self.raw = raw }

    var label: String? { raw.label }
    var name: String { raw.name }
    var type: ValueType {
        get { ValueType(raw.type) }
        set { raw.type = newValue.raw }
    }
    var isVariadic: Bool { raw.variadic }
    /// The parameter a pipe feeds (`@input`).
    var isInput: Bool { raw.isInput }
    var shortFlag: Character? { raw.shortFlag }
    /// Whether the call may leave it out: it has a default, here or in Swift.
    var hasDefault: Bool { raw.defaultValue != nil || raw.externalDefault != nil }
    /// A switch that is on unless said otherwise: `--no-` turns it off.
    var defaultsToTrue: Bool {
        if case .literal(.bool(true))? = raw.defaultValue { true } else { false }
    }
    /// Whether a closure can be given for it.
    var acceptsFunction: Bool { raw.type.acceptsFunction }
    var isOptional: Bool { if case .optional = raw.type { true } else { false } }
}

/// What a function, method or initializer is called with and gives.
struct Signature {
    var raw: TypeChecker.Signature
    init(_ raw: TypeChecker.Signature) { self.raw = raw }

    var name: String { raw.name }
    var parameters: [ParameterShape] {
        get { raw.parameters.map(ParameterShape.init) }
        set { raw.parameters = newValue.map(\.raw) }
    }
    var returns: ValueType {
        get { ValueType(raw.returns) }
        set { raw.returns = newValue.raw }
    }
    var isThrowing: Bool { raw.isThrowing }
    var isMutating: Bool { raw.isMutating }
    /// Its position among the overloads of the name.
    var index: Int { raw.index }
    /// Its type parameters and what each must conform to.
    var generics: [String: [String]] { raw.generics }

    /// How it reads in a list of candidates: `name(_ a: Int, label b: String) -> Bool`.
    var rendered: String {
        Function(name: raw.name, parameters: raw.parameters, returnType: raw.returns, body: .native { _, _ in .nothing },
                 isThrowing: raw.isThrowing, generics: raw.generics).signature
    }

    /// This signature with the first `@input` parameter removed, as a piped call sees it.
    var withoutInput: Signature {
        var signature = self
        signature.raw.parameters.removeAll(where: \.isInput)
        return signature
    }
}

/// An enum, as a command line reads a word for it: which cases a word can name, and whether its raw values can be named.
struct EnumShape {
    var plainCases: Set<String>
    var hasRawValues: Bool
}

/// Where a name is an enum the program declares, which has no runtime type yet to read cases from.
typealias EnumRule = (String) -> EnumShape?
