import Foundation
import Swiit

extension Shell {
    // MARK: Conversions

    /// The body of `members`: each type's fields and members, of the input.
    func membersBody(_ arguments: [String: Value]) throws -> Value {
        guard let items = arguments["items"]?.cast(to: [Value].self) else { return Value([] as [Value]) }
        var rows: [Value] = []
        var seen: Set<String> = []
        func add(_ type: String, _ name: String, _ kind: String) {
            guard seen.insert("\(type).\(name)").inserted else { return }
            rows.append(Value(struct: "Member", fields: ["type": Value(type), "name": Value(name), "kind": Value(kind)]))
        }
        for item in items {
            let before = rows.count
            // A struct's fields, or an object's members, are its own.
            switch item.kind {
            case .structure, .tuple:
                if let fields = item.fields { for (key, value) in fields { add(item.typeName, key, value.typeName) } }
            case .object:
                // An object a host made, not a Swift value held as it is.
                if let object = (try? item.unboxed(Any.self)) as? any HostObject {
                    for name in object.memberNames { add(object.typeName, name, object.member(name).map { $0.typeName } ?? "") }
                }
            case .function:
                add("Function", item.description, "signature")
            default: break
            }
            // Then what its type has, as `help Type` shows it.
            if let name = interpreter.describedTypeName(of: item), let type = interpreter.typeDescription(named: name) {
                for member in type.members where member.kind != .initializer { add(type.name, member.name, member.kind.rawValue) }
            }
            // A type with nothing to list is still named.
            if rows.count == before && !seen.contains("\(item.typeName).") { add(item.typeName, "", "") }
        }
        return Value(rows)
    }
}
