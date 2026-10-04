import Foundation
import SwishKit

/// What a type has, for `help Type` and `members`: a Swift type's members
/// from the bridge (with Swish's own extensions, and for a sequence the
/// shell's additions), a struct's or enum's from its declaration. One
/// description, so what's shown is what can be called.
struct TypeDescription {
    /// What a member is; the order of the cases is the order `help` shows
    /// them in.
    enum Kind: String, CaseIterable {
        case `case`, initializer, property, method
        case staticProperty = "static property", staticMethod = "static method"

        /// The heading `help` lists them under: "Properties", "Static methods".
        var heading: String {
            let plural = rawValue.hasSuffix("y") ? rawValue.dropLast() + "ies" : rawValue + "s"
            return plural.prefix(1).uppercased() + plural.dropFirst()
        }
    }

    struct Member {
        let name: String
        let kind: Kind
        /// As Swift writes it: `count: Int`, `uppercased() -> String`.
        let signature: String
        let summary: String
    }

    let name: String
    /// What kind of type: "Swift type", "struct" or "enum".
    let kind: String
    let members: [Member]
}

extension Shell {
    /// The type named `name`, if Swish knows one by that name.
    func typeDescription(named name: String) -> TypeDescription? {
        if let bridged = Bridge.types[name] { return describe(bridged) }
        switch lookup(name)?.value {
        case .object(let type as StructType)?: return describe(type)
        case .object(let type as EnumType)?: return describe(type)
        default: return nil
        }
    }

    /// The name `typeDescription` knows a value's type by.
    func describedTypeName(of value: Value) -> String? {
        if case .record(let record) = value { return record.typeName }
        return TypeChecker(shell: self).type(of: value).swiftType?.name
    }

    private func describe(_ type: BridgedType) -> TypeDescription {
        var members = type.members.filter { $0.kind != .setter }.map { member in
            let settable = member.kind == .property
                && type.members.contains { $0.kind == .setter && $0.name == member.name }
            let kind: TypeDescription.Kind = switch member.kind {
            case .initializer: .initializer
            case .property, .setter: member.isStatic ? .staticProperty : .property
            case .method: member.isStatic ? .staticMethod : .method
            }
            return TypeDescription.Member(
                name: member.kind == .initializer ? "init" : member.name,
                kind: kind,
                signature: TypeDescription.signature(member, settable: settable),
                summary: member.summary
            )
        }
        // A sequence has the shell's additions too: `select`, `get`, …
        if type.conformances["Sequence"] != nil {
            for (name, methods) in sequenceMethods.sorted(by: { $0.key < $1.key }) {
                for method in methods.candidates {
                    members.append(.init(name: name, kind: .method, signature: TypeDescription.signature(method),
                                         summary: method.documentation?.summary.firstLine ?? ""))
                }
            }
        }
        return TypeDescription(name: type.name, kind: "Swift type", members: members)
    }

    private func describe(_ type: StructType) -> TypeDescription {
        var members: [TypeDescription.Member] = []
        let initializers = type.initializers?.candidates ?? [type.memberwise]
        for initializer in initializers {
            members.append(.init(name: "init", kind: .initializer, signature: TypeDescription.signature(initializer, as: "init"),
                                 summary: initializer.documentation?.summary.firstLine ?? ""))
        }
        for property in type.stored {
            members.append(.init(name: property.name, kind: .property,
                                 signature: "\(property.mutable ? "var" : "let") \(property.name): \(property.type.map { "\($0)" } ?? "Any")",
                                 summary: ""))
        }
        for (name, getter) in type.computed.sorted(by: { $0.key < $1.key }) {
            members.append(.init(name: name, kind: .property,
                                 signature: "var \(name): \(getter.returnType.map { "\($0)" } ?? "Any") { get }",
                                 summary: getter.documentation?.summary.firstLine ?? ""))
        }
        for (name, methods) in type.methods.sorted(by: { $0.key < $1.key }) {
            for method in methods.candidates {
                members.append(.init(name: name, kind: .method,
                                     signature: (method.isMutating ? "mutating " : "") + TypeDescription.signature(method),
                                     summary: method.documentation?.summary.firstLine ?? ""))
            }
        }
        return TypeDescription(name: type.name, kind: "struct", members: members)
    }

    private func describe(_ type: EnumType) -> TypeDescription {
        let payloads = enumPayloadTypes[ObjectIdentifier(type)] ?? [:]
        let members = type.cases.map { enumCase -> TypeDescription.Member in
            var signature = "case \(enumCase.name)"
            if !enumCase.labels.isEmpty {
                let types = payloads[enumCase.name] ?? []
                let values = enumCase.labels.enumerated().map { index, label in
                    (label.map { "\($0): " } ?? "") + (index < types.count ? "\(types[index])" : "Any")
                }
                signature += "(\(values.joined(separator: ", ")))"
            }
            if let raw = enumCase.rawValue { signature += " = \(raw.debugDescription)" }
            return .init(name: enumCase.name, kind: .case, signature: signature, summary: "")
        }
        return TypeDescription(name: type.name, kind: "enum", members: members)
    }

    /// What `help Type` shows: its members, grouped by kind, each with its
    /// signature (highlighted as Swift) and, on the line below, what its
    /// documentation says.
    func helpLines(for type: TypeDescription) -> [StyledText] {
        var lines = [StyledText([.init(type.kind, HelpStyle.keyword), .init(" "), .init(type.name, HelpStyle.type)])]
        let groups = Dictionary(grouping: type.members, by: \.kind)
        for kind in TypeDescription.Kind.allCases {
            guard let members = groups[kind], !members.isEmpty else { continue }
            lines += [StyledText(plain: ""), HelpStyle.heading("\(kind.heading):")]
            for (index, member) in members.sorted(by: { $0.name < $1.name }).enumerated() {
                // A blank line between them, so a signature and its description read as one.
                if index > 0 { lines.append(StyledText(plain: "")) }
                lines.append(StyledText([.init("  ")] + HelpStyle.signature(member.signature)))
                if !member.summary.isEmpty { lines.append(StyledText(plain: "    " + member.summary)) }
            }
        }
        return lines
    }
}

extension TypeDescription {
    /// A bridged member as Swift declares it.
    static func signature(_ member: BridgedMember, settable: Bool) -> String {
        switch member.kind {
        case .initializer: return "init(\(parameters(member.parameters)))"
        case .property: return "\(member.name): \(member.returns)" + (settable ? " { get set }" : "")
        case .method, .setter:
            return "\(member.name)(\(parameters(member.parameters)))" + (member.returns == .void ? "" : " -> \(member.returns)")
        }
    }

    /// A Swish function as a member, under `name` if given: its input is
    /// what it's called on, so it isn't shown.
    static func signature(_ function: Function, as name: String? = nil) -> String {
        let shown = function.parameters.filter { !$0.isInput }
        let result = function.returnType.flatMap { $0 == .void ? nil : " -> \($0)" } ?? ""
        return "\(name ?? function.name ?? "closure")(\(parameters(shown)))" + result
    }

    private static func parameters(_ parameters: [Parameter]) -> String {
        parameters.map { parameter in
            let names = parameter.label == parameter.name ? parameter.name : "\(parameter.label ?? "_") \(parameter.name)"
            return "\(names): \(parameter.type)\(parameter.variadic ? "..." : "")"
        }.joined(separator: ", ")
    }
}

private extension String {
    /// The first line: a documentation summary's first sentence's line.
    var firstLine: String { String(prefix { $0 != "\n" }) }
}
