import Foundation
import SwishKit

struct FunctionDecl: Equatable, Sendable {
    var name: String
    var parameters: [Parameter]
    var returnType: TypeAnnotation?
    var body: Program
    var documentation: Documentation?
    /// A struct's `mutating func`, which may change `self`.
    var isMutating = false
    /// `throws`: calling it needs `try`.
    var isThrowing = false
    /// `rethrows`: it throws only if a closure passed to it does.
    var isRethrowing = false
    /// `<T, V: Comparable>` and `where` clauses: each type parameter, and
    /// the protocols it must conform to. Only the prelude has these, for now.
    var generics: [String: [String]] = [:]
    var names = NamesUsed()
}

/// Assigning to a variable, or to part of one: `p.x`, `xs[0]`, `r["k"]`.
struct Assignment: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case member(String)
        case index(Expr)
    }

    var root: String
    var path: [Step] = []
    /// `+=` and the like: the operator applied to the current value.
    var op: BinaryOperator?
    var value: Expr
}

/// `struct Name { var x: Int; func f() {…}; init(…) {…} }`.
struct StructDecl: Equatable, Sendable {
    var name: String
    var properties: [PropertyDecl]
    var methods: [FunctionDecl]
    var initializers: [FunctionDecl]
    /// `struct Point: Equatable, Hashable`.
    var conformances: [String] = []
    /// `static let origin = Point(x: 0, y: 0)`: values of the type itself,
    /// and `static func`s, which are called on it: `Point.origin`.
    var staticProperties: [PropertyDecl] = []
    var staticMethods: [FunctionDecl] = []
}

struct PropertyDecl: Equatable, Sendable {
    var name: String
    var mutable: Bool
    var type: TypeAnnotation? = nil
    var defaultValue: Expr? = nil
    /// A computed property's body; nil for a stored one.
    var getter: Program? = nil
    var getterNames = NamesUsed()
}

/// The `#` comment block directly above a `func`, for `--help`.
struct Documentation: Equatable, Sendable {
    var summary: String
    /// From `- Parameter name: description` lines.
    var parameters: [String: String]
}

struct ClosureLiteral: Equatable, Sendable {
    /// For `{ $0 * 2 }`, the implicit `$0`, `$1`, … parameters.
    var parameters: [Parameter]
    var returnType: TypeAnnotation?
    var body: Program
    var names = NamesUsed()
}

/// The names a body mentions, so a closure keeps only the variables it
/// uses rather than every scope around it (which would keep the scope it's
/// stored in, and leak). Not part of what the code says, so it doesn't
/// count toward equality.
struct NamesUsed: Equatable, Sendable {
    var names: Set<String> = []

    static func == (lhs: NamesUsed, rhs: NamesUsed) -> Bool { true }
}

struct Parameter: Equatable, Sendable {
    /// The argument label; nil for `_` (positional in command mode).
    var label: String?
    var name: String
    var type: TypeAnnotation = .any
    var variadic = false
    var defaultValue: Expr?
    /// `@input`: receives pipeline input; per item, or the whole stream
    /// if its type is a list.
    var isInput = false
    /// `@flag("n")`: a short flag in command mode.
    var shortFlag: Character?
    /// A plugin's default only Swift can compute, like `Date()`: the
    /// argument is left out for the plugin to fill in. Its source, for help.
    var externalDefault: String?

    var hasDefault: Bool { defaultValue != nil || externalDefault != nil }
}
