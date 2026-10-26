import Swiit

/// The types the prelude declares, which Swift code builds values of and tells values apart by.
/// Asked of the interpreter once, after the prelude loads: a name the prelude no longer declares
/// stops the shell at startup, not at a use.
struct PreludeTypes {
    let status, commandFailure, fileEntry, processEntry, member, help, json: Symbol.ID
    let glob, spread, jobState, wrapping: Symbol.ID

    init(_ interpreter: Interpreter) {
        func declared(_ name: String) -> Symbol.ID {
            guard let id = interpreter.typeID(named: name) else {
                preconditionFailure("the shell's prelude declares no \(name)")
            }
            return id
        }
        status = declared("Status")
        commandFailure = declared("CommandFailure")
        fileEntry = declared("FileEntry")
        processEntry = declared("ProcessEntry")
        member = declared("Member")
        help = declared("Help")
        json = declared("JSON")
        glob = declared("Glob")
        spread = declared("Spread")
        jobState = declared("JobState")
        wrapping = declared("Wrapping")
    }
}

extension Shell {
    /// A value of a type the prelude declares, made by its initializer, with its fields by name.
    func make(_ type: Symbol.ID, _ fields: KeyValuePairs<String, Value>) -> Value {
        do {
            return try interpreter.make(type, arguments: fields.map { ($0.key, $0.value) })
        } catch {
            preconditionFailure("the shell's \(type): \(error)")
        }
    }

    /// The prelude's `JSON` holding `value`.
    func jsonWrap(_ value: Value) -> Value { make(preludeTypes.json, ["raw": value]) }

    /// As `jsonWrap`, and nil for nothing, as a field that is not there.
    func jsonWrapping(_ value: Value?) -> Value {
        guard let value, value.kind != .nothing else { return .nothing }
        return jsonWrap(value)
    }
}
