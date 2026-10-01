import Foundation
import SwishKit

/// Swift's own types and members, as Swish sees them: read from the
/// standard library's symbol graph (and swift-system's, for FilePath) by
/// `swish-bridge`, which writes StandardLibrary.swift and SystemPackage.swift
/// beside this file (see `run bridge` in Tasks.swish
/// and docs/design/swift-interop.md). Each member comes with its signature,
/// for the checker, and its glue, which calls Swift.
enum Bridge {
    /// The bridged types, by the name Swish writes them with.
    nonisolated(unsafe) static let types: [String: BridgedType] = Dictionary(uniqueKeysWithValues: (standardLibrary + system).map {
        ($0.name, $0.adding(extensions[$0.name] ?? []))
    })

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
        let found: (String, [String: TypeAnnotation])? = switch annotation {
        case .string: ("String", [:])
        case .int: ("Int", [:])
        case .double: ("Double", [:])
        case .bool: ("Bool", [:])
        case .list(let element): ("Array", ["Element": element])
        // A command's output has its lines' members: `$(ls).sorted()`.
        case .output: ("Array", ["Element": .string])
        case .optional(let wrapped): ("Optional", ["Wrapped": wrapped])
        case .dictionary(let key, let value): ("Dictionary", ["Key": key, "Value": value])
        case .named(let name): (name, [:])
        case .generic(let name, let arguments):
            (name, Dictionary(uniqueKeysWithValues: zip(types[name]?.genericParameters ?? [], arguments)))
        default: nil
        }
        guard let (name, bindings) = found, let type = types[name] else { return nil }
        return (type, bindings)
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

extension Bridge {
    /// A bridged type's members that can be a pipeline stage: those named
    /// `name` that read their receiver without changing it.
    static func stageMembers(_ typeName: String, _ name: String) -> [(index: Int, member: BridgedMember)] {
        (types[typeName]?.members ?? []).enumerated().filter { _, member in
            member.name == name && !member.isStatic && !member.isMutating && (member.kind == .method || member.kind == .property)
        }.map { (index: $0.offset, member: $0.element) }
    }

    /// A parameter's type as a word on the command line converts to it: a
    /// generic parameter as what it's bound to (Element as Int).
    static func wordType(_ type: TypeAnnotation, _ bindings: [String: TypeAnnotation]) -> TypeAnnotation {
        switch type {
        case .parameter(let name): bindings[name].flatMap { $0 == .unknown || $0 == .any ? nil : $0 } ?? type
        case .optional(let wrapped): .optional(wordType(wrapped, bindings))
        case .list(let element): .list(wordType(element, bindings))
        default: type
        }
    }

    /// The receiver of a member as a stage's input: the items collected
    /// (for `.value`, the one item), or each one.
    static func receiverParameter(_ receiver: StageReceiver, element: TypeAnnotation = .any) -> Parameter {
        var parameter = Parameter(label: nil, name: "self", type: receiver == .each ? element : .list(element))
        parameter.isInput = true
        return parameter
    }
}

extension Bridge {
    /// Every bridged member's name that can be a stage, for highlighting.
    nonisolated(unsafe) static let stageNames: Set<String> = Set(types.values.flatMap { type in
        type.members.filter { !$0.isStatic && !$0.isMutating && ($0.kind == .method || $0.kind == .property) }.map(\.name)
    })
}

extension Shell {
    /// Whether some type has a member called `name` that a stage could
    /// call: a Swift type's, a struct's in scope, or a job's.
    func isMemberName(_ name: String) -> Bool {
        if Bridge.stageNames.contains(name) || Job.memberNames.contains(name) { return true }
        return scopes.contains { scope in
            scope.bindings.values.contains { binding in
                if case .object(let type as StructType) = binding.value { type.methods[name] != nil } else { false }
            }
        }
    }

    /// `xs | max` or `names | uppercased`: a bridged type's members named
    /// `name`, as functions whose input is the receiver, so a stage runs
    /// them as it runs any function.
    func bridgedStage(
        _ typeName: String, _ name: String, receiver: StageReceiver, bindings: [String: TypeAnnotation] = [:]
    ) -> OverloadSet? {
        let members = Bridge.stageMembers(typeName, name)
        guard !members.isEmpty else { return nil }
        return OverloadSet(name: name, candidates: members.map { _, member in
            let parameters = member.parameters.map { parameter -> Parameter in
                var parameter = parameter
                parameter.type = Bridge.wordType(parameter.type, bindings)
                return parameter
            }
            var body = member.body
            if receiver == .value, case .native(let call) = body {
                // Collected like a sequence's items, so what it gives flows
                // as items too; but it's the one value that's the receiver.
                body = .native { shell, args in
                    var args = args
                    if case .list(let items)? = args["self"] { args["self"] = items.first ?? .nothing }
                    return try call(shell, args)
                }
            }
            return Function(name: name, parameters: [Bridge.receiverParameter(receiver)] + parameters,
                            returnType: nil, body: body, isThrowing: member.isThrowing,
                            isRethrowing: member.isRethrowing, generics: member.generics)
        })
    }
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

extension Shell {
    /// Runs a bridged member: binds its arguments as a call binds them, and
    /// its glue does the rest.
    func runBridged(_ typeName: String, _ index: Int, receiver: Expr?, _ arguments: [Argument]) throws -> Value {
        guard let member = Bridge.types[typeName]?.members[index] else { throw RuntimeError("no bridged member #\(index) of \(typeName)") }
        let function = Function(name: member.name, parameters: member.parameters, returnType: nil, body: member.body)
        var bindings = try bind(arguments, to: function).bindings
        if let receiver {
            let value = try evaluate(receiver)
            // Through `?.`: nil stays nil. (Optional's own members take nil.)
            if value == .nothing && typeName != "Optional" { return .nothing }
            bindings["self"] = value
        }
        guard member.isMutating, let receiver else { return try invoke(function, with: bindings) }
        // `xs.append(1)`: Swift changes a copy, which goes back into `xs`.
        guard case .list(let parts) = try invoke(function, with: bindings), parts.count == 2 else {
            throw RuntimeError("\(typeName).\(member.name) gave back no receiver")
        }
        try mutate(receiver, by: member.name) { _ in parts[1] }
        return parts[0]
    }
}

extension Shell {
    /// A Swift property of a value, looked up when it runs, as a key path
    /// does; nil if its type has none of that name.
    func bridgedProperty(_ name: String, of value: Value) throws -> Value? {
        let typeName: String? = switch value {
        case .string: "String"
        case .int: "Int"
        case .double: "Double"
        case .bool: "Bool"
        case .list: "Array"
        case .dictionary: "Dictionary"
        case .object(let box as SwiftValue): box.typeName
        default: nil
        }
        guard let typeName, let member = Bridge.types[typeName]?.members.first(where: {
            $0.kind == .property && !$0.isStatic && $0.name == name
        }) else { return nil }
        let function = Function(name: member.name, parameters: [], returnType: nil, body: member.body)
        return try invoke(function, with: ["self": value])
    }
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

    /// With Swish's own members after Swift's.
    func adding(_ extra: [BridgedMember]) -> BridgedType {
        BridgedType(name: name, genericParameters: genericParameters, conformances: conformances,
                    associatedTypes: associatedTypes, parse: parse, literal: literal, arrayLiteral: arrayLiteral,
                    members: members + extra)
    }
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
    /// Converts the arguments (and `self`), calls Swift, and converts back.
    let body: FunctionBody
}

// MARK: Conversions the glue uses

/// A list's items, or an Output's lines.
func bridgeList(_ value: Value) throws -> [Value] {
    switch value {
    case .list(let items): return items
    case .output(let output): return output.lines.map(Value.string)
    default: throw SwishError("expected a list, not \(value.typeName)")
    }
}

/// A dictionary as Swift's, which is what it holds.
func bridgeDictionary(_ value: Value) throws -> [Value: Value] {
    guard case .dictionary(let dictionary) = value else { throw SwishError("expected a dictionary, not \(value.typeName)") }
    return dictionary.dictionary
}

/// Swift's dictionary as Swish's.
func bridgeDictionary(_ dictionary: [Value: Value]) -> Value {
    .dictionary(ValueDictionary(dictionary))
}

/// A tuple's elements, by label or position, made into a Swift tuple.
func bridgeTuple<T>(_ value: Value, _ labels: [String?], _ make: ([Value]) throws -> T) throws -> T {
    guard case .record(let record) = value, record.typeName == nil, record.count == labels.count else {
        throw SwishError("expected a tuple of \(labels.count), not \(value.typeName)")
    }
    return try make(labels.enumerated().map { index, label in
        label.flatMap { record[$0] } ?? record[record.keys[index]]!
    })
}

/// A Swift tuple as Swish's, from its elements' labels and values.
func bridgeTuple<T>(_ tuple: T, _ elements: (T) -> [(String?, Value)]) -> Value {
    var record = Record()
    for (index, (label, value)) in elements(tuple).enumerated() { record[label ?? String(index)] = value }
    return .record(record)
}

/// The items of any sequence, for a Swift parameter that takes one: a
/// String's Characters, a dictionary's (key, value) pairs, or what
/// `Shell.items(of:)` gives.
func bridgeSequence(_ value: Value) throws -> [Value] {
    switch value {
    case .string(let text):
        return Array(Shell.iterator(text))
    case .dictionary(let dictionary):
        return dictionary.map { bridgeTuple(($0.key, $0.value)) { [("key", $0.0), ("value", $0.1)] } }
    default:
        guard let items = Shell.items(of: value) else { throw SwishError("expected a sequence, not \(value.typeName)") }
        return Array(items)
    }
}

/// A range with bounds of a Swift type, from Swish's range of values.
func bridgeRange<Bound: Comparable>(_ value: Value, _ bound: (Value) throws -> Bound) throws -> Range<Bound> {
    let range = try SwiftValue.unbox(Range<Value>.self, value)
    return Range(uncheckedBounds: (lower: try bound(range.lowerBound), upper: try bound(range.upperBound)))
}

func bridgeClosedRange<Bound: Comparable>(_ value: Value, _ bound: (Value) throws -> Bound) throws -> ClosedRange<Bound> {
    let range = try SwiftValue.unbox(ClosedRange<Value>.self, value)
    return ClosedRange(uncheckedBounds: (lower: try bound(range.lowerBound), upper: try bound(range.upperBound)))
}

/// A Swift value boxed as Swish holds it, converted first (a `Set<Int>` to
/// a `Set<Value>`).
func bridgeBox<T, Boxed>(_ value: T, as typeName: String, _ convert: (T) -> Boxed) -> Value {
    SwiftValue.make(convert(value), as: typeName)
}

func bridgeBox<T, Boxed: Hashable>(_ value: T, as typeName: String, _ convert: (T) -> Boxed) -> Value {
    SwiftValue.make(convert(value), as: typeName)
}

/// `lower...upper` or `lower..<upper`, of any values that compare.
func makeRange(_ op: BinaryOperator, _ lower: Value, _ upper: Value) throws -> Value {
    guard lower <= upper else { throw RuntimeError("range \(lower)\(op.rawValue)\(upper) has its bounds reversed") }
    if op == .closedRange { return SwiftValue.make(ClosedRange(uncheckedBounds: (lower: lower, upper: upper)), as: "ClosedRange") }
    return SwiftValue.make(Range(uncheckedBounds: (lower: lower, upper: upper)), as: "Range")
}

extension Shell {
    /// The items of a list, an Output's lines, or a Swift sequence Swish
    /// holds (a Set, a range of Ints, a dictionary's keys), one at a time,
    /// so a range of a billion never becomes a list; nil for anything else.
    static func items(of value: Value) -> AnyIterator<Value>? {
        switch value {
        case .list(let items):
            return AnyIterator(items.makeIterator())
        case .output(let output):
            return AnyIterator(output.lines.lazy.map(Value.string).makeIterator())
        case .object(let box as SwiftValue):
            if let range = box.value as? ClosedRange<Value> {
                guard case .int(let lower) = range.lowerBound, case .int(let upper) = range.upperBound else { return nil }
                return AnyIterator((lower...upper).lazy.map(Value.int).makeIterator())
            }
            if let range = box.value as? Range<Value> {
                guard case .int(let lower) = range.lowerBound, case .int(let upper) = range.upperBound else { return nil }
                return AnyIterator((lower..<upper).lazy.map(Value.int).makeIterator())
            }
            guard let sequence = box.value as? any Sequence else { return nil }
            return iterator(sequence)
        default:
            return nil
        }
    }

    /// A Swift sequence's elements as Swish values, boxed by their type's name.
    static func iterator<S: Sequence>(_ sequence: S) -> AnyIterator<Value> {
        var iterator = sequence.makeIterator()
        return AnyIterator {
            guard let next = iterator.next() else { return nil }
            if let value = next as? Value { return value }
            // By the name Swish writes it with, without its module:
            // FilePath.Component, not SystemPackage.FilePath.Component.
            let name = String(reflecting: type(of: next))
            let unqualified = String(name.drop { $0 != "." }.dropFirst())
            return SwiftValue.make(next, as: Bridge.types[unqualified] != nil ? unqualified : name)
        }
    }
}

/// A Swish function as a Swift closure.
func bridgeClosure(_ shell: Shell, _ function: Value) -> ([Value]) throws -> Value {
    { arguments in try shell.call(function, with: arguments) }
}

/// Swish's values sort as `order(comparedTo:)` has it, so Swift's generic
/// algorithms that need Comparable elements work on them.
extension Value: @retroactive Comparable {
    public static func < (lhs: Value, rhs: Value) -> Bool {
        lhs.order(comparedTo: rhs) == .orderedAscending
    }
}
