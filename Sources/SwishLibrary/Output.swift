import Foundation
import Swiit

/// A command's standard output (trailing newlines trimmed) and exit status.
/// It's a collection of lines: iterating, counting and indexing go by line,
/// and where a String is wanted it's the whole text.
public struct Output: Sendable, Hashable, RandomAccessCollection {
    /// All of it, as one String.
    public let text: String
    /// How the command ended.
    public let status: Status
    /// One String for each line: always `text` split at its newlines, kept so that indexing and
    /// counting do not split it again.
    public let lines: [String]

    package init(text: String, status: Status) {
        self.text = text
        self.status = status
        lines =
            text.isEmpty
            ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// An output of this text that ended as a command with this code, or this signal, would.
    public init(text: String, code: Int?, signal: Int?) {
        self.init(
            text: text,
            status: signal.map { Status.signaled(Int32($0)) } ?? .exited(Int32(code ?? 0))
        )
    }

    // MARK: Collection of lines

    public typealias Element = String
    public typealias Index = Int

    public var startIndex: Int { lines.startIndex }
    public var endIndex: Int { lines.endIndex }
    public subscript(position: Int) -> String { lines[position] }

    // The collection's own, which scripts read as members of a list.
    public var count: Int { lines.count }
    public var isEmpty: Bool { lines.isEmpty }
    public var first: String? { lines.first }
    public var last: String? { lines.last }
}

/// A command's output compares with text as its text does, on either side.
extension Output {
    public static func == (lhs: Output, rhs: String) -> Bool { lhs.text == rhs }
    public static func == (lhs: String, rhs: Output) -> Bool { lhs == rhs.text }
    public static func != (lhs: Output, rhs: String) -> Bool { lhs.text != rhs }
    public static func != (lhs: String, rhs: Output) -> Bool { lhs != rhs.text }
    public static func < (lhs: Output, rhs: String) -> Bool { lhs.text < rhs }
    public static func < (lhs: String, rhs: Output) -> Bool { lhs < rhs.text }
    public static func > (lhs: Output, rhs: String) -> Bool { lhs.text > rhs }
    public static func > (lhs: String, rhs: Output) -> Bool { lhs > rhs.text }
    public static func <= (lhs: Output, rhs: String) -> Bool { lhs.text <= rhs }
    public static func <= (lhs: String, rhs: Output) -> Bool { lhs <= rhs.text }
    public static func >= (lhs: Output, rhs: String) -> Bool { lhs.text >= rhs }
    public static func >= (lhs: String, rhs: Output) -> Bool { lhs >= rhs.text }
}

extension Output: CustomStringConvertible, CustomDebugStringConvertible, Presentable {
    public var description: String { text }
    /// Shown as its text and status, and nothing at all if it's empty.
    public var shape: DisplayShape { DisplayShape(isEmpty: text.isEmpty) }
    /// One line in a table: its newlines shown as ↵.
    public var cell: String { text.replacingOccurrences(of: "\n", with: "↵") }
    public var debugDescription: String {
        "Output(text: \(Value(text).debugDescription), status: \(statusFields.debugDescription))"
    }
}

/// A command's output laid out as the struct it is: its text and its status.
private struct OutputFields: Encodable {
    let text: String
    let status: Status
}

extension Output {
    /// How it exited, as the struct `output.status` is.
    package var statusFields: Value {
        (try? Value(encoding: status)) ?? .nothing
    }

    /// How a debug form lays it out: its text and status as the fields of a struct.
    package var displayValue: Value {
        (try? Value(encoding: OutputFields(text: text, status: status), as: Output.id)) ?? .nothing
    }
}

extension Output: BridgedType {
    package static let id = Symbol.ID(hostType: "Output")
}

/// What a library function says when a value is not what it takes.
public struct LibraryError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}
