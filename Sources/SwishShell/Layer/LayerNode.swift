@_spi(Layer) import Swiit
import Foundation

// Spike: a form of a layer's that the tree holds without reading, and that checks itself when the checker comes to it.

/// What the checker says is wrong, with the message a person reads.
struct TypeFailure: Error {
    var message: String
    /// The checker's own error, with where it is, when it came from there.
    var raw: TypeError?
    init(_ message: String) { self.message = message }
    init(_ raw: TypeError) {
        message = raw.message
        self.raw = raw
    }
}

/// A form of a layer's that is a node in the tree: it checks itself, in the context of where the checker is, and gives its type.
protocol LayerNode: Equatable, Sendable {
    mutating func check(in context: CheckContext, expecting expected: ValueType?) throws -> ValueType
    /// Whether it ends the program (`exit`), for a guard's `else`.
    var leavesProgram: Bool { get }
}

extension LayerNode {
    var leavesProgram: Bool { false }
}

/// The interpreter's node for a layer's, which passes the checker to it.
struct LayerNodeBox<Node: LayerNode>: ExprExtension {
    var node: Node

    init(_ node: Node) { self.node = node }

    func isEqual(to other: any SyntaxExtension) -> Bool { (other as? LayerNodeBox<Node>)?.node == node }

    mutating func check(in checker: TypeChecker, expecting expected: TypeAnnotation?) throws -> TypeAnnotation {
        do {
            return try node.check(in: CheckContext(checker), expecting: expected.map(ValueType.init)).raw
        } catch let failure as TypeFailure {
            throw failure.raw ?? TypeError(failure.message)
        }
    }

    var leavesProgram: Bool { node.leavesProgram }
}

extension SwiftExpression {
    /// The layer's node this holds, if it is a `T`.
    func node<T: LayerNode>(as type: T.Type = T.self) -> T? {
        if case .extended(let box) = raw { (box.node as? LayerNodeBox<T>)?.node } else { nil }
    }

    /// A layer's node as an expression.
    static func node<T: LayerNode>(_ node: T) -> SwiftExpression { SwiftExpression(.extended(ExprExtensionBox(LayerNodeBox(node)))) }
}
