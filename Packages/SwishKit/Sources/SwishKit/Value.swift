import Foundation

/// A value flowing through Swish.
///
/// This is the currency shared by the interpreter and every compiled plugin,
/// which is why it lives in its own dynamic library.
public enum Value: Sendable {
    case nothing
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case list([Value])
    /// Named fields in order, like a row of a table.
    case record(Record)
    /// A size in bytes, shown as `1.2 MB`.
    case filesize(Int64)
    case date(Date)
    /// What `$(…)` gives: a command's output and how it exited.
    case output(CommandOutput)
    /// A case of an enum: `.directory`, or `.failed(code: 2)`.
    case enumValue(EnumValue)
    /// A live value with members of its own: a background job, an enum type,
    /// and later bridged Swift objects.
    case object(any SwishObject)
    case function(any Callable)
}

/// A live value that answers for its own members, properties and methods
/// alike (a method is a function value). Objects compare by identity.
public protocol SwishObject: AnyObject, Sendable, CustomStringConvertible {
    /// The name `members` and error messages use, like `Job`.
    var typeName: String { get }
    /// Names of its members, for `members` and completion.
    var memberNames: [String] { get }
    /// The member called `name`, or nil if it has none.
    func member(_ name: String) -> Value?
    /// Its data as a record, which tables, `select` and `to json` use; nil
    /// for an object that isn't data, like an enum type.
    var fields: Record? { get }
}

extension SwishObject {
    /// Every member that isn't a method, in `memberNames` order.
    public var fields: Record? {
        var record = Record(typeName: typeName)
        for name in memberNames {
            guard let value = member(name) else { continue }
            if case .function = value { continue }
            record[name] = value
        }
        return record
    }
}

/// A command's standard output (trailing newlines trimmed) and exit status.
/// It's a collection of lines: iterating, counting and indexing go by line,
/// and where a String is wanted it's the whole text.
public struct CommandOutput: Sendable, Hashable {
    public var text: String
    /// The exit code, or nil if a signal ended the command.
    public var code: Int?
    /// The signal that ended the command, if one did.
    public var signal: Int?

    public init(text: String, code: Int?, signal: Int? = nil) {
        self.text = text
        self.code = code
        self.signal = signal
    }

    public var lines: [String] {
        text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    public var succeeded: Bool {
        code == 0
    }
}

/// A function value. The interpreter implements this for Swish functions and
/// closures; plugins will implement it for bridged Swift functions.
public protocol Callable: AnyObject, Sendable, CustomStringConvertible {}

/// Fields in insertion order. Two records are equal when they have the same
/// fields, whatever their order or type name.
public struct Record: Sendable, Hashable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: Value] = [:]
    /// The Swift type this record came from, like `FileEntry`, which picks
    /// how it's displayed.
    public var typeName: String?

    public init(typeName: String? = nil) {
        self.typeName = typeName
    }

    public init(_ fields: KeyValuePairs<String, Value>, typeName: String? = nil) {
        self.typeName = typeName
        for (key, value) in fields { self[key] = value }
    }

    public subscript(key: String) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }

    public func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
        keys.lazy.map { (key: $0, value: storage[$0]!) }.makeIterator()
    }

    public static func == (lhs: Record, rhs: Record) -> Bool {
        lhs.storage == rhs.storage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}

/// Encodes as a `.filesize` value through `ValueEncoder`, and as a plain
/// byte count elsewhere.
public struct FileSize: Codable, Hashable, Sendable {
    public var bytes: Int64

    public init(bytes: Int64) {
        self.bytes = bytes
    }

    public init(from decoder: any Decoder) throws {
        bytes = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

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
        case (.record(let a), .record(let b)): a == b
        case (.filesize(let a), .filesize(let b)): a == b
        case (.date(let a), .date(let b)): a == b
        case (.output(let a), .output(let b)): a == b
        case (.enumValue(let a), .enumValue(let b)): a == b
        case (.object(let a), .object(let b)): a === b
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
        case .record(let record): hasher.combine(record)
        case .filesize(let bytes): hasher.combine(bytes)
        case .date(let date): hasher.combine(date)
        case .output(let output): hasher.combine(output)
        case .enumValue(let value): hasher.combine(value)
        case .object(let object): hasher.combine(ObjectIdentifier(object))
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
        case .record(let record): "{" + record.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
        case .filesize(let bytes): Value.formatFileSize(bytes)
        case .date(let date): Value.dateFormatter.string(from: date)
        case .output(let output): output.text
        case .enumValue(let value): value.description
        case .object(let object): object.description
        case .function(let function): function.description
        }
    }

    /// Decimal units, as Finder shows them: `532 B`, `1.2 KB`, `123 MB`.
    public static func formatFileSize(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var size = Double(bytes.magnitude)
        var unit = 0
        while size >= 1000 && unit < units.count - 1 {
            size /= 1000
            unit += 1
        }
        let sign = bytes < 0 ? "-" : ""
        if unit == 0 { return "\(sign)\(bytes.magnitude) B" }
        let number = size < 100 ? String(format: "%.1f", size) : String(format: "%.0f", size)
        return "\(sign)\(number) \(units[unit])"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}
