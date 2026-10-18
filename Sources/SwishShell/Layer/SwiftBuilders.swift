@_spi(Layer) import Swiit
import Foundation

// Spike: what a layer writes when it rewrites its forms into Swift. The Swift it makes is put together from these, and the
// Swift it was given (the fragments it holds) goes in as it is.

extension SwiftExpression {
    static func variable(_ name: String) -> SwiftExpression { SwiftExpression(.variable(name)) }
    static func text(_ text: String) -> SwiftExpression { SwiftExpression(.literal(.string(text))) }
    static func integer(_ number: Int) -> SwiftExpression { SwiftExpression(.literal(.int(number))) }
    static func boolean(_ value: Bool) -> SwiftExpression { SwiftExpression(.literal(.bool(value))) }
    static let nothing = SwiftExpression(.literal(.nothing))

    /// A string with Swift interpolated into it.
    static func interpolated(_ pieces: [StringPiece]) -> SwiftExpression {
        SwiftExpression(.string(pieces.map { piece in
            switch piece {
            case .literal(let text): StringPart.literal(text)
            case .expression(let expr): StringPart.expression(expr.raw)
            }
        }))
    }

    static func call(_ callee: SwiftExpression, _ arguments: [SwiftArgument] = []) -> SwiftExpression {
        SwiftExpression(.call(callee.raw, arguments.map(\.raw)))
    }
    static func call(_ name: String, _ arguments: [SwiftArgument] = []) -> SwiftExpression { call(.variable(name), arguments) }

    func member(_ name: String) -> SwiftExpression { SwiftExpression(.member(raw, name)) }
    /// `self.method(arguments)`.
    func calling(_ method: String, _ arguments: [SwiftArgument] = []) -> SwiftExpression { .call(member(method), arguments) }

    static func record(_ entries: [(key: String, value: SwiftExpression)]) -> SwiftExpression {
        SwiftExpression(.record(entries.map { RecordEntry(key: .literal(.string($0.key)), value: $0.value.raw) }))
    }
    static func tuple(_ arguments: [SwiftArgument]) -> SwiftExpression { SwiftExpression(.tuple(arguments.map(\.raw))) }

    func forceUnwrapped() -> SwiftExpression { SwiftExpression(.forceUnwrap(raw)) }
    func subscripted(by key: SwiftExpression) -> SwiftExpression { SwiftExpression(.index(raw, key.raw)) }
    /// `self != nil`.
    func isNotNil() -> SwiftExpression { SwiftExpression(.binary(.notEqual, raw, .literal(.nothing))) }
    /// `try self`, `try? self` or `try! self`.
    func attempt(_ style: TryStyle) -> SwiftExpression {
        SwiftExpression(.attempt(raw, style == .plain ? .plain : style == .optional ? .optional : .forced))
    }

    /// A call of a native member the checker found (a Swift member of a bridged type), on a receiver or without one.
    static func nativeCall(_ member: StageMember, on receiver: SwiftExpression?, _ arguments: [SwiftArgument]) -> SwiftExpression {
        SwiftExpression(.bridged(type: member.typeName, member: member.index, receiver: receiver?.raw, arguments: arguments.map(\.raw)))
    }

    /// Whether this is a closure written out.
    var isClosure: Bool { if case .closure = raw { true } else { false } }

    /// The names of the variables it reads, which a closure made of it holds on to.
    var variableNames: Set<String> {
        nonisolated(unsafe) var names: Set<String> = []
        _ = TreeRewriter(expr: { node in
            if case .variable(let name) = node { names.insert(name) }
            return node
        }).expression(raw)
        return names
    }

    /// It, with `transform` applied to each node of a layer's inside it, innermost first.
    func rewritingNodes(_ transform: @escaping (SwiftExpression) -> SwiftExpression) -> SwiftExpression {
        SwiftExpression(TreeRewriter(expr: { transform(SwiftExpression($0)).raw }).expression(raw))
    }
}

extension SwiftBlock {
    init(expressions: [SwiftExpression]) { self.init(Program(statements: expressions.map { .expression($0.raw) })) }

    func rewritingNodes(_ transform: @escaping (SwiftExpression) -> SwiftExpression) -> SwiftBlock {
        SwiftBlock(TreeRewriter(expr: { transform(SwiftExpression($0)).raw }).program(raw))
    }
}

extension SwiftClosure {
    /// `{ block }`, a closure of no parameters.
    init(block: SwiftBlock) { self.init(ClosureLiteral(parameters: [], body: block.raw)) }

    /// `{ expression }`, which holds on to the variables `names`.
    init(expression: SwiftExpression, capturing names: Set<String>) {
        self.init(ClosureLiteral(parameters: [], body: Program(statements: [.expression(expression.raw)]), names: NamesUsed(names: names)))
    }

    /// `{ $0 in expression }`: a closure of one anonymous parameter.
    init(parameter name: String, returning expression: SwiftExpression) {
        self.init(ClosureLiteral(parameters: [Parameter(name: name)], body: Program(statements: [.expression(expression.raw)])))
    }

    var parameterCount: Int { raw.parameters.count }

    func rewritingNodes(_ transform: @escaping (SwiftExpression) -> SwiftExpression) -> SwiftClosure {
        SwiftClosure(TreeRewriter(expr: { transform(SwiftExpression($0)).raw }).closure(raw))
    }
}

extension Array where Element == SwiftArgument {
    func rewritingNodes(_ transform: @escaping (SwiftExpression) -> SwiftExpression) -> [SwiftArgument] {
        TreeRewriter(expr: { transform(SwiftExpression($0)).raw }).arguments(map(\.raw)).map(SwiftArgument.init)
    }
}

extension StageMember {
    /// The Swift members of `typeName` named `name` that a stage can call without changing what it reads.
    static func members(of typeName: String, named name: String) -> [StageMember] {
        Bridge.stageMembers(typeName, name).enumerated().map { position, entry in
            StageMember(typeName: typeName, index: entry.index, signature: Signature(TypeChecker.Signature(
                name: name, parameters: entry.member.parameters, returns: entry.member.returns, isThrowing: entry.member.isThrowing,
                isRethrowing: entry.member.isRethrowing, index: position, generics: entry.member.generics)))
        }
    }

    /// `Flow(items)`: the member that makes a `Flow` of a sequence's items.
    static var flowInitializer: StageMember? {
        Bridge.flowInitializer.map { StageMember(typeName: "Flow", index: $0, signature: Signature(TypeChecker.Signature(name: "init", parameters: [], returns: .named("Flow")))) }
    }

    /// Whether it can be called with no arguments: every parameter has a default.
    var needsNoArguments: Bool { signature.parameters.allSatisfy(\.hasDefault) }
    /// Whether it gives a list.
    var returnsList: Bool { signature.returns.isList }
}

extension ValueType {
    var isOptional: Bool { if case .optional = raw { true } else { false } }
}

extension Interpreter {
    /// The shell this interpreter belongs to.
    var shell: Shell { owner as! Shell }
}
