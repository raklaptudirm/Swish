import Foundation
import Swiit

/// A command's standard output (trailing newlines trimmed) and exit status.
/// It's a collection of lines: iterating, counting and indexing go by line,
/// and where a String is wanted it's the whole text.
struct Output: Sendable, Hashable, RandomAccessCollection {
    /// All of it, as one String.
    public let text: String
    /// The exit code, or nil if a signal ended the command.
    public let code: Int?
    /// The signal that ended the command, if one did.
    public let signal: Int?
    /// One String for each line.
    public let lines: [String]

    public init(text: String, code: Int?, signal: Int? = nil) {
        self.text = text
        self.code = code
        self.signal = signal
        lines =
            text.isEmpty
            ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    public var succeeded: Bool {
        code == 0
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

extension Output {
    /// How it exited, laid out as the struct `output.status` is, for showing: a struct of the
    /// Swift type `Status`, by name, so it is shown as one. (`output.status` itself is the
    /// prelude's `Status`.)
    var statusFields: Value {
        Value(
            struct: "Status",
            fields: [
                "code": code.map { Value($0) } ?? Value.nothing,
                "signal": signal.map { Value($0) } ?? Value.nothing,
                "succeeded": Value(succeeded),
            ]
        )
    }

    /// How a debug form lays it out: its text and status as the fields of a struct.
    var displayValue: Value {
        Value(
            struct: "Output",
            fields: [
                "text": Value(text),
                "status": statusFields,
            ]
        )
    }
}

extension Value {
    /// What `$(…)` gives: a command's output, held as the Swift value it is.
    static func output(_ output: Output) -> Value { Value(boxing: output, as: "Output") }

    /// The command output it holds, if it's one.
    var commandOutput: Output? { try? unboxed(Output.self) }
}

extension Output: ScriptConvertible {
    static let id = Symbol.ID(hostType: "Output")
    static var scriptType: ScriptType { .named(id) }
    init(_ swiitValue: Value) throws {
        guard let value = swiitValue.commandOutput else {
            throw LibraryError("expected an Output, not \(swiitValue)")
        }
        self = value
    }
    var value: Value { .output(self) }
}

/// What a library function says when a value is not what it takes.
struct LibraryError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
