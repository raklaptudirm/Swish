import Foundation
import SwishKit

/// Builtins written in Swift. They're ordinary functions to the rest of
/// the shell: the same flags, help, overloads and streaming as Swish ones.

/// A library of functions and types written in Swift and bridged by
/// `swish-bridge`: the core's own is `Library.standard`; a host has others
/// (the shell's `ls` and `ps` are `SwishShellLibrary`).
package struct Library {
    /// Its structs and enums, as Swish source, declared with the prelude.
    package var types: String
    /// The columns a table starts with, for its types that say so.
    package var columns: [String: [DisplayColumn]]
    /// How its enums' cases are styled, by case name.
    package var enumStyles: [String: @Sendable (String) -> DisplayStyle?]
    package var functions: [BridgedMember]

    package init(
        types: String, columns: [String: [DisplayColumn]],
        enumStyles: [String: @Sendable (String) -> DisplayStyle?], functions: [BridgedMember]
    ) {
        self.types = types
        self.columns = columns
        self.enumStyles = enumStyles
        self.functions = functions
    }

    /// The core's own: conversions (`from`, `to`, `table`, `list`) and styles.
    package nonisolated(unsafe) static let standard = Library(
        types: Bridge.standardTypes, columns: Bridge.standardColumns,
        enumStyles: Bridge.standardEnumStyles, functions: Bridge.standardFunctions
    )
}

extension Interpreter {
    /// `provided` are bodies for prelude functions the host owns (the shell's
    /// `help`, which describes its builtins and programs); `libraries` are
    /// the host's own bridged functions and types, beside the core's.
    package func installBuiltinFunctions(providing provided: [String: FunctionBody] = [:], libraries added: [Library] = []) {
        libraries = [.standard] + added
        scopes[0].bindings["jobs"] = Binding(value: .nothing, mutable: false, special: .jobs)
        scopes[0].bindings["args"] = Binding(value: .list([]), mutable: false)
        installPrelude(providing: provided)
        installJSONAccess()
        installStandardFunctions()
        // Swift's types by name, for their initializers and static members.
        for name in Bridge.types.keys {
            scopes[0].bindings[name] = Binding(value: .object(BridgedTypeName(name)), mutable: false)
        }
    }

    /// The shell's own functions, written in Swift (SwishStandardLibrary) and
    /// bridged: `pwd`, `readLine`. Each is an ordinary function to the rest
    /// of the shell, with its flags, help and overloads.
    private func installStandardFunctions() {
        for member in libraries.flatMap(\.functions) {
            let function = Function(
                name: member.name, parameters: member.parameters, returnType: member.returns, body: member.body,
                documentation: Documentation(summary: member.summary, parameters: member.parameterDocs),
                isThrowing: member.isThrowing, isRethrowing: member.isRethrowing, generics: member.generics
            )
            scopes[0].declare(function, named: member.name)
        }
    }

    /// What the checker writes JSON access into: `json.name` is
    /// `$json(json, "name")`, `json.port?.int` is `$jsonAs(…, "int")`. Both
    /// give nil for nil, a missing field, or a value of another kind.
    private func installJSONAccess() {
        let field = Function(name: "$json", parameters: [
            Parameter(label: nil, name: "value", type: .any), Parameter(label: nil, name: "key", type: .any),
        ], returnType: nil, body: .native { _, args in
            switch (args["value"]!, args["key"]!) {
            case (.record(let record), .string(let key)): record[key] ?? .nothing
            case (.dictionary(let dictionary), let key): dictionary[key] ?? .nothing
            case (.list(let items), .int(let index)): items.indices.contains(index) ? items[index] : .nothing
            default: .nothing
            }
        })
        let accessor = Function(name: "$jsonAs", parameters: [
            Parameter(label: nil, name: "value", type: .any), Parameter(label: nil, name: "kind", type: .string),
        ], returnType: nil, body: .native { _, args in
            let value = args["value"]!
            guard case .string(let kind) = args["kind"]! else { return .nothing }
            switch (kind, value) {
            case ("string", .string), ("int", .int), ("double", .double), ("bool", .bool), ("array", .list): return value
            case ("double", .int(let n)): return .double(Double(n))
            case ("int", .double(let d)) where d == d.rounded() && abs(d) < 9e15: return .int(Int(d))
            case ("object", .record(let record)):
                return .dictionary(ValueDictionary(record.map { (Value.string($0.key), $0.value) }))
            case ("object", .dictionary): return value
            case ("isNull", _): return .bool(value == .nothing)
            default: return .nothing
            }
        })
        for function in [field, accessor] {
            scopes[0].bindings[function.name!] = Binding(
                value: .function(OverloadSet(name: function.name!, candidates: [function])), mutable: false
            )
        }
    }

    /// Each builtin's body, by name, for the prelude's declarations; a
    /// sequence method's also says how it reads the sequence: each item
    /// (`filter`), or all of them (`sorted`).
    package func builtinBodies(providing provided: [String: FunctionBody]) -> [String: (body: FunctionBody, input: Parameter?)] {
        var bodies: [String: (body: FunctionBody, input: Parameter?)] = [:]
        for function in [members()] {
            bodies[function.name!] = (function.body, nil)
        }
        for (name, body) in provided { bodies[name] = (body, nil) }
        for method in [select()] {
            let input = method.parameters.first(where: \.isInput)!
            // Each item is an Element; all of them, a list of Elements.
            let type: TypeAnnotation = input.type.isList ? .list(.parameter("Element")) : .parameter("Element")
            bodies["Sequence." + method.name!] = (method.body, Parameter(label: nil, name: input.name, type: type, isInput: true))
        }
        return bodies
    }

    /// A case of an enum the prelude or the standard library module
    /// declares: `FileType.directory`.
    package func declaredCase(_ type: String, _ name: String) -> Value {
        .enumValue(EnumValue(type: enumType(named: type)!, name: name))
    }
}

// MARK: - Declaring builtins

extension Function {
    /// A builtin written in Swift, with its documentation.
    package static func builtin(
        _ name: String, _ summary: String, _ parameters: [Parameter],
        docs: [String: String] = [:], _ body: FunctionBody
    ) -> Function {
        Function(
            name: name, parameters: parameters, returnType: nil, body: body,
            documentation: Documentation(summary: summary, parameters: docs)
        )
    }
}

extension Parameter {
    /// An argument by position.
    package static func positional(_ name: String, _ type: TypeAnnotation, default value: Value? = nil, variadic: Bool = false) -> Parameter {
        Parameter(label: nil, name: name, type: type, variadic: variadic, defaultValue: value.map(Expr.literal))
    }

    /// A labeled argument: a flag on the command line.
    package static func option(_ label: String, _ type: TypeAnnotation, default value: Value? = nil, short: Character? = nil) -> Parameter {
        Parameter(label: label, name: label, type: type, defaultValue: value.map(Expr.literal), shortFlag: short)
    }

    /// What's piped in.
    package static func input(_ name: String, _ type: TypeAnnotation) -> Parameter {
        Parameter(label: nil, name: name, type: type, isInput: true)
    }
}

extension Dictionary where Key == String, Value == SwishKit.Value {
    /// A String or list-of-Strings argument as an array; empty if absent.
    package func strings(_ key: String) -> [String] {
        switch self[key] {
        case .string(let text)?: [text]
        case .list(let items)?: items.map(\.description)
        default: []
        }
    }
}
