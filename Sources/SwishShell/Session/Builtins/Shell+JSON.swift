import Swiit

extension Shell {
    /// Registers parsed JSON as a type whose values are whatever they parsed
    /// as (lists, records, scalars), read by field (`json.name`,
    /// `json["name"]`) or position (`json[0]`), each giving `JSON?`: the
    /// checker writes each access into `jsonField(json, "name")`, and a view like
    /// `json.port?.int` into `jsonInt(…)`. All give nil for nil, a missing
    /// field, or a value of another kind. The functions are the shell's
    /// (Resources/Prelude.swift), typed in its declarations like any others.
    func installJSON() {
        let json = ValueType.named("JSON")
        interpreter.registerDynamic(named: "JSON", field: "jsonField", views: [
            "string": ("jsonString", .optional(.string)),
            "int": ("jsonInt", .optional(.int)),
            "double": ("jsonDouble", .optional(.double)),
            "bool": ("jsonBool", .optional(.bool)),
            "array": ("jsonArray", .optional(.list(json))),
            "object": ("jsonObject", .optional(.dictionary(.string, json))),
            "isNull": ("jsonIsNull", .bool),
        ])
    }

    /// The bodies of the JSON functions the declarations name.
    var jsonBodies: [String: @Sendable ([String: Value]) throws -> Value] {
        func view(_ read: @escaping @Sendable (Value) -> Value) -> @Sendable ([String: Value]) throws -> Value {
            { arguments in read(arguments["value"] ?? .null) }
        }
        return [
            "jsonField": { arguments in
                let value = arguments["value"] ?? .null, key = arguments["key"] ?? .null
                switch value.kind {
                case .structure, .tuple:
                    guard let name = key.cast(to: String.self) else { return .null }
                    return value.field(name) ?? .null
                case .dictionary: return value.entries?[key] ?? .null
                case .list:
                    guard let index = key.cast(to: Int.self), let items = value.cast(to: [Value].self) else { return .null }
                    return items.indices.contains(index) ? items[index] : .null
                default: return .null
                }
            },
            "jsonString": view { $0.kind == .string ? $0 : .null },
            "jsonInt": view {
                if $0.kind == .int { return $0 }
                if let d = $0.cast(to: Double.self), d == d.rounded(), abs(d) < 9e15 { return Value(Int(d)) }
                return .null
            },
            "jsonDouble": view {
                if $0.kind == .double { return $0 }
                if let n = $0.cast(to: Int.self) { return Value(Double(n)) }
                return .null
            },
            "jsonBool": view { $0.kind == .bool ? $0 : .null },
            "jsonArray": view { $0.kind == .list ? $0 : .null },
            "jsonObject": view {
                switch $0.kind {
                case .structure, .tuple: $0.fields.map { Value(ValueDictionary($0.entries.map { (Value($0.key), $0.value) })) } ?? .null
                case .dictionary: $0
                default: .null
                }
            },
            "jsonIsNull": view { Value($0.kind == .nothing) },
        ]
    }
}
