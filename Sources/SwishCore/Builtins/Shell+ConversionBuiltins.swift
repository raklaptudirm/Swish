import Foundation
import SwishKit
import SwishStandardLibrary

extension Shell {
    // MARK: Conversions

    func members() -> Function {
        .builtin(
            "members", "Describes the input: each type's fields and members.", [.input("items", .list(.any))],
            .native { shell, args in
                guard case .list(let items) = args["items"] else { return .list([]) }
                var rows: [Value] = []
                var seen: Set<String> = []
                func add(_ type: String, _ name: String, _ kind: String) {
                    guard seen.insert("\(type).\(name)").inserted else { return }
                    rows.append(.record(Record(["type": .string(type), "name": .string(name), "kind": .string(kind)], typeName: "Member")))
                }
                for item in items {
                    let before = rows.count
                    // A record's fields, or an object's members, are its own.
                    switch item {
                    case .record(let record):
                        for (key, value) in record { add(record.typeName ?? "Record", key, value.typeName) }
                    case .function(let set as OverloadSet):
                        for candidate in set.candidates { add("Function", candidate.signature, "signature") }
                    case .object(let object) where !(object is SwiftValue):
                        for name in object.memberNames {
                            add(object.typeName, name, object.member(name).map { $0.typeName } ?? "")
                        }
                    default: break
                    }
                    // Then what its type has, as `help Type` shows it.
                    if let name = shell.describedTypeName(of: item), let type = shell.typeDescription(named: name) {
                        for member in type.members where member.kind != .initializer { add(type.name, member.name, member.kind.rawValue) }
                    }
                    // A type with nothing to list is still named.
                    if rows.count == before && !seen.contains("\(item.typeName).") { add(item.typeName, "", "") }
                }
                return .list(rows)
            }
        )
    }
}
