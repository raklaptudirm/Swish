import Swiit
import Synchronization

/// The types the prelude declares, which Swift code builds values of and tells values apart by.
/// Asked of the interpreter once, after the prelude loads: a name the prelude no longer declares
/// stops the shell at startup, not at a use.
struct PreludeTypes {
    let interpreter: Interpreter
    let status, commandFailure, member, memberKind, help, json: Symbol.ID
    let glob, spread, wrapping, stream: Symbol.ID

    init(_ interpreter: Interpreter) {
        self.interpreter = interpreter
        func declared(_ name: String) -> Symbol.ID {
            guard let id = Symbol.ID(named: name, in: interpreter) else {
                preconditionFailure("the shell's prelude declares no \(name)")
            }
            return id
        }
        status = declared("Status")
        commandFailure = declared("CommandFailure")
        member = declared("Member")
        memberKind = declared("MemberKind")
        help = declared("Help")
        json = declared("JSON")
        glob = declared("Glob")
        spread = declared("Spread")
        wrapping = declared("Wrapping")
        stream = declared("ThrowingStream")
    }
}

extension PreludeTypes {
    /// A value of a type the prelude declares, made by its initializer, with its fields by name.
    func make(_ type: Symbol.ID, _ fields: KeyValuePairs<String, Value>) -> Value {
        do {
            return try interpreter.make(type, arguments: fields.map { ($0.key, $0.value) })
        } catch {
            preconditionFailure("the shell's \(type): \(error)")
        }
    }

    /// The type of the items as they come.
    var streamType: ScriptType { .named(stream, [.any]) }

    /// A stream that gives what `read` does, one item at a time, until it gives nil.
    func stream(_ source: @escaping () throws -> Value?) -> Value {
        nonisolated(unsafe) let read = source  // safe: a stream is read by one stage at a time
        let function = Value(
            HostSymbol.function(
                name: "read",
                returns: .named(.optional, [.any]),
                isThrowing: true
            ) { _ in try read().map { Value([$0]) } ?? .nothing }
        )
        return make(stream, ["read": function, "source": Value(StreamSource(read))])
    }

    /// A stream of `items`.
    func stream(of items: [Value]) -> Value {
        let position = Mutex(0)
        return stream {
            position.withLock { index in
                defer { index += 1 }
                return index < items.count ? items[index] : nil
            }
        }
    }

    /// What a value gives one at a time: a prelude stream's, or any sequence a script holds (a
    /// list, a set, a range, a command's output); nil for a value that isn't a sequence.
    func reader(of value: Value) -> (() throws -> Value?)? {
        if value.isInstance(of: stream) {
            if let held = try? interpreter.value(forMember: "source", of: value),
                let source = held.casting(to: StreamSource.self)
            {
                return source.read
            }
            guard let read = try? interpreter.value(forMember: "read", of: value) else {
                return nil
            }
            let interpreter = interpreter
            return {
                // The item is in a list of one: nil as an item is not the end.
                let item = try interpreter.call(read, with: [])
                return item.casting(to: [Value].self)?.first
            }
        }
        guard let items = try? AnySequence<Value>(value) else { return nil }
        var iterator = items.makeIterator()
        return { iterator.next() }
    }

    /// The prelude's `JSON` holding `value`.
    func jsonWrap(_ value: Value) -> Value { make(json, ["raw": value]) }

    /// As `jsonWrap`, and nil for nothing, as a field that is not there.
    func jsonWrapping(_ value: Value?) -> Value {
        guard let value, value.kind != .nothing else { return .nothing }
        return jsonWrap(value)
    }
}

// safe: read by one stage at a time
/// What the shell's own streams read with: held by the stream, so a stage reads it without a call.
final class StreamSource: @unchecked Sendable, BridgedType {
    let read: () throws -> Value?
    init(_ read: @escaping () throws -> Value?) { self.read = read }
}
