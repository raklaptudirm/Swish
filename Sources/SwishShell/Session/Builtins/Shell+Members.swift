import Foundation
import Swiit

extension Shell {
    // MARK: Conversions

    /// The body of `members`: each type's fields and members, of the input.
    func membersBody(_ arguments: [String: Value]) throws -> Value {
        guard let items = arguments["items"]?.casting(to: [Value].self) else {
            return Value([] as [Value])
        }
        var rows: [Value] = []
        var seen: Set<String> = []
        func add(_ type: String, _ name: String, _ kind: String) {
            guard seen.insert("\(type).\(name)").inserted else { return }
            rows.append(
                make(
                    preludeTypes.member,
                    ["type": Value(type), "name": Value(name), "kind": Value(kind)]
                )
            )
        }
        for item in items {
            let before = rows.count
            // A struct's fields, or an object's members, are its own.
            switch item.kind {
            case .structure, .tuple:
                if let fields = item.fields {
                    for (key, value) in fields { add(item.typeName, key, value.typeName) }
                }
            case .object:
                // A value that says its members, methods too: a job's, a parsed object's.
                if let held = item.casting(toExistential: (any ScriptConvertible).self),
                    let names = held.memberNames
                {
                    for name in names {
                        add(item.typeName, name, held.member(name).map { $0.typeName } ?? "")
                    }
                }
            case .function:
                add("Function", item.description, "signature")
            default: break
            }
            // Then what its type has, as `help Type` shows it.
            for member in interpreter.symbols(in: interpreter.scriptType(of: item)) {
                guard let kind = member.memberKind, kind != .initializer else { continue }
                add(item.typeName, member.name, kind.rawValue)
            }
            // A type with nothing to list is still named.
            if rows.count == before && !seen.contains("\(item.typeName).") {
                add(item.typeName, "", "")
            }
        }
        return Value(rows)
    }
}
