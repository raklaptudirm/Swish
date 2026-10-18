@_spi(Layer) import Swiit
import SwishShellLibrary
import Foundation

// What a command and a pipeline are in Swift: the prelude's `Command` and
// `Pipeline` (Library+Shell.swift), built by hand or by the rewrite of the
// shell's constructs (Docs/Design/desugaring.md).
//
//     Command("ls", "-la", Glob("*.swift")).writing(1, to: "out").run()
//     Pipeline(from: xs, Command("sorted"), Command("prefix", "3")).output()
//
// Here is how they run: through the same machinery as a command typed at the
// prompt.

/// What the checker decided about a stage, as the rewritten program says it
/// (`StageHint` in Library+Shell.swift): written as a call by the rewrite, and
/// read back when the command runs.
struct StageHint {
    var resolution: StageResolution?
    var overload: Int?
    var notAnExpression: String?

    var isEmpty: Bool { resolution == nil && overload == nil && notAnExpression == nil }

    /// The arguments of the `StageHint(…)` that says it.
    var arguments: [SwiftArgument] {
        func text(_ label: String, _ value: String) -> SwiftArgument { SwiftArgument(label: label, value: .text(value)) }
        var arguments: [SwiftArgument] = []
        switch resolution {
        case .sequenceMethod?: arguments.append(text("method", "sequence"))
        case .itemMethod?: arguments.append(text("method", "item"))
        case .bridged(let type, let receiver, let bindings)?:
            arguments += [text("method", "bridged"), text("type", type), text("receiver", "\(receiver)")]
            if !bindings.isEmpty {
                arguments.append(SwiftArgument(label: "bindings", value: .record(bindings.sorted { $0.key < $1.key }.map {
                    (key: $0.key, value: SwiftExpression.text($0.value.description))
                })))
            }
        case nil: break
        }
        if let overload { arguments.append(SwiftArgument(label: "overload", value: .integer(overload))) }
        if let notAnExpression { arguments.append(text("notAnExpression", notAnExpression)) }
        return arguments
    }

    init(resolution: StageResolution? = nil, overload: Int? = nil, notAnExpression: String? = nil) {
        self.resolution = resolution
        self.overload = overload
        self.notAnExpression = notAnExpression
    }

    /// A `StageHint` value read back.
    init?(_ value: Value, interpreter: Interpreter) {
        guard case .record(let record) = value, record.typeName == "StageHint" else { return nil }
        func string(_ key: String) -> String? {
            if case .string(let text)? = record[key], !text.isEmpty { text } else { nil }
        }
        switch string("method") {
        case "sequence"?: resolution = .sequenceMethod
        case "item"?: resolution = .itemMethod
        case "bridged"?:
            guard let type = string("type"), let receiver = StageReceiver(string("receiver")) else { return nil }
            var bindings: [String: ValueType] = [:]
            if case .dictionary(let written)? = record["bindings"] {
                for (key, value) in written.dictionary { bindings[key.description] = StageHint.type(spelled: value.description, interpreter) }
            }
            resolution = .bridged(type: type, receiver: receiver, bindings: bindings)
        default: break
        }
        if case .int(let number)? = record["overload"], number >= 0 { overload = number }
        notAnExpression = string("notAnExpression")
    }

    /// A type as it is written: read by the front end, as `x as! T` says it.
    static func type(spelled text: String, _ interpreter: Interpreter) -> ValueType {
        if case .success(let program) = interpreter.parse("0 as! \(text)"),
           case .expression(.cast(_, let type, _))? = program.statements.first { return ValueType(type) }
        return .unknown
    }
}

extension StageReceiver {
    init?(_ text: String?) {
        switch text {
        case "collected"?: self = .collected
        case "each"?: self = .each
        case "flow"?: self = .flow
        case "value"?: self = .value
        default: return nil
        }
    }
}

extension Shell {
    /// The Swift bodies of `Command`'s and `Pipeline`'s methods that run them.
    var commandMethods: [String: (body: FunctionBody, input: Parameter?)] {
        let methods: [String: ([Value], Value?) throws -> Value] = [
            // As a statement: its output goes where the shell's does.
            "run": { [unowned self] in statusValue(try run($0, from: $1, display: true)) },
            // In a chain or a condition: a function used as a command shows nothing.
            "runQuietly": { [unowned self] in statusValue(try run($0, from: $1, display: false)) },
            "check": { [unowned self] in try check($0, from: $1) },
            "output": { [unowned self] in .output(try output($0, from: $1)) },
            "start": { [unowned self] in .object(try startJob(try stages($0, from: $1), source: source($0, from: $1), capture: false)) },
            "startCapturing": { [unowned self] in
                .object(try startJob(try stages($0, from: $1), source: source($0, from: $1), capture: true))
            },
        ]
        var bodies: [String: (body: FunctionBody, input: Parameter?)] = [:]
        for (name, method) in methods {
            // A command alone, or a pipeline's commands and what it is fed.
            bodies["Command." + name] = (.native { _, arguments in try method([arguments["self"] ?? .nothing], nil) }, nil)
            bodies["Pipeline." + name] = (.native { _, arguments in
                guard case .record(let pipeline)? = arguments["self"], case .list(let commands)? = pipeline["commands"] else {
                    throw RuntimeError("not a Pipeline")
                }
                return try method(commands, pipeline["input"].flatMap { $0 == .nothing ? nil : $0 })
            }, nil)
        }
        return bodies
    }

    /// `capture { … }`: the block, run with its output gathered.
    var captureBody: FunctionBody {
        .native { [unowned self] interpreter, arguments in
            guard case .function(let body as Function)? = arguments["body"], case .swiit(let program) = body.body else {
                throw RuntimeError("capture needs a block")
            }
            // What runs in it leaves the status it ends with.
            let before = lastStatus
            lastStatus = 0
            // Its statements run as statements, which say how they went.
            let text = try capturing { try interpreter.runBlock(program) }
            let status = lastStatus
            lastStatus = before
            let output = output(text, status: status)
            // Without `try`, failing is just what `.status` says.
            if arguments["throwing"] == .bool(true) && status != 0 {
                throw RuntimeError.commandFailure("$(…) failed with status \(status)", status: status, output: output)
            }
            return .output(output)
        }
    }

    func run(_ commands: [Value], from input: Value?, display: Bool) throws -> Int32 {
        try runPipeline(try stages(commands, from: input), source: source(commands, from: input), display: display)
    }

    /// As `try make`: failing throws a `CommandFailure`.
    func check(_ commands: [Value], from input: Value?) throws -> Value {
        let status = try run(commands, from: input, display: true)
        if status != 0 {
            let (code, signal) = interpreter.exitCode(status)
            throw RuntimeError.commandFailure("\(source(commands, from: input)) failed with status \(status)", status: status,
                                              output: Output(text: "", code: code, signal: signal))
        }
        return statusValue(status)
    }

    /// As `$(…)`: its output is gathered, whatever its status.
    func output(_ commands: [Value], from input: Value?) throws -> Output {
        var status: Int32 = 0
        let text = try capturing { status = try run(commands, from: input, display: false) }
        return output(text, status: status)
    }

    /// The Output of a command's text and status, as `$(…)` gives it.
    func output(_ text: String, status: Int32) -> Output {
        var text = text
        while text.last == "\n" { text.removeLast() }
        let (code, signal) = interpreter.exitCode(status)
        return Output(text: text, code: code, signal: signal)
    }

    /// The exit status a value gives: a Bool's truth, a `Status` or an
    /// `Output` how its command ended; anything else succeeded.
    func status(of value: Value) -> Int32 {
        if case .bool(let truth) = value { return truth ? 0 : 1 }
        if case .record(let record) = value, record.typeName == "Status", case .bool(let succeeded)? = record["succeeded"] {
            if succeeded { return 0 }
            if case .int(let code)? = record["code"] { return Int32(code) }
            if case .int(let signal)? = record["signal"] { return 128 + Int32(signal) }
            return 1
        }
        // `await build && echo ok`: an Output's status is its command's.
        if let output = value.commandOutput, !output.succeeded {
            return output.code.map(Int32.init) ?? 128 + Int32(output.signal ?? 0)
        }
        return 0
    }

    /// Keeps the exit status as statements run: an expression statement's
    /// value says it (`false` fails, a command's `Status` is how it ended),
    /// a per-item error reported makes it a failure, and anything else, as a
    /// `let`, succeeds. An `if` or a loop is what ran in it last.
    func recordStatuses() {
        interpreter.statementFinished = { [unowned self] statement, value, itemErrors in
            var status = value.map(status(of:)) ?? 0
            // A `try?` that caught an error failed; other nils, like a
            // function that returns nothing, didn't.
            if value == .nothing, case .expression(.attempt(_, .optional)) = statement { status = 1 }
            lastStatus = itemErrors && status == 0 ? 1 : status
        }
    }

    /// A command statement's value: how it ended.
    func statusValue(_ status: Int32) -> Value {
        let (code, signal) = interpreter.exitCode(status)
        return .record(Record([
            "code": code.map(Value.int) ?? .nothing,
            "signal": signal.map(Value.int) ?? .nothing,
            "succeeded": .bool(status == 0),
        ], typeName: "Status"))
    }

    func stages(_ commands: [Value], from input: Value?) throws -> [Stage] {
        try stages(input: input, commands: try commands.map(spec))
    }

    /// The commands as a person would type them, for messages and `jobs`.
    func source(_ commands: [Value], from input: Value?) -> String {
        let typed = commands.map { command -> String in
            guard case .record(let record) = command, case .list(let words)? = record["words"] else { return command.description }
            return (record["isExternal"] == .bool(true) ? "^" : "") + words.map(Shell.shellWord).joined(separator: " ")
        }
        return ((input.map { [$0.debugDescription] } ?? []) + typed).joined(separator: " | ")
    }

    /// A word as a shell would show it: quoted when it has spaces or quotes.
    private static func shellWord(_ value: Value) -> String {
        if case .record(let record) = value, record.typeName == "Glob", case .string(let pattern)? = record["pattern"] {
            return Glob.unescape(pattern)
        }
        guard case .string(let text) = value else { return value.description }
        guard !text.isEmpty, !text.contains(where: { " \t\n'\"\\$|&;<>(){}".contains($0) }) else {
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return text
    }

    /// A `Command` as it runs: its words expanded, its redirects resolved.
    func spec(_ command: Value) throws -> CommandSpec {
        guard case .record(let record) = command, case .list(let words)? = record["words"] else {
            throw RuntimeError("\(command.typeName) isn't a Command")
        }
        var spec = CommandSpec(arguments: try words.flatMap(arguments))
        spec.external = record["isExternal"] == .bool(true)
        if case .list(let redirections)? = record["redirections"] {
            spec.redirects = try redirections.map(redirect)
        }
        if case .dictionary(let variables)? = record["variables"] {
            spec.environment = variables.dictionary.map { ($0.key.description, $0.value.description) }.sorted { $0.0 < $1.0 }
        }
        // `(by: "size")`: the tuple's elements, as arguments; a position is no label.
        if case .record(let tuple)? = record["arguments"] {
            spec.call = tuple.keys.map { key in
                Argument(label: Int(key) == nil ? key : nil, value: .literal(tuple[key] ?? .nothing))
            }
        }
        if let value = record["hint"], let hint = StageHint(value, interpreter: interpreter) {
            spec.resolution = hint.resolution
            spec.overload = hint.overload
            spec.notAnExpression = hint.notAnExpression
        }
        return spec
    }

    private func redirect(_ value: Value) throws -> ResolvedRedirect {
        guard case .record(let record) = value, case .int(let fd)? = record["fd"], case .string(let mode)? = record["mode"] else {
            throw RuntimeError("\(value.typeName) isn't a Redirection")
        }
        let modes: [String: Redirect.Mode] = ["read": .read, "write": .write, "append": .append]
        guard let open = modes[mode] else {
            guard mode == "send", case .int(let other)? = record["other"] else { throw RuntimeError("no redirection '\(mode)'") }
            return ResolvedRedirect(fd: Int32(fd), action: .duplicate(Int32(other)))
        }
        let paths = try arguments(record["path"] ?? .nothing)
        guard paths.count == 1, case .text(let path) = paths[0] else {
            throw RuntimeError("ambiguous redirect: \(paths.count) files match")
        }
        return ResolvedRedirect(fd: Int32(fd), action: .open(path, open))
    }

    /// The arguments a word gives: a String is itself, a `Glob` the paths it
    /// matches, a `Spread` its items, a closure itself.
    func arguments(_ word: Value) throws -> [CommandArgument] {
        switch word {
        case .string(let text):
            return [.text(text)]
        case .function:
            return [.value(word)]
        case .record(let record) where record.typeName == "Glob":
            guard case .string(let pattern)? = record["pattern"] else { return [] }
            return try interpreter.expand(pattern).map(CommandArgument.text)
        case .record(let record) where record.typeName == "Spread":
            guard case .list(let items)? = record["value"] else { return [.text(record["value"]?.description ?? "")] }
            return items.map { .text($0.description) }
        default:
            return [.text(word.description)]
        }
    }
}
