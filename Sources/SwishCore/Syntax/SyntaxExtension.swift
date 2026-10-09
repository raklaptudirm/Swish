import SwishKit

/// Syntax the core's grammar doesn't define: what a layer over the core adds,
/// like the shell's commands, pipelines and substitutions. The tree holds it
/// without knowing what it is, and each pass asks it to do its part: the
/// checker to check it, the interpreter to run it. The core never names the
/// node types, so it can be built without them (Docs/Design/frontend.md).
package protocol SyntaxExtension: Sendable {
    /// Trees compare, so extensions do.
    func isEqual(to other: any SyntaxExtension) -> Bool
}

extension SyntaxExtension where Self: Equatable {
    package func isEqual(to other: any SyntaxExtension) -> Bool {
        (other as? Self) == self
    }
}

/// An expression an extension adds: `$(…)`, `$name`, `async …`.
package protocol ExprExtension: SyntaxExtension {
    /// Checks it, with whatever the checker found written in, and gives its type.
    mutating func check(in checker: TypeChecker, expecting expected: TypeAnnotation?) throws -> TypeAnnotation
    func evaluate(in interpreter: Interpreter) throws -> Value
}

/// A unit an extension adds: a command or a pipeline of them. A unit has an
/// exit status, which `&&`, `||` and conditions go by.
package protocol UnitExtension: SyntaxExtension {
    mutating func check(in checker: TypeChecker) throws
    func run(in interpreter: Interpreter, context: UnitContext) throws -> Int32
    /// Whether it ends the program (`exit`), for a function that must return
    /// on every path.
    var leavesProgram: Bool { get }
}

extension UnitExtension {
    package var leavesProgram: Bool { false }
}

/// A statement an extension adds: `env.NAME = value`, `import Name from path`.
package protocol StatementExtension: SyntaxExtension {
    mutating func check(in checker: TypeChecker) throws
    func run(in interpreter: Interpreter) throws -> Int32
}

/// What the tree holds for each: the node, compared through `isEqual`.
package struct ExprExtensionBox: Equatable, Sendable {
    package var node: any ExprExtension

    package init(_ node: any ExprExtension) {
        self.node = node
    }

    package static func == (lhs: ExprExtensionBox, rhs: ExprExtensionBox) -> Bool {
        lhs.node.isEqual(to: rhs.node)
    }
}

package struct UnitExtensionBox: Equatable, Sendable {
    package var node: any UnitExtension

    package init(_ node: any UnitExtension) {
        self.node = node
    }

    package static func == (lhs: UnitExtensionBox, rhs: UnitExtensionBox) -> Bool {
        lhs.node.isEqual(to: rhs.node)
    }
}

package struct StatementExtensionBox: Equatable, Sendable {
    package var node: any StatementExtension

    package init(_ node: any StatementExtension) {
        self.node = node
    }

    package static func == (lhs: StatementExtensionBox, rhs: StatementExtensionBox) -> Bool {
        lhs.node.isEqual(to: rhs.node)
    }
}
