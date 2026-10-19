@_spi(Layer) import SwishShellLibrary
import Foundation
@_spi(Layer) import Swiit

/// A command's standard output (trailing newlines trimmed) and exit status.
/// It's a collection of lines: iterating, counting and indexing go by line,
/// and where a String is wanted it's the whole text.
@_spi(Layer) public struct Output: Sendable, Hashable, RandomAccessCollection, StandsForText {
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
        lines = text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    public var succeeded: Bool {
        code == 0
    }

    /// `output.status`: how the command exited.
    public var status: Status {
        Status(code: code, signal: signal, succeeded: succeeded)
    }

    // MARK: Collection of lines

    public typealias Element = String
    public typealias Index = Int

    public var startIndex: Int { lines.startIndex }
    public var endIndex: Int { lines.endIndex }
    public subscript(position: Int) -> String { lines[position] }
}

/// How a command exited: `output.status`.
@_spi(Layer) public struct Status: Sendable, Hashable, Encodable {
    public let code: Int?
    public let signal: Int?
    public let succeeded: Bool

    public init(code: Int?, signal: Int?, succeeded: Bool) {
        self.code = code
        self.signal = signal
        self.succeeded = succeeded
    }
}

extension Output: CustomStringConvertible, CustomDebugStringConvertible, SwiitDisplayed {
    @_spi(Layer) public var description: String { text }
    @_spi(Layer) public var swiitDescription: String { text }
    /// Shown as its text and status, and nothing at all if it's empty.
    @_spi(Layer) public var swiitShape: DisplayShape { DisplayShape(isEmpty: text.isEmpty) }
    /// How a debug form lays it out: its text and status as the fields of a struct.
    @_spi(Layer) public var displayRecord: Record {
        Record(["text": .string(text), "status": .record(statusRecord)], typeName: "Output")
    }
    /// One line in a table: its newlines shown as ↵.
    @_spi(Layer) public var swiitCell: String { text.replacingOccurrences(of: "\n", with: "↵") }
    /// The record `output.status` is, with every field there.
    @_spi(Layer) public var statusRecord: Record {
        Record([
            "code": code.map(Value.int) ?? .nothing,
            "signal": signal.map(Value.int) ?? .nothing,
            "succeeded": .bool(succeeded),
        ], typeName: "Status")
    }
    @_spi(Layer) public var debugDescription: String {
        "Output(text: \(Value.quoted(text)), status: \(statusRecord.debugDescription))"
    }
    @_spi(Layer) public var swiitDebugDescription: String { debugDescription }
}

extension Value {
    /// What `$(…)` gives: a command's output, held as the Swift value it is.
    @_spi(Layer) public static func output(_ output: Output) -> Value {
        SwiftValue.make(output, as: "Output")
    }

    /// The command output it holds, if it's one.
    @_spi(Layer) public var commandOutput: Output? {
        if case .object(let box as SwiftValue) = self { box.value as? Output } else { nil }
    }
}

extension Output: ValueConvertible {
    @_spi(Layer) public static var valueType: ValueType { .named("Output") }
    @_spi(Layer) public init(_ swiitValue: Value) throws {
        guard let value = swiitValue.commandOutput else { throw SwiitError("expected an Output, not \(swiitValue)") }
        self = value
    }
    @_spi(Layer) public var value: Value { .output(self) }
}
