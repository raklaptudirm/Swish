@_spi(Layer) import Swiit

extension Interpreter {
    /// Registers parsed JSON as a type whose values are whatever they parsed
    /// as (lists, records, scalars), read by field (`json.name`,
    /// `json["name"]`) or position (`json[0]`), each giving `JSON?`: the
    /// checker writes each access into `jsonField(json, "name")`, and a view like
    /// `json.port?.int` into `jsonInt(…)`. All give nil for nil, a missing
    /// field, or a value of another kind. The functions are the library's
    /// (`Library.shell`), typed in its declarations like any others.
    func installJSON() {
        let json = TypeAnnotation.named("JSON")
        dynamicTypes["JSON"] = DynamicType(read: .optional(json), write: .optional(json), plain: PlainDynamic(
            field: "jsonField",
            views: [
                "string": .init(function: "jsonString", type: .optional(.string)),
                "int": .init(function: "jsonInt", type: .optional(.int)),
                "double": .init(function: "jsonDouble", type: .optional(.double)),
                "bool": .init(function: "jsonBool", type: .optional(.bool)),
                "array": .init(function: "jsonArray", type: .optional(.list(json))),
                "object": .init(function: "jsonObject", type: .optional(.dictionary(.string, json))),
                "isNull": .init(function: "jsonIsNull", type: .bool),
            ],
            element: json
        ))
    }
}

extension Library {
    /// The bodies of the JSON functions the declarations name.
    static var jsonBodies: [String: (body: FunctionBody, input: Parameter?)] {
        func view(_ read: @escaping @Sendable (Value) -> Value) -> (body: FunctionBody, input: Parameter?) {
            (.native { _, args in read(args["value"] ?? .nothing) }, nil)
        }
        return [
            "jsonField": (.native { _, args in
                switch (args["value"] ?? .nothing, args["key"] ?? .nothing) {
                case (.record(let record), .string(let key)): record[key] ?? .nothing
                case (.dictionary(let dictionary), let key): dictionary[key] ?? .nothing
                case (.list(let items), .int(let index)): items.indices.contains(index) ? items[index] : .nothing
                default: .nothing
                }
            }, nil),
            "jsonString": view { if case .string = $0 { $0 } else { .nothing } },
            "jsonInt": view {
                switch $0 {
                case .int: $0
                case .double(let d) where d == d.rounded() && abs(d) < 9e15: .int(Int(d))
                default: .nothing
                }
            },
            "jsonDouble": view {
                switch $0 {
                case .double: $0
                case .int(let n): .double(Double(n))
                default: .nothing
                }
            },
            "jsonBool": view { if case .bool = $0 { $0 } else { .nothing } },
            "jsonArray": view { if case .list = $0 { $0 } else { .nothing } },
            "jsonObject": view {
                switch $0 {
                case .record(let record): .dictionary(ValueDictionary(record.map { (Value.string($0.key), $0.value) }))
                case .dictionary: $0
                default: .nothing
                }
            },
            "jsonIsNull": view { .bool($0 == .nothing) },
        ]
    }
}
