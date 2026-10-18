@_spi(Layer) import Swiit
import Foundation

// Spike: where the checker is when a node of a layer checks itself, and what the node can ask of it: the type of a Swift
// expression it holds, what a name is in scope, which overload a call means, what a type has.

/// What a name is, where the checker is.
enum Declaration {
    case variable(ValueType)
    case functions([Signature])
    case other
}

/// A native member that can be a pipeline stage: the Swift member, as the interpreter will call it, and its signature with the
/// receiver as the stage's input.
struct StageMember {
    var typeName: String
    var index: Int
    var signature: Signature
}

/// What a struct or host object has that a stage can call on each item.
struct ItemMethods {
    var typeName: String
    var methods: [Signature]
    /// A host object's, as the host described it, not a struct's of the program's.
    var isHostObject: Bool
}

struct CheckContext {
    let raw: TypeChecker
    init(_ raw: TypeChecker) { self.raw = raw }

    /// The shell this checks for.
    var shell: Shell? { raw.interpreter.owner as? Shell }

    /// Runs `body`, giving the checker's errors as the layer sees them.
    private func guarded<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as TypeError { throw TypeFailure(error) }
    }

    // MARK: Types of what the layer holds

    func typeOf(_ expression: inout SwiftExpression, expecting expected: ValueType? = nil) throws -> ValueType {
        try guarded { ValueType(try raw.typeOf(&expression.raw, expecting: expected?.raw)) }
    }

    func closureType(_ closure: inout SwiftClosure, expecting expected: ValueType?) throws -> ValueType {
        try guarded { ValueType(try raw.closureType(&closure.raw, expecting: expected?.raw)) }
    }

    func check(_ block: inout SwiftBlock, inNewScope newScope: Bool) throws {
        try guarded { try raw.checkBlock(&block.raw, newScope: newScope) }
    }

    /// Checks `body` as the body of a closure is, where `await` may be written.
    func allowingAwait<T>(_ body: () throws -> T) rethrows -> T {
        try raw.withEffects(allowsAwait: true, body).0
    }

    // MARK: Names

    func lookup(_ name: String) -> Declaration? {
        switch raw.lookup(name) {
        case .variable(let type, _)?: .variable(ValueType(type))
        case .functions(let signatures)?: .functions(signatures.map(Signature.init))
        case _?: .other
        case nil: nil
        }
    }

    /// Notes a place that can throw, which must be inside a `try` or a handler.
    func throwingSite(_ what: String) throws {
        try guarded { try raw.throwingSite(what) }
    }

    /// What a word may name where `name` is an enum the program declares: its cases without payload, and whether it has raw values.
    func isEnum(_ name: String) -> EnumShape? {
        raw.enumInfo(named: name).map { profile in
            EnumShape(plainCases: Set(profile.cases.filter { $0.payload.isEmpty }.map(\.name)), hasRawValues: profile.rawType != nil)
        }
    }

    /// Notes a `try` that covers something that throws, which has to be handled where it is.
    func throwingTry(_ what: String) throws {
        raw.throwingSites += 1
        try guarded { try raw.checkHandled(what) }
    }

    // MARK: Calls

    /// The overload a call with these arguments means, and its arguments checked; nil when the callee isn't known well enough.
    func resolve(
        _ candidates: [Signature], arguments: inout [SwiftArgument], name: String, bindings: [String: ValueType] = [:]
    ) throws -> Signature? {
        var written = arguments.map(\.raw)
        defer { arguments = written.map(SwiftArgument.init) }
        return try guarded { try raw.resolve(candidates.map(\.raw), &written, name: name, bindings: bindings.mapValues(\.raw)).map(Signature.init) }
    }

    /// What every overload gives, if they agree; else nothing is known.
    func commonReturn(_ overloads: [Signature]) -> ValueType {
        ValueType(raw.commonReturn(overloads.map(\.raw)))
    }

    // MARK: Types

    func fits(_ actual: ValueType, _ expected: ValueType) -> Bool { raw.fits(actual.raw, expected.raw) }
    func conforms(_ type: ValueType, to protocolName: String) -> Bool { raw.conforms(type.raw, to: protocolName) }
    func substitute(_ type: ValueType, _ bindings: [String: ValueType]) -> ValueType {
        ValueType(raw.substitute(type.raw, bindings.mapValues(\.raw)))
    }
    func unify(_ pattern: ValueType, _ actual: ValueType, _ bindings: inout [String: ValueType]) {
        var found = bindings.mapValues(\.raw)
        raw.unify(pattern.raw, actual.raw, &found)
        bindings = found.mapValues(ValueType.init)
    }
    func memberType(of type: ValueType, _ name: String) throws -> ValueType {
        try guarded { ValueType(try raw.memberType(of: type.raw, name)) }
    }

    /// What the items of a sequence of this type are: a list's, a bridged sequence's. Nil when it isn't one.
    func itemType(ofSequence type: ValueType) -> ValueType? {
        switch type.raw {
        case .list(let element): return ValueType(element)
        case .generic: return raw.bridgedElement(type.raw).map(ValueType.init)
        case .named(let name):
            return Bridge.types[name]?.conformances["Sequence"] != nil ? Bridge.types[name]?.associatedTypes["Element"].map(ValueType.init) : nil
        default: return nil
        }
    }
}

// MARK: What a stage can be

extension CheckContext {
    /// The prelude's methods of every sequence under this name, as signatures with the sequence's `Element` free.
    func sequenceMethod(named name: String) -> [Signature]? {
        shell?.interpreter.sequenceMethods[name].map { raw.sequenceSignatures($0).map(Signature.init) }
    }

    /// What a call of the prelude's sequence method `name` on a list of `element`s gives, and the overload it chose.
    func sequenceMethodResult(
        named name: String, element: ValueType, arguments: inout [SwiftArgument]
    ) throws -> (type: ValueType, overload: Int?)? {
        var callee = Expr.variable(name)
        var written = arguments.map(\.raw)
        defer { arguments = written.map(SwiftArgument.init) }
        return try guarded {
            guard let type = try raw.sequenceMethodType(name, on: .list(element.raw), &callee, &written) else { return nil }
            if case .chosen(_, let overload) = callee { return (ValueType(type), overload) }
            return (ValueType(type), nil)
        }
    }

    /// What `select name size` gives for items of this type.
    func selectResult(element: ValueType, fields: [String]) throws -> ValueType {
        var arguments = fields.map { Argument(label: nil, value: .literal(.string($0))) }
        return try guarded { ValueType(try raw.selectType(element.raw, arguments: &arguments)) }
    }

    /// The Swift members named `name` that a stage can call on `receiver` made of `element`s, as the interpreter will call them:
    /// the items collected, the items as they come, each item, or the one value. Nil when there is no such type or member.
    func stageMembers(
        named name: String, receiver: StageReceiver, element: ValueType
    ) -> (typeName: String, bindings: [String: ValueType], members: [StageMember])? {
        let receiverType: TypeAnnotation = switch receiver {
        case .collected: .list(element.raw)
        case .flow: .generic("Flow", [element.raw])
        case .each, .value: element.raw
        }
        guard let (bridgedType, bindings) = raw.bridged(receiverType) else { return nil }
        let entries = receiver == .flow ? Bridge.flowMembers(name) : Bridge.stageMembers(bridgedType.name, name)
        guard !entries.isEmpty else { return nil }
        let members = entries.enumerated().map { position, entry in
            StageMember(
                typeName: bridgedType.name, index: entry.index,
                signature: Signature(TypeChecker.Signature(
                    name: name, parameters: [Bridge.receiverParameter(receiver, element: element.raw)] + entry.member.parameters,
                    returns: entry.member.returns, isThrowing: entry.member.isThrowing,
                    isRethrowing: entry.member.isRethrowing, index: position, generics: entry.member.generics)))
        }
        return (bridgedType.name, bindings.mapValues(ValueType.init), members)
    }

    /// The methods named `name` that items of this type have, for a stage called on each item.
    func itemMethods(of element: ValueType, named name: String) -> ItemMethods? {
        guard case .named(let typeName) = element.raw else { return nil }
        if let info = raw.structInfo(named: typeName), let methods = info.declared.methods[name] {
            return ItemMethods(typeName: typeName, methods: methods.map(Signature.init), isHostObject: false)
        }
        if let description = raw.describe(named: typeName), description.kind == .protocolType,
           let methods = description.declared.methods[name], methods.count == 1 {
            return ItemMethods(typeName: typeName, methods: methods.map(Signature.init), isHostObject: true)
        }
        return nil
    }

    /// Of two errors from reading a stage two ways, the one meant: the prelude's, or Swift's.
    func preferred(prelude: TypeFailure, swift: TypeFailure) -> TypeFailure {
        guard let prelude = prelude.raw, let swift = swift.raw else { return prelude }
        return TypeFailure(TypeChecker.preferred(prelude: prelude, swift: swift))
    }
}
