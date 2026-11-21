import Swiit

// What the shell asks of a type a parameter has: whether a word can be one, what a list of them
// holds.

extension TypeExpression {
    var isBool: Bool { self == .bool }

    /// `T` for `[T]`.
    var listElement: TypeExpression? {
        if case .named(let named) = self, named.reference == .array, named.arguments.count == 1 {
            named.arguments[0]
        } else {
            nil
        }
    }

    var isList: Bool { listElement != nil }

    /// `T` for `T?`.
    var optionalWrapped: TypeExpression? {
        if case .named(let named) = self, named.reference == .optional,
            named.arguments.count == 1
        {
            named.arguments[0]
        } else {
            nil
        }
    }

    /// Whether a closure can be passed for it.
    var acceptsFunction: Bool {
        switch self {
        case .function: true
        case .named(let named) where named.reference == .function || named.reference == .any: true
        default: optionalWrapped?.acceptsFunction ?? false
        }
    }

    /// Nothing is known of it: it fits anywhere.
    var isUnknown: Bool { self == .any }
}
