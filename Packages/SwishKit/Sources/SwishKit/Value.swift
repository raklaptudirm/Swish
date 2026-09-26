/// A value flowing through Swish.
///
/// This is the currency shared by the interpreter and every compiled plugin,
/// which is why it lives in its own dynamic library. More cases (paths, file
/// sizes, records, tables, closures, streams) arrive with the language.
public enum Value: Sendable, Hashable {
    case nothing
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([Value])
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
        }
    }
}
