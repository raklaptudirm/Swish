@_spi(Shell) import Swiit
import Foundation
import SwishKit
import SwishStandardLibrary
import SystemPackage

extension Bridge {
    /// A bridged type's members that can be a pipeline stage: those named
    /// `name` that read their receiver without changing it.
    static func stageMembers(_ typeName: String, _ name: String) -> [(index: Int, member: BridgedMember)] {
        (types[typeName]?.members ?? []).enumerated().filter { _, member in
            member.name == name && !member.isStatic && !member.isMutating && (member.kind == .method || member.kind == .property)
        }.map { (index: $0.offset, member: $0.element) }
    }

    /// `Flow(items)`: the initializer that makes a `Flow` of a sequence's items.
    static let flowInitializer: Int? = (types["Flow"]?.members ?? []).firstIndex { member in
        member.kind == .initializer && member.parameters.map(\.name) == ["items"]
    }

    /// Of a stage's members, those a `Flow` passes on as another: the ones
    /// that work on items as they come.
    static func flowMembers(_ name: String) -> [(index: Int, member: BridgedMember)] {
        stageMembers("Flow", name).filter { _, member in
            if case .generic("Flow", _) = member.returns { true } else { false }
        }
    }

    /// A parameter's type as a word on the command line converts to it: a
    /// generic parameter as what it's bound to (Element as Int).
    static func wordType(_ type: TypeAnnotation, _ bindings: [String: TypeAnnotation]) -> TypeAnnotation {
        switch type {
        case .parameter(let name): bindings[name].flatMap { $0 == .unknown || $0 == .any ? nil : $0 } ?? type
        case .optional(let wrapped): .optional(wordType(wrapped, bindings))
        case .list(let element): .list(wordType(element, bindings))
        default: type
        }
    }

    /// The receiver of a member as a stage's input: the items collected
    /// (for `.value`, the one item), or each one.
    static func receiverParameter(_ receiver: StageReceiver, element: TypeAnnotation = .any) -> Parameter {
        var parameter = Parameter(label: nil, name: receiver == .flow ? "items" : "self", type: receiver == .each ? element : .list(element))
        parameter.isInput = true
        return parameter
    }
}

extension Bridge {
    /// Every bridged member's name that can be a stage, for highlighting.
    static let stageNames: Set<String> = Set(types.values.flatMap { type in
        type.members.filter { !$0.isStatic && !$0.isMutating && ($0.kind == .method || $0.kind == .property) }.map(\.name)
    })

    /// The methods of the items as they come, which a pipeline stage is.
    static var flowNames: Set<String> {
        Set((types["Flow"]?.members ?? []).filter { member in
            if case .generic("Flow", _) = member.returns { true } else { false }
        }.map(\.name))
    }

    /// Those that are methods: a bare one, with nothing piped in, has
    /// nothing to work on (a property's name could be a program's).
    static let methodNames: Set<String> = Set(types.values.flatMap { type in
        type.members.filter { !$0.isStatic && !$0.isMutating && $0.kind == .method }.map(\.name)
    })
}

extension Shell {
    /// Whether some type has a member called `name` that a stage could
    /// call: a Swift type's, a struct's in scope, or a job's.
    func isMemberName(_ name: String) -> Bool {
        if Bridge.stageNames.contains(name) || Job.members.contains { $0.name == name } { return true }
        return interpreter.scopes.contains { scope in
            scope.bindings.values.contains { binding in
                if case .object(let type as StructType) = binding.value { type.methods[name] != nil } else { false }
            }
        }
    }

    /// Whether `name` is a method some type has that a stage could call,
    /// and that makes no sense without something piped in.
    func isStageMethod(_ name: String) -> Bool {
        interpreter.sequenceMethods[name] != nil || Bridge.methodNames.contains(name)
    }

    /// What `name` is after a `|`: what the prelude adds to every sequence, or
    /// a method of the items as they come (a `Flow`'s), or one of any bridged
    /// type's. In the order the stage looks.
    func stageMethods(named name: String) -> OverloadSet? {
        interpreter.sequenceMethods[name] ?? bridgedStage("Flow", name, receiver: .flow) ?? stageFunctions(named: name)
    }

    /// Every bridged type's stage members named `name`, as one set of
    /// functions: what's known of a stage while typing, before the type of
    /// what's piped into it is.
    func stageFunctions(named name: String) -> OverloadSet? {
        let candidates = Bridge.types.keys.sorted().flatMap {
            bridgedStage($0, name, receiver: .collected)?.candidates ?? []
        }
        return candidates.isEmpty ? nil : OverloadSet(name: name, candidates: candidates)
    }

    /// `xs | max` or `names | uppercased`: a bridged type's members named
    /// `name`, as functions whose input is the receiver, so a stage runs
    /// them as it runs any function.
    func bridgedStage(
        _ typeName: String, _ name: String, receiver: StageReceiver, bindings: [String: TypeAnnotation] = [:]
    ) -> OverloadSet? {
        let members = receiver == .flow ? Bridge.flowMembers(name) : Bridge.stageMembers(typeName, name)
        guard !members.isEmpty else { return nil }
        return OverloadSet(name: name, candidates: members.map { _, member in
            let parameters = member.parameters.map { parameter -> Parameter in
                var parameter = parameter
                parameter.type = Bridge.wordType(parameter.type, bindings)
                return parameter
            }
            var body = member.body
            if receiver == .flow, case .native(let call) = body {
                // Lazily: the stage reads upstream only as its own reader is
                // asked, and the Flow it gives is read as the next stage asks.
                body = .stream { shell, upstream, arguments in
                    var arguments = arguments
                    arguments["self"] = SwiftValue.make(Flow<Value> { try upstream.next() }, as: "Flow")
                    let flow = try SwiftValue.unbox(Flow<Value>.self, try call(shell, arguments))
                    return ValueStream { try flow.read() }
                }
            } else if receiver == .value, case .native(let call) = body {
                // Collected like a sequence's items, so what it gives flows
                // as items too; but it's the one value that's the receiver.
                body = .native { shell, args in
                    var args = args
                    if case .list(let items)? = args["self"] { args["self"] = items.first ?? .nothing }
                    return try call(shell, args)
                }
            }
            return Function(name: name, parameters: [Bridge.receiverParameter(receiver)] + parameters,
                            returnType: nil, body: body,
                            documentation: Documentation(summary: member.summary, parameters: member.parameterDocs),
                            isThrowing: member.isThrowing,
                            isRethrowing: member.isRethrowing, generics: member.generics)
        })
    }
}
