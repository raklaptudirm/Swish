import Foundation
import Swiit

/// A command's standard output (trailing newlines trimmed) and exit status.
/// It's a collection of lines: iterating, counting and indexing go by line,
/// and where a String is wanted it's the whole text.
struct Output: Sendable, Hashable, RandomAccessCollection {
    /// All of it, as one String.
    public let text: String
    /// How the command ended.
    public let status: Status
    /// One String for each line.
    public let lines: [String]

    public init(text: String, status: Status) {
        self.text = text
        self.status = status
        lines =
            text.isEmpty
            ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: Collection of lines

    public typealias Element = String
    public typealias Index = Int

    public var startIndex: Int { lines.startIndex }
    public var endIndex: Int { lines.endIndex }
    public subscript(position: Int) -> String { lines[position] }
}

extension Output: CustomStringConvertible, CustomDebugStringConvertible, Presentable {
    var description: String { text }
    /// Shown as its text and status, and nothing at all if it's empty.
    var shape: DisplayShape { DisplayShape(isEmpty: text.isEmpty) }
    /// One line in a table: its newlines shown as ↵.
    var cell: String { text.replacingOccurrences(of: "\n", with: "↵") }
    var debugDescription: String {
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
    var statusFields: Value {
        (try? Value(encoding: status)) ?? .nothing
    }

    /// How a debug form lays it out: its text and status as the fields of a struct.
    var displayValue: Value {
        (try? Value(encoding: OutputFields(text: text, status: status), as: Output.id)) ?? .nothing
    }
}

extension Value {
    /// What `$(…)` gives: a command's output, held as the Swift value it is.
    static func output(_ output: Output) -> Value { Value(output) }

    /// The command output it holds, if it's one.
    var commandOutput: Output? { casting(to: Output.self) }
}

extension Output: ScriptConvertible {
    static let id = Symbol.ID(hostType: "Output")
}

/// What a library function says when a value is not what it takes.
struct LibraryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
