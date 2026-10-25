import Swiit

extension Shell {
    /// The bodies of the JSON functions the prelude's `JSON` calls.
    var jsonBodies: [String: @Sendable ([String: Value]) throws -> Value] {
        func view(
            _ read: @escaping @Sendable (Value) -> Value
        ) -> @Sendable ([String: Value]) throws -> Value {
            { arguments in read(arguments["raw"] ?? .null) }
        }
        return [
            "jsonField": { arguments in
                let value = arguments["raw"] ?? .null, key = arguments["key"] ?? .null
                switch value.kind {
                case .structure, .tuple:
                    guard let name = key.cast(to: String.self) else { return .null }
                    return JSON.wrapping(value.field(name))
                case .dictionary: return JSON.wrapping(value.entries?[key])
                case .list:
                    guard let index = key.cast(to: Int.self),
                        let items = value.cast(to: [Value].self)
                    else {
                        return .null
                    }
                    return JSON.wrapping(items.indices.contains(index) ? items[index] : nil)
                default: return .null
                }
            },
            "jsonString": view { $0.kind == .string ? $0 : .null },
            "jsonInt": view {
                if $0.kind == .int { return $0 }
                if let d = $0.cast(to: Double.self), d == d.rounded(), abs(d) < 9e15 {
                    return Value(Int(d))
                }
                return .null
            },
            "jsonDouble": view {
                if $0.kind == .double { return $0 }
                if let n = $0.cast(to: Int.self) { return Value(Double(n)) }
                return .null
            },
            "jsonBool": view { $0.kind == .bool ? $0 : .null },
            "jsonArray": view {
                $0.kind == .list ? Value(($0.cast(to: [Value].self) ?? []).map(JSON.wrap)) : .null
            },
            "jsonObject": view {
                switch $0.kind {
                case .structure, .tuple, .dictionary:
                    $0.entries.map { entries in
                        Value(ValueDictionary(entries.map { ($0.key, JSON.wrap($0.value)) }))
                    } ?? .null
                default: .null
                }
            },
            "jsonIsNull": view { Value($0.kind == .nothing) },
        ]
    }
}
