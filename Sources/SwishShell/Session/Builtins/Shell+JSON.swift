@_spi(Shell) import Swiit
import SwishKit

extension Interpreter {
    /// Registers parsed JSON as a type whose values are whatever they parsed
    /// as (lists, records, scalars), read by field (`json.name`,
    /// `json["name"]`) or position (`json[0]`), each giving `JSON?`: the
    /// checker writes each access into `$json(json, "name")`, and a view like
    /// `json.port?.int` into `$jsonAs(…, "int")`. Both give nil for nil, a
    /// missing field, or a value of another kind.
    func installJSON() {
        let json = TypeAnnotation.named("JSON")
        dynamicTypes["JSON"] = DynamicType(read: .optional(json), write: .optional(json), plain: PlainDynamic(
            field: "$json", view: "$jsonAs",
            views: [
                "string": .optional(.string), "int": .optional(.int), "double": .optional(.double), "bool": .optional(.bool),
                "array": .optional(.list(json)), "object": .optional(.dictionary(.string, json)), "isNull": .bool,
            ],
            element: json
        ))
        installJSONAccess()
    }

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
}
