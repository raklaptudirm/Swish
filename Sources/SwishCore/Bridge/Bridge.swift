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
    nonisolated(unsafe) static let types: [String: BridgedType] = Dictionary(uniqueKeysWithValues: (standardLibrary + system).map { ($0.name, $0) })

    /// Whether a string literal can be one of the type: `FilePath`.
    static func isStringLiteral(_ typeName: String) -> Bool {
        types[typeName]?.conformances["ExpressibleByStringLiteral"] != nil
    }

    /// The type's `init(stringLiteral:)`, and its label, if it's bridged.
    static func literalInitializer(_ typeName: String) -> (Int, String?)? {
        types[typeName]?.members.firstIndex {
            $0.kind == .initializer && $0.parameters.count == 1 && $0.parameters[0].label == "stringLiteral"
        }.map { ($0, "stringLiteral") }
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
        return try invoke(function, with: bindings)
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
    let members: [BridgedMember]
}

struct BridgedMember {
    enum Kind { case method, property, initializer }

    let kind: Kind
    let name: String
    let isStatic: Bool
    let parameters: [Parameter]
    let returns: TypeAnnotation
    let generics: [String: [String]]
    let isThrowing: Bool
    let isRethrowing: Bool
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
        return text.map { SwiftValue.make($0, as: "Character") }
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

    private static func iterator<S: Sequence>(_ sequence: S) -> AnyIterator<Value> {
        var iterator = sequence.makeIterator()
        return AnyIterator {
            guard let next = iterator.next() else { return nil }
            if let value = next as? Value { return value }
            // A Substring's Characters.
            if let character = next as? Character { return SwiftValue.make(character, as: "Character") }
            // By the name Swish writes it with: FilePath.Component, not Component.
            let name = String(reflecting: type(of: next))
            let module = name.prefix { $0 != "." }
            return SwiftValue.make(next, as: module == "Swift" || module == "SystemPackage" ? String(name.dropFirst(module.count + 1)) : name)
        }
    }
}

/// A Character, or a String of one: `"a,b".split(separator: ",")`.
func bridgeCharacter(_ value: Value) throws -> Character {
    if case .string(let text) = value, text.count == 1 { return text.first! }
    return try SwiftValue.unbox(Character.self, value)
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
