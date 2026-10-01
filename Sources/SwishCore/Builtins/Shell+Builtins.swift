import Foundation
import SwishKit

/// Builtins written in Swift. They're ordinary functions to the rest of
/// the shell: the same flags, help, overloads and streaming as Swish ones.

extension Shell {
    func installBuiltinFunctions() {
        scopes[0].bindings["env"] = Binding(value: .nothing, mutable: false, special: .environment)
        scopes[0].bindings["FileType"] = Binding(value: .object(Shell.fileType), mutable: false)
        scopes[0].bindings["JobState"] = Binding(value: .object(Shell.jobState), mutable: false)
        scopes[0].bindings["TextStyle"] = Binding(value: .object(Shell.textStyle), mutable: false)
        // In declaration order, so `ls | sorted --by type` puts files first.
        for type in [Shell.fileType, Shell.jobState, Shell.textStyle] {
            enumConformances[ObjectIdentifier(type)] = ["Equatable", "Hashable", "Comparable"]
        }
        scopes[0].bindings["jobs"] = Binding(value: .nothing, mutable: false, special: .jobs)
        scopes[0].bindings["args"] = Binding(value: .list([]), mutable: false)
        installPrelude()
        installJSONAccess()
        // Swift's types by name, for their initializers and static members.
        for name in Bridge.types.keys {
            scopes[0].bindings[name] = Binding(value: .object(BridgedTypeName(name)), mutable: false)
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
    func builtinBodies() -> [String: (body: FunctionBody, input: Parameter?)] {
        var bodies: [String: (body: FunctionBody, input: Parameter?)] = [:]
        for function in [ls(), pwd(), history(), readLine(), ps(), from(), to(), table(), list(), members(), help(), with()] {
            bodies[function.name!] = (function.body, nil)
        }
        for method in [sorted(), filter(), map(), compactMap(), prefix(), reversed(), count(), uniqued(), select(), get()] {
            let input = method.parameters.first(where: \.isInput)!
            // Each item is an Element; all of them, a list of Elements.
            let type: TypeAnnotation = input.type.isList ? .list(.parameter("Element")) : .parameter("Element")
            bodies["Sequence." + method.name!] = (method.body, Parameter(label: nil, name: input.name, type: type, isInput: true))
        }
        return bodies
    }

    /// `with(env: ["EDITOR": "vim"]) { git commit }`: runs the closure with
    /// environment variables set, then puts them back.
    private func with() -> Function {
        .builtin(
            "with", "Runs a closure with environment variables set.",
            [.option("env", .dictionary(.string, .string)), .positional("body", .function)],
            .native { shell, args in
                guard case .dictionary(let variables) = args["env"] else { return .nothing }
                let pairs = variables.map { ($0.key.description, $0.value.description) }
                return try shell.withEnvironment(pairs) { try shell.call(args["body"]!, with: []) }
            }
        )
    }

    /// What kind of entry `ls` found: `ls | where { $0.type == .directory }`.
    static let fileType = EnumType(name: "FileType", cases: ["file", "directory", "symlink", "other"].map { .init(name: $0) })

    /// A job's `state`.
    static let jobState = EnumType(name: "JobState", cases: ["running", "stopped", "done", "cancelled"].map { .init(name: $0) })

    /// What `String.styled` can make text, with each one's terminal code.
    static let textStyleCodes: KeyValuePairs = [
        "bold": "1", "dim": "2", "italic": "3", "underline": "4",
        "red": "31", "green": "32", "yellow": "33", "blue": "34", "magenta": "35", "cyan": "36", "white": "37", "gray": "90",
    ]
    static let textStyle = EnumType(name: "TextStyle", cases: textStyleCodes.map { .init(name: $0.key) })
}

// MARK: - Declaring builtins

extension Function {
    /// A builtin written in Swift, with its documentation.
    static func builtin(
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
    static func positional(_ name: String, _ type: TypeAnnotation, default value: Value? = nil, variadic: Bool = false) -> Parameter {
        Parameter(label: nil, name: name, type: type, variadic: variadic, defaultValue: value.map(Expr.literal))
    }

    /// A labeled argument: a flag on the command line.
    static func option(_ label: String, _ type: TypeAnnotation, default value: Value? = nil, short: Character? = nil) -> Parameter {
        Parameter(label: label, name: label, type: type, defaultValue: value.map(Expr.literal), shortFlag: short)
    }

    /// What's piped in.
    static func input(_ name: String, _ type: TypeAnnotation) -> Parameter {
        Parameter(label: nil, name: name, type: type, isInput: true)
    }
}

extension Dictionary where Key == String, Value == SwishKit.Value {
    /// A String or list-of-Strings argument as an array; empty if absent.
    func strings(_ key: String) -> [String] {
        switch self[key] {
        case .string(let text)?: [text]
        case .list(let items)?: items.map(\.description)
        default: []
        }
    }
}
