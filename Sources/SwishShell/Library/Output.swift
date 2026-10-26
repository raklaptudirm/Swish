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

/// How a command exited, as `output.status` and a debug form give it: a struct of the Swift type
/// `Status`, by name, which stands for the prelude's `Status`. Host types are process-wide, so a
/// member of `Output` cannot make one of the prelude's, which an interpreter declares.
private struct Status: Encodable {  // named for what it stands for: the encoder names a struct by its Swift type
    let code: Int?
    let signal: Int?
    let succeeded: Bool

    enum CodingKeys: String, CodingKey { case code, signal, succeeded }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(signal, forKey: .signal)
        try container.encode(succeeded, forKey: .succeeded)
    }
}

/// A command's output laid out as the struct it is: its text and its status.
private struct OutputFields: Encodable {
    let text: String
    let status: Status
}

extension Output {
    private var exit: Status { Status(code: code, signal: signal, succeeded: succeeded) }

    /// How it exited, as the struct `output.status` is. Every field is there, and `nil` is a field.
    var statusFields: Value {
        (try? Value(encoding: exit)) ?? .nothing
    }

    /// How a debug form lays it out: its text and status as the fields of a struct.
    var displayValue: Value {
        (try? Value(encoding: OutputFields(text: text, status: exit), as: Output.id)) ?? .nothing
    }
}

extension Value {
    /// What `$(…)` gives: a command's output, held as the Swift value it is.
    static func output(_ output: Output) -> Value { Value(boxing: output) }

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
