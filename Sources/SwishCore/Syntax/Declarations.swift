import Foundation
import SwishKit

package struct FunctionDecl: Equatable, Sendable {
    package var name: String
    package var parameters: [Parameter]
    package var returnType: TypeAnnotation?
    package var body: Program
    package var documentation: Documentation?
    /// A struct's `mutating func`, which may change `self`.
    package var isMutating = false
    /// `throws`: calling it needs `try`.
    package var isThrowing = false
    /// `rethrows`: it throws only if a closure passed to it does.
    package var isRethrowing = false
    /// `<T, V: Comparable>` and `where` clauses: each type parameter, and
    /// the protocols it must conform to. Only the prelude has these, for now.
    package var generics: [String: [String]] = [:]
    package var names = NamesUsed()

    package init(name: String, parameters: [Parameter], returnType: TypeAnnotation? = nil, body: Program, documentation: Documentation? = nil, isMutating: Bool = false, isThrowing: Bool = false, isRethrowing: Bool = false, generics: [String: [String]] = [:], names: NamesUsed = NamesUsed()) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.documentation = documentation
        self.isMutating = isMutating
        self.isThrowing = isThrowing
        self.isRethrowing = isRethrowing
        self.generics = generics
        self.names = names
    }
}

/// Assigning to a variable, or to part of one: `p.x`, `xs[0]`, `r["k"]`.
package struct Assignment: Equatable, Sendable {
    package enum Step: Equatable, Sendable {
        case member(String)
        case index(Expr)
    }

    package var root: String
    package var path: [Step] = []
    /// `+=` and the like: the operator applied to the current value.
    package var op: BinaryOperator?
    package var value: Expr

    package init(root: String, path: [Step] = [], op: BinaryOperator? = nil, value: Expr) {
        self.root = root
        self.path = path
        self.op = op
        self.value = value
    }
}

/// `struct Name { var x: Int; func f() {…}; init(…) {…} }`.
package struct StructDecl: Equatable, Sendable {
    package var name: String
    package var properties: [PropertyDecl]
    package var methods: [FunctionDecl]
    package var initializers: [FunctionDecl]
    /// `struct Point: Equatable, Hashable`.
    package var conformances: [String] = []
    /// `static let origin = Point(x: 0, y: 0)`: values of the type itself,
    /// and `static func`s, which are called on it: `Point.origin`.
    package var staticProperties: [PropertyDecl] = []
    package var staticMethods: [FunctionDecl] = []

    package init(name: String, properties: [PropertyDecl], methods: [FunctionDecl], initializers: [FunctionDecl], conformances: [String] = []) {
        self.name = name
        self.properties = properties
        self.methods = methods
        self.initializers = initializers
        self.conformances = conformances
    }
}

package struct PropertyDecl: Equatable, Sendable {
    package var name: String
    package var mutable: Bool
    package var type: TypeAnnotation? = nil
    package var defaultValue: Expr? = nil
    /// A computed property's body; nil for a stored one.
    package var getter: Program? = nil
    package var getterNames = NamesUsed()

    package init(name: String, mutable: Bool, type: TypeAnnotation? = nil, defaultValue: Expr? = nil, getter: Program? = nil, getterNames: NamesUsed = NamesUsed()) {
        self.name = name
        self.mutable = mutable
        self.type = type
        self.defaultValue = defaultValue
        self.getter = getter
        self.getterNames = getterNames
    }
}

/// The `#` comment block directly above a `func`, for `--help`.
package struct Documentation: Equatable, Sendable {
    package var summary: String
    /// From `- Parameter name: description` lines.
    package var parameters: [String: String]

    package init(summary: String, parameters: [String: String]) {
        self.summary = summary
        self.parameters = parameters
    }
}

package struct ClosureLiteral: Equatable, Sendable {
    /// For `{ $0 * 2 }`, the implicit `$0`, `$1`, … parameters.
    package var parameters: [Parameter]
    package var returnType: TypeAnnotation?
    package var body: Program
    package var names = NamesUsed()

    package init(parameters: [Parameter], returnType: TypeAnnotation? = nil, body: Program, names: NamesUsed = NamesUsed()) {
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.names = names
    }
}

/// The names a body mentions, so a closure keeps only the variables it
/// uses rather than every scope around it (which would keep the scope it's
/// stored in, and leak). Not part of what the code says, so it doesn't
/// count toward equality.
package struct NamesUsed: Equatable, Sendable {
    package var names: Set<String> = []

    package static func == (lhs: NamesUsed, rhs: NamesUsed) -> Bool { true }

    package init(names: Set<String> = []) {
        self.names = names
    }
}

package struct Parameter: Equatable, Sendable {
    /// The argument label; nil for `_` (positional in command mode).
    package var label: String?
    package var name: String
    package var type: TypeAnnotation = .any
    package var variadic = false
    package var defaultValue: Expr?
    /// `@input`: receives pipeline input; per item, or the whole stream
    /// if its type is a list.
    package var isInput = false
    /// `@flag("n")`: a short flag in command mode.
    package var shortFlag: Character?
    /// A plugin's default only Swift can compute, like `Date()`: the
    /// argument is left out for the plugin to fill in. Its source, for help.
    package var externalDefault: String?

    package var hasDefault: Bool { defaultValue != nil || externalDefault != nil }

    package init(
        label: String? = nil, name: String, type: TypeAnnotation = .any, variadic: Bool = false,
        defaultValue: Expr? = nil, isInput: Bool = false, shortFlag: Character? = nil, externalDefault: String? = nil
    ) {
        self.label = label
        self.name = name
        self.type = type
        self.variadic = variadic
        self.defaultValue = defaultValue
        self.isInput = isInput
        self.shortFlag = shortFlag
        self.externalDefault = externalDefault
    }
}
