import Foundation
import SwishKit

/// A pull-based stream of values between in-process pipeline stages. A
/// stage only runs when downstream asks for its next item, so
/// `… | first 5` stops upstream work early.
final class ValueStream {
    private let pull: () throws -> Value?

    init(_ pull: @escaping () throws -> Value?) {
        self.pull = pull
    }

    func next() throws -> Value? {
        try pull()
    }

    static var empty: ValueStream {
        ValueStream { nil }
    }

    /// A list flows as its elements, nothing as no items, anything else as
    /// a single item.
    static func elements(of value: Value) -> ValueStream {
        let items: [Value] = switch value {
        case .nothing: []
        case .list(let list): list
        default: [value]
        }
        var index = 0
        return ValueStream {
            guard index < items.count else { return nil }
            defer { index += 1 }
            return items[index]
        }
    }

    /// Lines of an external program's output, read as they arrive.
    static func lines(from fd: Int32) -> ValueStream {
        let reader = LineReader(fd: fd)
        return ValueStream { reader.next().map(Value.string) }
    }
}

private final class LineReader {
    private let fd: Int32
    private var buffer: [UInt8] = []
    private var start = 0
    private var atEnd = false

    init(fd: Int32) {
        self.fd = fd
    }

    func next() -> String? {
        while true {
            if let newline = buffer[start...].firstIndex(of: UInt8(ascii: "\n")) {
                var line = buffer[start..<newline]
                if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
                start = newline + 1
                return String(decoding: line, as: UTF8.self)
            }
            if atEnd {
                guard start < buffer.count else { return nil }
                defer { start = buffer.count }
                return String(decoding: buffer[start...], as: UTF8.self)
            }
            buffer.removeSubrange(..<start)
            start = 0
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer += chunk[..<count]
            } else if !(count == -1 && errno == EINTR) {
                atEnd = true
            }
        }
    }
}

/// Writing into a pipe whose reader has gone, as in `… | head -1`.
private struct BrokenPipe: Error {}

extension Shell {
    /// Runs the in-process run of a pipeline: reads `input` (an external
    /// stage's output, or -1 when the run starts the pipeline), and writes
    /// its items as text to `output`, one per line.
    func runSegment(_ stages: ArraySlice<Stage>, input: Int32, output: Int32, toExternal: Bool) throws {
        // Text the functions' own commands print goes to the same place.
        let savedOutput = stdoutFD
        stdoutFD = output
        defer { stdoutFD = savedOutput }

        var stream: ValueStream? = input >= 0 ? .lines(from: input) : nil
        var upstreamIsExternal = input >= 0
        for stage in stages {
            switch stage {
            case .value(let value):
                stream = .elements(of: value)
            case .function(let set, let args):
                stream = try functionStream(set, args, upstream: stream, upstreamIsExternal: upstreamIsExternal)
            case .external:
                preconditionFailure("external stages don't run in-process")
            }
            upstreamIsExternal = false
        }

        guard let stream else { return }
        do {
            if toExternal {
                while let item = try stream.next() {
                    try writeText(item, to: output)
                }
            } else {
                // The end of the pipeline: format for a person.
                let formatter = Formatter(fd: output)
                while let item = try stream.next() {
                    guard formatter.add(item) else { throw BrokenPipe() }
                }
                formatter.finish()
            }
        } catch is BrokenPipe {
            // The reader has what it wanted; stop producing.
        }
    }

    /// One line per item for an external program. Lists are written one
    /// element per line, since a list item is what a per-item function
    /// returns to produce several outputs. Records have no one obvious text
    /// form, so they need an explicit conversion rather than a guess.
    private func writeText(_ item: Value, to fd: Int32) throws {
        switch item {
        case .nothing:
            return
        case .list(let elements):
            for element in elements { try writeText(element, to: fd) }
        case .record(let record):
            throw RuntimeError("can't send a \(record.typeName ?? "Record") to an external command; "
                + "convert it with `to json` or `to text`, or pick a field with `get`")
        case .function:
            throw RuntimeError("can't send a function to an external command")
        default:
            guard writeAll(fd, item.description + "\n") else { throw BrokenPipe() }
        }
    }

    private func functionStream(
        _ set: OverloadSet, _ args: [CommandArgument], upstream: ValueStream?, upstreamIsExternal: Bool
    ) throws -> ValueStream {
        if helpRequested(args, for: set) {
            writeAll(stdoutFD, helpText(for: set))
            return .empty
        }

        guard let upstream else {
            // First in the pipeline: every parameter, @input included, comes
            // from the command line, and the function runs once.
            let (function, bindings) = try resolve(set) { try self.bind(commandLine: args, to: $0, excludingInput: false) }
            if case .stream(let transform) = function.body {
                let input = function.inputParameter.flatMap { bindings[$0.name] } ?? .list([])
                return try transform(self, .elements(of: input), bindings)
            }
            let result = try invoke(function, with: bindings)
            if let input = function.inputParameter, !input.type.isList {
                return .elements(of: .list([result]))
            }
            return .elements(of: result)
        }

        let (function, bindings) = try resolve(set) { try self.bind(commandLine: args, to: $0, excludingInput: true) }
        if case .stream(let transform) = function.body {
            return try transform(self, upstream, bindings)
        }
        let name = function.name ?? "closure"
        guard let input = function.inputParameter else {
            // Takes no input: let in-process stages before it run for their
            // effects, but don't wait on an external one, which may never end.
            if !upstreamIsExternal {
                while try upstream.next() != nil {}
            }
            return .elements(of: try invoke(function, with: bindings))
        }

        if case .list(let elementType) = input.type {
            var output: ValueStream?
            return ValueStream {
                if output == nil {
                    var items: [Value] = []
                    while let item = try upstream.next() {
                        items.append(try self.inputValue(item, as: elementType, of: name))
                    }
                    var arguments = bindings
                    arguments[input.name] = .list(items)
                    output = .elements(of: try self.invoke(function, with: arguments))
                }
                return try output!.next()
            }
        }

        return ValueStream {
            while let item = try upstream.next() {
                var arguments = bindings
                arguments[input.name] = try self.inputValue(item, as: input.type, of: name)
                let result = try self.invoke(function, with: arguments)
                if result != .nothing { return result }
            }
            return nil
        }
    }

    /// Input items as the parameter's type. Lines from external programs
    /// are text, so they're converted like command-line arguments.
    private func inputValue(_ item: Value, as type: TypeAnnotation, of name: String) throws -> Value {
        if let value = item.conforming(to: type) { return value }
        if case .string(let text) = item, let value = try? converted(text, to: type, for: "input", of: name) {
            return value
        }
        throw RuntimeError("\(name): input must be \(type), not \(item.typeName) '\(item)'")
    }
}
