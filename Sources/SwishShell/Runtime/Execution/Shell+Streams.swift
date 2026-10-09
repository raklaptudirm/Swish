@_spi(Shell) import Swiit
import Foundation
import SwishKit
import SwishStandardLibrary

extension ValueStream {
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
            case .function(let set, let args, _, _):
                stream = try functionStream(set, args, upstream: stream, upstreamIsExternal: upstreamIsExternal)
            case .method(let name, let args, _, _):
                stream = methodStream(name, args, upstream: stream ?? .empty)
            case .external:
                preconditionFailure("external stages don't run in-process")
            }
            upstreamIsExternal = false
        }

        guard let stream else { return }
        do {
            if toExternal {
                // Records as the rows they'd display as, so `ls | grep x` works.
                let formatter = DisplayFormatter.forProgram(fd: output, registry: interpreter.displayRegistry)
                while let item = try stream.next() {
                    if case .function = item { throw RuntimeError("can't send a function to an external command") }
                    guard formatter.add(item) else { throw BrokenPipe() }
                }
                guard formatter.finish() else { throw BrokenPipe() }
            } else {
                // The end of the pipeline: format for a person.
                let formatter = DisplayFormatter(fd: output, registry: interpreter.displayRegistry)
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
        _ set: OverloadSet, _ args: [CommandArgument], upstream: ValueStream?, upstreamIsExternal: Bool
    ) throws -> ValueStream {
        if helpRequested(args, for: set) {
            writeAll(stdoutFD, helpText(for: set, styled: DisplayStyle.enabled(for: stdoutFD)))
            return .empty
        }

        guard let upstream else {
            // First in the pipeline: every parameter, @input included, comes
            // from the command line, and the function runs once.
            let (function, bindings) = try interpreter.resolve(set) { try self.bind(commandLine: args, to: $0, excludingInput: false) }
            if case .stream(let transform) = function.body {
                let input = function.inputParameter.flatMap { bindings[$0.name] } ?? .list([])
                return try transform(interpreter, .elements(of: input), bindings)
            }
            let result = try interpreter.invoke(function, with: bindings)
            if let input = function.inputParameter, !input.type.isList {
                return .elements(of: .list([result]))
            }
            return .elements(of: result)
        }

        let (function, bindings) = try interpreter.resolve(set) { try self.bind(commandLine: args, to: $0, excludingInput: true) }
        return try stream(function, bindings, upstream: upstream, upstreamIsExternal: upstreamIsExternal)
    }

    /// `function` fed by `upstream`: once per item for an item parameter,
    /// once with them all for a list, or lazily for a stream builtin.
    private func stream(
        _ function: Function, _ bindings: [String: Value], upstream: ValueStream, upstreamIsExternal: Bool
    ) throws -> ValueStream {
        if case .stream(let transform) = function.body {
            return try transform(interpreter, upstream, bindings)
        }
        let name = function.name ?? "closure"
        guard let input = function.inputParameter else {
            // Takes no input: let in-process stages before it run for their
            // effects, but don't wait on an external one, which may never end.
            if !upstreamIsExternal {
                while try upstream.next() != nil {}
            }
            return .elements(of: try interpreter.invoke(function, with: bindings))
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
                    output = .elements(of: try self.interpreter.invoke(function, with: arguments))
                }
                return try output!.next()
            }
        }

        return ValueStream {
            while let item = try upstream.next() {
                var arguments = bindings
                arguments[input.name] = try self.inputValue(item, as: input.type, of: name)
                let result = try self.interpreter.invoke(function, with: arguments)
                if result != .nothing { return result }
            }
            return nil
        }
    }

    // MARK: Methods

    /// `xs.sorted(by: "size")`: a sequence method called on a list, with
    /// the list as its input, and a list back (or a count, for `count`).
    func callSequenceMethod(_ methods: OverloadSet, on items: [Value], _ arguments: [Argument]) throws -> Value {
        let values = try [Argument(label: nil, value: .literal(.list(items)))] + arguments.map { argument -> Argument in
            if case .caseLiteral = argument.value { return argument }
            return Argument(label: argument.label, value: .literal(try interpreter.evaluate(argument.value)))
        }
        let (function, bindings) = try interpreter.resolve(methods) { try self.interpreter.bind(values, to: $0) }
        guard let input = function.inputParameter else { return try interpreter.invoke(function, with: bindings) }
        if input.type.isList, case .native = function.body {
            return try interpreter.invoke(function, with: bindings)
        }
        var rest = bindings
        rest.removeValue(forKey: input.name)
        let output = try stream(function, rest, upstream: .elements(of: .list(items)), upstreamIsExternal: false)
        var results: [Value] = []
        while let item = try output.next() { results.append(item) }
        return .list(results)
    }

    /// `[p1, p2] | describe`: the method called on each item, with the
    /// stage's arguments; what it returns flows on.
    func methodStream(_ name: String, _ args: [CommandArgument], upstream: ValueStream) -> ValueStream {
        ValueStream {
            while let item = try upstream.next() {
                let result = try self.callItemMethod(name, args, on: item)
                if result != .nothing { return result }
            }
            return nil
        }
    }

    private func callItemMethod(_ name: String, _ args: [CommandArgument], on item: Value) throws -> Value {
        switch item {
        case .record(let record):
            if let type = interpreter.structType(of: record), let methods = type.methods[name] {
                let (method, bindings) = try interpreter.resolve(methods) { try self.bind(commandLine: args, to: $0, excludingInput: false) }
                guard !method.isMutating else {
                    throw RuntimeError("\(type.name).\(name) is mutating, and a piped value can't change: call it on a variable")
                }
                return try interpreter.invoke(method, with: bindings, receiver: Receiver(item, mutable: false))
            }
        case .object(let object):
            let callable: OverloadSet? = switch object.member(name) {
            case .function(let set as OverloadSet)?: set
            case .function(let native as NativeFunction)?: OverloadSet(name: name, candidates: [interpreter.hostFunction(native.function)])
            default: nil
            }
            if let callable {
                let (method, bindings) = try interpreter.resolve(callable) { try self.bind(commandLine: args, to: $0, excludingInput: false) }
                return try interpreter.invoke(method, with: bindings)
            }
        default:
            break
        }
        let type = if case .record(let record) = item { record.typeName ?? "Record" } else { item.typeName }
        throw RuntimeError("\(name): not a method of \(type), nor a function or program")
    }

    /// Input items as the parameter's type. Lines from external programs
    /// are text, so they're converted like command-line arguments.
    private func inputValue(_ item: Value, as type: TypeAnnotation, of name: String) throws -> Value {
        if let value = interpreter.conform(item, to: type) { return value }
        if case .string(let text) = item, let value = try? converted(text, to: type, for: "input", of: name) {
            return value
        }
        throw RuntimeError("\(name): input must be \(type), not \(item.typeName) '\(item)'")
    }
}
