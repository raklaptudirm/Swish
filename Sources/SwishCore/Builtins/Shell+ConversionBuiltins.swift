import Foundation
import SwishKit
import SwishStandardLibrary

extension Shell {
    // MARK: Conversions

    func to() -> Function {
        .builtin(
            "to", "Converts the input to text.",
            [.positional("format", .string), .input("items", .list(.any))],
            docs: ["format": "json, or text for how it would be displayed"],
            .native { _, args in
                guard case .list(let items) = args["items"] else { return .nothing }
                switch args.strings("format")[0] {
                case "json":
                    return .string(try JSON.text(items.count == 1 ? items[0] : .list(items)))
                case "text":
                    // One String, as its signature says, as JSON is.
                    return .string(Shell.formattedLines(items, useViews: true).map(\.description).joined(separator: "\n"))
                case let format:
                    throw RuntimeError("to: unknown format '\(format)' (supported: json, text)")
                }
            }
        )
    }

    func table() -> Function {
        .builtin(
            "table", "Lays records out as a table with every field.", [.input("items", .list(.any))],
            .native { _, args in
                guard case .list(let items) = args["items"] else { return .list([]) }
                return .list(Shell.formattedLines(items, useViews: false))
            }
        )
    }

    func list() -> Function {
        .builtin(
            "list", "Shows each record as a list of fields.", [.input("items", .list(.any))],
            .native { shell, args in
                guard case .list(let items) = args["items"] else { return .list([]) }
                var lines: [String] = []
                for item in items {
                    if !lines.isEmpty { lines.append("") }
                    if let record = item.asRecord {
                        lines += shell.keyValueLines(record)
                    } else {
                        lines.append(item.description)
                    }
                }
                return .list(lines.map(Value.string))
            }
        )
    }

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

    /// The lines the display step would show for `items`.
    static func formattedLines(_ items: [Value], useViews: Bool) -> [Value] {
        var lines: [Value] = []
        let formatter = Formatter(useViews: useViews) { text in
            lines.append(.string(String(text.dropLast())))
            return true
        }
        for item in items { formatter.add(item) }
        formatter.finish()
        return lines
    }
}
