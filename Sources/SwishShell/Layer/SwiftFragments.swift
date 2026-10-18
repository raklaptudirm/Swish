@_spi(Layer) import Swiit
import Foundation

// Spike: the Swift a layer's forms hold, as a layer sees it. A layer reads its own text and hands the Swift inside it
// (`\(expr)`, a closure word, the program in `$(…)`) to the interpreter to read; what comes back is opaque to the layer,
// which can only keep it, ask the checker about it, and put it into what it rewrites to. Only files in this folder name
// the interpreter's tree.

/// A Swift expression a layer's form holds.
struct SwiftExpression: Equatable, Sendable {
    var raw: Expr
    init(_ raw: Expr) { self.raw = raw }
}

/// Swift statements a layer's form holds (the program in `$(…)`).
struct SwiftBlock: Equatable, Sendable {
    var raw: Program
    init(_ raw: Program) { self.raw = raw }
}

/// A closure a layer's form holds (`where { $0.size > 1 }`).
struct SwiftClosure: Equatable, Sendable {
    var raw: ClosureLiteral
    init(_ raw: ClosureLiteral) { self.raw = raw }
}

/// An argument of a call written in a layer's form: `by: "size"`.
struct SwiftArgument: Equatable, Sendable {
    var label: String?
    var value: SwiftExpression

    init(label: String? = nil, value: SwiftExpression) {
        self.label = label
        self.value = value
    }

    init(_ raw: Argument) {
        label = raw.label
        value = SwiftExpression(raw.value)
    }

    var raw: Argument { Argument(label: label, value: value.raw) }
}

/// A piece of a string a layer reads: text, or Swift to interpolate.
enum StringPiece: Equatable, Sendable {
    case literal(String)
    case expression(SwiftExpression)

    init(_ raw: StringPart) {
        switch raw {
        case .literal(let text): self = .literal(text)
        case .expression(let expr): self = .expression(SwiftExpression(expr))
        }
    }
}

/// How a `try` was written: `try`, `try?`, `try!`.
enum TryStyle: Equatable, Sendable {
    case plain, optional, forced

    init(_ raw: TryKind) {
        switch raw {
        case .plain: self = .plain
        case .optional: self = .optional
        case .forced: self = .forced
        }
    }
}

extension SwiftExpression {
    /// `n` in a closure without named parameters: `$n`.
    static func closureParameter(_ index: Int) -> SwiftExpression { SwiftExpression(.variable("$\(index)")) }

    /// A closure as an argument's value.
    static func closure(_ closure: SwiftClosure) -> SwiftExpression { SwiftExpression(.closure(closure.raw)) }

    /// `try? build()`: a value that says whether it caught an error.
    var isOptionalAttempt: Bool {
        if case .attempt(_, .optional) = raw { true } else { false }
    }
}

extension SwiftBlock {
    /// The one expression statement this is, if it is only that.
    var singleExpression: SwiftExpression? {
        guard raw.statements.count == 1, case .expression(let expr) = raw.statements[0] else { return nil }
        return SwiftExpression(expr)
    }
}

extension SwiftExpression {
    /// The closure this is, if it is one written out.
    var closure: SwiftClosure? {
        if case .closure(let literal) = raw { SwiftClosure(literal) } else { nil }
    }
}

// The shell's tests read the tree the interpreter reads.
extension Expr {
    var pipelineNode: PipelineNode? { SwiftExpression(self).pipelineNode }
    var substitutionParts: (program: SwiftBlock, throwing: Bool)? { SwiftExpression(self).substitutionParts }
    var dollarName: String? { SwiftExpression(self).dollarName }
    var asyncTarget: AsyncExpr.Target? { SwiftExpression(self).asyncTarget }
    static func commands(_ chain: CommandChainExpr) -> Expr { SwiftExpression.commands(chain).raw }
}
