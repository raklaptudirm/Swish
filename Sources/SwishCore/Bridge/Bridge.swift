import Foundation
import SwishKit

/// Swift's own types and members, as Swish sees them: read from the
/// standard library's symbol graph by `swish-bridge`, which writes
/// StandardLibrary.swift beside this file (see scripts/generate-bridge.sh
/// and docs/design/swift-interop.md). Each member comes with its signature,
/// for the checker, and its glue, which calls Swift.
enum Bridge {
    /// The bridged types, by the name Swish writes them with.
    nonisolated(unsafe) static let types: [String: BridgedType] = Dictionary(uniqueKeysWithValues: standardLibrary.map { ($0.name, $0) })
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
            // Through `?.`: nil stays nil.
            if value == .nothing { return .nothing }
            bindings["self"] = value
        }
        return try invoke(function, with: bindings)
    }
}

struct BridgedType {
    /// `String`, `Substring`, `Array`.
    let name: String
    /// A generic type's parameters: `Element` for Array.
    let genericParameters: [String]
    /// The protocols it conforms to, of those Swish knows.
    let conformances: [String]
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
