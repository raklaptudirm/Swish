import Swiit
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

extension Shell {
    /// The Swift bodies of `Command`'s and `Pipeline`'s methods that run them, by the names the prelude gives them.
    var commandMethods: [String: @Sendable ([String: Value]) throws -> Value] {
        let methods: [String: ([Value], Value?) throws -> Value] = [
            // As a statement: its output goes where the shell's does.
            "run": { [unowned self] in statusValue(try run($0, from: $1, display: true)) },
            // In a chain or a condition: a function used as a command shows nothing.
            "runQuietly": { [unowned self] in statusValue(try run($0, from: $1, display: false)) },
            "check": { [unowned self] in try check($0, from: $1) },
            "output": { [unowned self] in .output(try output($0, from: $1)) },
            "start": { [unowned self] in Value(try startJob(try stages($0, from: $1), source: source($0, from: $1), capture: false)) },
            "startCapturing": { [unowned self] in
                Value(try startJob(try stages($0, from: $1), source: source($0, from: $1), capture: true))
            },
        ]
        var bodies: [String: @Sendable ([String: Value]) throws -> Value] = [:]
        for (name, method) in methods {
            nonisolated(unsafe) let method = method
            // A command alone, or a pipeline's commands and what it is fed.
            bodies["Command." + name] = { arguments in try method([arguments["self"] ?? .null], nil) }
            bodies["Pipeline." + name] = { arguments in
                guard let pipeline = arguments["self"], let commands = pipeline.field("commands")?.cast(to: [Value].self) else {
                    throw RuntimeError("not a Pipeline")
                }
                return try method(commands, pipeline.field("input").flatMap { $0.kind == .nothing ? nil : $0 })
            }
        }
        return bodies
    }

    /// `captureThrowing { … }`: as `capture(throwing: true)`.
    func captureThrowingBody(_ arguments: [String: Value]) throws -> Value {
        var arguments = arguments
        arguments["throwing"] = Value(true)
        return try captureBody(arguments)
    }

    /// `capture { … }`: the block, run with its output gathered.
    func captureBody(_ arguments: [String: Value]) throws -> Value {
        guard let body = arguments["body"], body.kind == .function else { throw RuntimeError("capture needs a block") }
        // What runs in it leaves the status it ends with.
        let before = lastStatus
        lastStatus = 0
        // Its statements run as statements, which say how they went.
        let text = try capturing {
            let result = try self.callBlock(body)
            // A block of one expression gives its value rather than running a statement, so says its status here.
            if result.kind != .nothing { self.lastStatus = self.status(of: result) }
        }
        let status = lastStatus
        lastStatus = before
        let output = output(text, status: status)
        // Without `try`, failing is just what `.status` says.
        if arguments["throwing"]?.cast(to: Bool.self) == true && status != 0 {
            throw RuntimeError.commandFailure("$(…) failed with status \(status)", status: status, output: output)
        }
        return .output(output)
    }

    /// Runs a closure the language gave, as a block.
    func callBlock(_ closure: Value) throws -> Value {
        do {
            return try interpreter.call(closure, with: [])
        } catch let error as Diagnostic {
            throw ScriptError(error.message, status: error.status, isReported: error.isReported)
        }
    }

    func run(_ commands: [Value], from input: Value?, display: Bool) throws -> Int32 {
        try runPipeline(try stages(commands, from: input), source: source(commands, from: input), display: display)
    }

    /// As `try make`: failing throws a `CommandFailure`.
    func check(_ commands: [Value], from input: Value?) throws -> Value {
        let status = try run(commands, from: input, display: true)
        if status != 0 {
            let (code, signal) = exitCode(status)
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
        let (code, signal) = exitCode(status)
        return Output(text: text, code: code, signal: signal)
    }

    /// The exit status a value gives: a Bool's truth, a `Status` or an
    /// `Output` how its command ended; anything else succeeded.
    func status(of value: Value) -> Int32 {
        if let truth = value.cast(to: Bool.self) { return truth ? 0 : 1 }
        if value.kind == .structure, value.typeName == "Status", let succeeded = value.field("succeeded")?.cast(to: Bool.self) {
            if succeeded { return 0 }
            if let code = value.field("code")?.cast(to: Int.self) { return Int32(code) }
            if let signal = value.field("signal")?.cast(to: Int.self) { return 128 + Int32(signal) }
            return 1
        }
        // `await build && echo ok`: an Output's status is its command's.
        if let output = value.commandOutput, !output.succeeded {
            return output.code.map(Int32.init) ?? 128 + Int32(output.signal ?? 0)
        }
        return 0
    }

    /// A command statement's value: how it ended.
    func statusValue(_ status: Int32) -> Value {
        let (code, signal) = exitCode(status)
        return Value(struct: "Status", fields: [
            "code": code.map { Value($0) } ?? Value.null,
            "signal": signal.map { Value($0) } ?? Value.null,
            "succeeded": Value(status == 0),
        ])
    }

    func stages(_ commands: [Value], from input: Value?) throws -> [Stage] {
        try stages(input: input, commands: try commands.map(spec))
    }

    /// The commands as a person would type them, for messages and `jobs`.
    func source(_ commands: [Value], from input: Value?) -> String {
        let typed = commands.map { command -> String in
            guard let words = command.field("words")?.cast(to: [Value].self) else { return command.description }
            return (command.field("isExternal")?.cast(to: Bool.self) == true ? "^" : "") + words.map(Shell.shellWord).joined(separator: " ")
        }
        return ((input.map { [$0.debugDescription] } ?? []) + typed).joined(separator: " | ")
    }

    /// A word as a shell would show it: quoted when it has spaces or quotes.
    private static func shellWord(_ value: Value) -> String {
        if value.kind == .structure, value.typeName == "Glob", let pattern = value.field("pattern")?.cast(to: String.self) {
            return Glob.unescape(pattern)
        }
        guard let text = value.cast(to: String.self) else { return value.description }
        guard !text.isEmpty, !text.contains(where: { " \t\n'\"\\$|&;<>(){}".contains($0) }) else {
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return text
    }

    /// A `Command` as it runs: its words expanded, its redirects resolved.
    func spec(_ command: Value) throws -> CommandSpec {
        guard command.kind == .structure, let words = command.field("words")?.cast(to: [Value].self) else {
            throw RuntimeError("\(command.typeName) isn't a Command")
        }
        var spec = CommandSpec(arguments: try words.flatMap(arguments))
        spec.external = command.field("isExternal")?.cast(to: Bool.self) == true
        if let redirections = command.field("redirections")?.cast(to: [Value].self) {
            spec.redirects = try redirections.map(redirect)
        }
        if let variables = command.field("variables")?.entries {
            spec.environment = variables.map { ($0.key.description, $0.value.description) }.sorted { $0.0 < $1.0 }
        }
        // `(by: "size")`: the tuple's elements, as arguments; a position is no label.
        if let call = command.field("arguments"), call.kind != .nothing {
            if call.kind == .tuple, let tuple = call.fields {
                spec.call = tuple.entries.map { (label: Int($0.key) == nil ? $0.key : nil, value: $0.value) }
            } else {
                // `(x)` is x, not a tuple of one.
                spec.call = [(label: nil, value: call)]
            }
        }
        return spec
    }

    private func redirect(_ value: Value) throws -> ResolvedRedirect {
        guard let fd = value.field("fd")?.cast(to: Int.self), let mode = value.field("mode")?.cast(to: String.self) else {
            throw RuntimeError("\(value.typeName) isn't a Redirection")
        }
        let modes: [String: RedirectMode] = ["read": .read, "write": .write, "append": .append]
        guard let open = modes[mode] else {
            guard mode == "send", let other = value.field("other")?.cast(to: Int.self) else { throw RuntimeError("no redirection '\(mode)'") }
            return ResolvedRedirect(fd: Int32(fd), action: .duplicate(Int32(other)))
        }
        let paths = try arguments(value.field("path") ?? .null)
        guard paths.count == 1, case .text(let path) = paths[0] else {
            throw RuntimeError("ambiguous redirect: \(paths.count) files match")
        }
        return ResolvedRedirect(fd: Int32(fd), action: .open(path, open))
    }

    /// The arguments a word gives: a String is itself, a `Glob` the paths it
    /// matches, a `Spread` its items, a closure itself.
    func arguments(_ word: Value) throws -> [CommandArgument] {
        switch word.kind {
        case .string:
            return [.text(word.description)]
        case .function:
            return [.value(word)]
        case .structure where word.typeName == "Glob":
            guard let pattern = word.field("pattern")?.cast(to: String.self) else { return [] }
            return try expand(pattern).map(CommandArgument.text)
        case .structure where word.typeName == "Spread":
            guard let items = word.field("value")?.cast(to: [Value].self) else { return [.text(word.field("value")?.description ?? "")] }
            return items.map { .text($0.description) }
        default:
            return [.text(word.description)]
        }
    }
}

extension Value {
    /// The field of a struct value, by name.
    func field(_ name: String) -> Value? { entries?[Value(name)] }
}
