import Swiit
import Foundation
import SwiitStandardLibrary

/// Items read one at a time, as the stages of a pipeline pass them on.
final class ValueStream {
    private let pull: () throws -> Value?

    init(_ pull: @escaping () throws -> Value?) {
        self.pull = pull
    }

    func next() throws -> Value? { try pull() }

    static var empty: ValueStream { ValueStream { nil } }

    /// A list flows as its elements, as does a Swift sequence (a Set, a range of Ints, a command's output, a flow); nothing
    /// as no items, anything else as a single item.
    static func elements(of value: Value) -> ValueStream {
        if value.kind == .nothing { return .empty }
        if let flow = value.flow { return ValueStream { try flow.read() } }
        if let items = value.items {
            var iterator = items.makeIterator()
            return ValueStream { iterator.next() }
        }
        var pending: Value? = value
        return ValueStream {
            defer { pending = nil }
            return pending
        }
    }

    /// Lines of an external program's output, read as they arrive.
    /// Reading waits through the interpreter, so other tasks run meanwhile.
    static func lines(from fd: Int32) -> ValueStream {
        let reader = LineReader(fd: fd)
        return ValueStream { reader.next().map { Value($0) } }
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
            let count = Interpreter.whileWaiting { read(fd, &chunk, chunk.count) }
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
        var single: Value?
        for var stage in stages {
            if case .deferred(let deferred) = stage {
                if let upstream = stream {
                    let resolved = try resolve(deferred, upstream: upstream, single: single)
                    stage = resolved.stage
                    stream = resolved.upstream
                } else {
                    stage = try deferred.fallback()
                }
            }
            single = nil
            switch stage {
            case .value(let value):
                stream = .elements(of: value)
                single = value
            case .function(let callee, let args, _, _):
                stream = try functionStream(callee, args, upstream: stream, single: single, upstreamIsExternal: upstreamIsExternal)
            case .external(let argv, _, _, _):
                // A name that might have been a method, and was a program after all (Shell+Resolving.swift).
                throw RuntimeError("\(argv[0]) isn't a method of what flows into it, and a program can't run here")
            case .deferred:
                preconditionFailure("a deferred stage is resolved above")
            }
            upstreamIsExternal = false
        }

        guard let stream else { return }
        try display(stream, to: output, toExternal: toExternal)
    }

    /// A value's items, shown as the end of a pipeline shows them.
    func displayItems(_ value: Value) throws {
        try display(.elements(of: value), to: stdoutFD, toExternal: false)
    }

    /// Writes items as text: for a person, formatted, or for a program, as rows.
    private func display(_ stream: ValueStream, to output: Int32, toExternal: Bool) throws {
        do {
            if toExternal {
                // Records as the rows they'd display as, so `ls | grep x` works.
                let formatter = DisplayFormatter.forProgram(fd: output, registry: displayRegistry)
                while let item = try stream.next() {
                    if item.kind == .function { throw RuntimeError("can't send a function to an external command") }
                    guard formatter.add(item) else { throw BrokenPipe() }
                }
                guard formatter.finish() else { throw BrokenPipe() }
            } else {
                // The end of the pipeline: format for a person.
                let formatter = DisplayFormatter(fd: output, registry: displayRegistry)
                while let item = try stream.next() {
                    guard formatter.add(item) else { throw BrokenPipe() }
                }
                formatter.finish()
            }
        } catch is BrokenPipe {
            // The reader has what it wanted; stop producing.
        }
    }

    private func functionStream(
        _ callee: Callee, _ args: [CommandArgument], upstream: ValueStream?, single: Value?, upstreamIsExternal: Bool
    ) throws -> ValueStream {
        if helpRequested(args, for: callee) {
            writeAll(stdoutFD, helpText(for: callee, styled: DisplayStyle.enabled(for: stdoutFD)))
            return .empty
        }
        if let receiver = callee.receiver {
            return try methodStream(callee, args, receiver: receiver, upstream: upstream ?? .empty, single: single)
        }

        guard let upstream else {
            // First in the pipeline: every parameter, @input included, comes
            // from the command line, and the function runs once.
            let call = try bind(commandLine: args, to: callee, excludingInput: false)
            let result = try invoke(callee, call.arguments())
            if let input = callee.parameters[call.overload].first(where: \.isInput), !input.type.isList {
                return .elements(of: Value([result]))
            }
            return .elements(of: result)
        }

        let call = try bind(commandLine: args, to: callee, excludingInput: true)
        return stream(call, upstream: upstream, upstreamIsExternal: upstreamIsExternal)
    }

    /// `call` fed by `upstream`: once per item for an item parameter, or once with them all for a list.
    private func stream(_ call: BoundCall, upstream: ValueStream, upstreamIsExternal: Bool) -> ValueStream {
        let callee = call.callee
        guard let input = callee.parameters[call.overload].first(where: \.isInput) else {
            // Takes no input: let in-process stages before it run for their
            // effects, but don't wait on an external one, which may never end.
            var output: ValueStream?
            return ValueStream {
                if output == nil {
                    if !upstreamIsExternal {
                        while try upstream.next() != nil {}
                    }
                    output = .elements(of: try self.invoke(callee, call.arguments()))
                }
                return try output!.next()
            }
        }

        if let elementType = input.type.listElement {
            var output: ValueStream?
            return ValueStream {
                if output == nil {
                    var items: [Value] = []
                    while let item = try upstream.next() {
                        items.append(try self.inputValue(item, as: elementType, of: callee.name))
                    }
                    output = .elements(of: try self.invoke(callee, call.arguments(input: (input.name, Value(items)))))
                }
                return try output!.next()
            }
        }

        return ValueStream {
            while let item = try upstream.next() {
                let value = try self.inputValue(item, as: input.type, of: callee.name)
                let result = try self.invoke(callee, call.arguments(input: (input.name, value)))
                if result.kind != .nothing { return result }
            }
            return nil
        }
    }

    // MARK: Methods

    /// A method of what flows in: of each item (`[p1, p2] | describe`), of the items collected, of the one value the pipeline
    /// started from, or of the items as they come, lazily.
    private func methodStream(
        _ callee: Callee, _ args: [CommandArgument], receiver: StageReceiver, upstream: ValueStream, single: Value?
    ) throws -> ValueStream {
        let call = try bind(commandLine: args, to: callee, excludingInput: true)
        let overload = callee.overloads[call.overload]
        if let function = overload.function, function.isMutating {
            throw RuntimeError("\(callee.name) is mutating, and a piped value can't change: call it on a variable")
        }
        let isProperty = overload.function == nil
        func apply(to value: Value) throws -> Value {
            isProperty
                ? try interpreter.value(of: callee.name, in: value)
                : try invoke(callee, call.arguments(), on: value)
        }
        switch receiver {
        case .each:
            return ValueStream {
                while let item = try upstream.next() {
                    let result = try apply(to: item)
                    if result.kind != .nothing { return result }
                }
                return nil
            }
        case .collected:
            var output: ValueStream?
            return ValueStream {
                if output == nil {
                    var items: [Value] = []
                    while let item = try upstream.next() { items.append(item) }
                    output = .elements(of: try apply(to: Value(items)))
                }
                return try output!.next()
            }
        case .value:
            var output: ValueStream?
            return ValueStream {
                if output == nil {
                    // The one value is the receiver, not a sequence's items.
                    let value = try single ?? upstream.next() ?? Value.null
                    while try upstream.next() != nil {}
                    output = .elements(of: try apply(to: value))
                }
                return try output!.next()
            }
        case .flow:
            // Lazily: the stage reads upstream only as its own reader is asked, and the Flow it gives is read as the next
            // stage asks.
            let flow = Value(boxing: Flow<Value> { try upstream.next() }, as: "Flow")
            let result = try apply(to: flow)
            if let produced = result.flow { return ValueStream { try produced.read() } }
            return .elements(of: result)
        }
    }

    /// Input items as the parameter's type. Lines from external programs
    /// are text, so they're converted like command-line arguments.
    private func inputValue(_ item: Value, as type: ValueType, of name: String) throws -> Value {
        if let value = interpreter.convert(item, to: type) { return value }
        if item.kind == .string, let value = try? converted(item.description, to: type, for: "input", of: name) {
            return value
        }
        throw RuntimeError("\(name): input must be \(type), not \(item.typeName) '\(item)'")
    }
}
