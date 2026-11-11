import Swiit

extension Shell {
    /// The bodies of the JSON functions the prelude's `JSON` calls.
    var jsonBodies: [String: @Sendable ([String: Value]) throws -> Value] {
        func view(
            _ read: @escaping @Sendable (Value) -> Value
        ) -> @Sendable ([String: Value]) throws -> Value {
            { arguments in read(arguments["raw"] ?? .nothing) }
        }
        return [
            "jsonField": { [unowned self] arguments in
                let value = arguments["raw"] ?? .nothing, key = arguments["key"] ?? .nothing
                switch value.kind {
                case .structure, .tuple, .object:
                    guard let name = key.casting(to: String.self) else { return .nothing }
                    return jsonWrapping(value.field(name))
                case .dictionary:
                    return jsonWrapping(value.entries?.first { $0.key == key }?.value)
                case .list:
                    guard let index = key.casting(to: Int.self),
                        let items = value.casting(to: [Value].self)
                    else {
                        return .nothing
                    }
                    return jsonWrapping(items.indices.contains(index) ? items[index] : nil)
                default: return .nothing
                }
            },
            "jsonString": view { $0.kind == .string ? $0 : .nothing },
            "jsonInt": view {
                if $0.kind == .int { return $0 }
                if let d = $0.casting(to: Double.self), d == d.rounded(), abs(d) < 9e15 {
                    return Value(Int(d))
                }
                return .nothing
            },
            "jsonDouble": view {
                if $0.kind == .double { return $0 }
                if let n = $0.casting(to: Int.self) { return Value(Double(n)) }
                return .nothing
            },
            "jsonBool": view { $0.kind == .bool ? $0 : .nothing },
            "jsonArray": view { [unowned self] raw in
                raw.kind == .list
                    ? Value((raw.casting(to: [Value].self) ?? []).map(jsonWrap)) : .nothing
            },
            "jsonObject": view { [unowned self] raw in
                switch raw.kind {
                case .structure, .tuple, .dictionary, .object:
                    raw.entries.map { entries in
                        Value(
                            Dictionary(
                                entries.map { ($0.key, jsonWrap($0.value)) },
                                uniquingKeysWith: { $1 }
                            )
                        )
                    } ?? .nothing
                default: .nothing
                }
            },
            "jsonIsNull": view { Value($0.kind == .nothing) },
        ]
    }
}
