/// A value flowing through Swish.
///
/// This is the currency shared by the interpreter and every compiled plugin,
/// which is why it lives in its own dynamic library. More cases (paths, file
/// sizes, records, objects, streams) arrive with structured data.
public enum Value: Sendable {
    case nothing
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([Value])
    case function(any Callable)
}

/// A function value. The interpreter implements this for Swish functions and
/// closures; plugins will implement it for bridged Swift functions.
public protocol Callable: AnyObject, Sendable, CustomStringConvertible {}

extension Value: Hashable {
    /// Functions compare by identity.
    public static func == (lhs: Value, rhs: Value) -> Bool {
        switch (lhs, rhs) {
        case (.nothing, .nothing): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.double(let a), .double(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.list(let a), .list(let b)): a == b
        case (.function(let a), .function(let b)): a === b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .nothing: hasher.combine(0)
        case .bool(let value): hasher.combine(value)
        case .int(let value): hasher.combine(value)
        case .double(let value): hasher.combine(value)
        case .string(let value): hasher.combine(value)
        case .list(let values): hasher.combine(values)
        case .function(let function): hasher.combine(ObjectIdentifier(function))
        }
    }
}

extension Value: CustomStringConvertible {
    public var description: String {
        switch self {
        case .nothing: ""
        case .bool(let value): String(value)
        case .int(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        case .list(let values): "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .function(let function): function.description
        }
    }
}
