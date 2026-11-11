import Foundation
import Swiit

extension Shell {
    // MARK: Conversions

    /// The body of `members`: what each type of the input has, as `help Type` lists it, and then
    /// what a value says it has beyond that (a tuple's fields, a job's members).
    func membersBody(_ arguments: [String: Value]) throws -> Value {
        guard let items = arguments["items"]?.casting(to: [Value].self) else {
            return Value([] as [Value])
        }

        var rows: [Value] = []
        var seen: Set<String> = []
        func add(_ type: String, _ name: String, _ kind: MemberKind, _ declaration: String) {
            guard seen.insert("\(type).\(name)").inserted else { return }

            // The prelude's `MemberKind` has the cases of the Swift one a member can be.
            let kindValue = preludeTypes.memberKind.enumCase(named: "\(kind)", in: interpreter)
            rows.append(
                preludeTypes.make(
                    preludeTypes.member,
                    [
                        "type": Value(type), "name": Value(name),
                        "kind": kindValue ?? .nothing, "declaration": Value(declaration),
                    ]
                )
            )
        }

        for item in items {
            let type = item.typeName
            let listed = interpreter.scriptType(of: item).members(in: interpreter)
                .filter { $0.memberKind != nil && $0.memberKind != .initializer }

            // What the value holds comes first, in its own order: a struct's or a tuple's fields,
            // or the members of a value that says them itself. The type says what each is, where
            // it lists it.
            var held: [(name: String, value: Value)] = []
            switch item.kind {
            case .structure, .tuple:
                held = item.fields?.map { (name: $0.key, value: $0.value) } ?? []
            case .object:
                if let object = item.casting(toExistential: (any ScriptConvertible).self),
                    let names = object.memberNames
                {
                    held = names.compactMap { name in object.member(name).map { (name, $0) } }
                }
            default:
                break
            }
            for (name, value) in held {
                if let member = listed.first(where: { $0.name == name }) {
                    add(type, name, member.memberKind!, String(declaration(of: member).characters))
                } else {
                    let kind: MemberKind = value.kind == .function ? .method : .property
                    add(type, name, kind, "\(name): \(value.typeName)")
                }
            }

            // Then the rest of what the type has, as `help Type` lists it.
            for member in listed {
                add(
                    type,
                    member.name,
                    member.memberKind!,
                    String(declaration(of: member).characters)
                )
            }
        }
        return Value(rows)
    }
}
