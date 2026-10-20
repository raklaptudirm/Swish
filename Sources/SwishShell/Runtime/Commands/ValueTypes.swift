import Swiit

// What the shell asks of a type a parameter has: whether a word can be one, what a list of them holds.

extension ValueType {
    var isBool: Bool { self == .bool }

    /// `T` for `[T]`.
    var listElement: ValueType? {
        if case .named("Array", let arguments) = self, arguments.count == 1 { arguments[0] } else { nil }
    }

    var isList: Bool { listElement != nil }

    /// `T` for `T?`.
    var optionalWrapped: ValueType? {
        if case .named("Optional", let arguments) = self, arguments.count == 1 { arguments[0] } else { nil }
    }

    /// Whether a closure can be passed for it.
    var acceptsFunction: Bool {
        switch self {
        case .function: true
        case .named("Function", _), .named("Any", _): true
        default: optionalWrapped?.acceptsFunction ?? false
        }
    }

    /// Nothing is known of it: it fits anywhere.
    var isUnknown: Bool { self == .any }
}
