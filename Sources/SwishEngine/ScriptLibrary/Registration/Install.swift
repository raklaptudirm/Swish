import Foundation
import Swiit
import SystemPackage

// What the shell adds to the language, told to the interpreter through its public interface: Swift
// types it holds as they are (a size, a column, a command's output), and the declarations of its
// own functions and types, whose bodies are in Swift.

extension Shell {
    /// Teaches the interpreter the shell's own: `ls`, `ps`, `pwd`, `from`, `to`, `help`, and the
    /// types they use.
    func installLibrary() {
        for type in FileSizeBridge.types { interpreter.register(type) }
        interpreter.register(Date.native)
        interpreter.register(DisplayColumn.native)

        // What `ls` and `ps` give, with the enums their fields are (`FileType`).
        interpreter.register(FileEntry.native)
        interpreter.register(ProcessEntry.native)

        // The enums the declarations below name, which nothing registered gives.
        interpreter.register(InputFormat.self)
        interpreter.register(OutputFormat.self)
        interpreter.register(TextStyle.self)
        interpreter.register(JobState.self)

        // `output.status` is a struct of the prelude's `Status`, which the Swift type cannot name
        // (host types are process-wide, and the prelude's are each interpreter's), so it is one
        // by name: a value of the Swift type `Status`, which stands for the prelude's.
        interpreter.register(
            Output.native.member(
                .property(
                    "status",
                    summary: "How the command exited.",
                    type: .named(Symbol.ID(hostType: "Status"))
                ) { receiver in
                    guard let output = receiver.casting(to: Output.self) else {
                        throw LibraryError("expected an Output, not \(receiver)")
                    }
                    return output.statusFields
                }
            )
        )

        do {
            try interpreter.declare(Shell.prelude, bodies: preludeBodies)
        } catch {
            preconditionFailure("the shell's declarations: \(error)")
        }

        preludeTypes = PreludeTypes(interpreter)
        runner.preludeTypes = preludeTypes
    }

    /// The Swift bodies of the declarations, by name.
    private var preludeBodies: [String: @Sendable ([String: Value]) throws -> Value] {
        var bodies = runner.commandMethods.merging(runner.jobBodies) { _, new in new }
        func add(_ name: String, _ body: @escaping @Sendable ([String: Value]) throws -> Value) {
            bodies[name] = body
        }

        // The stream's operators that run for every item.
        func streamOperator(
            _ name: String,
            _ parameter: String,
            _ make:
                @escaping @Sendable (
                    _ interpreter: Interpreter, _ source: @escaping () throws -> Value?,
                    _ body: Value,
                    _ arguments: [String: Value]
                ) -> () throws -> Value?
        ) {
            add("ThrowingStream.\(name)") { [unowned self] arguments in
                guard let receiver = arguments["self"],
                    let source = preludeTypes.reader(of: receiver),
                    let body = arguments[parameter]
                else { return .nothing }
                return preludeTypes.stream(make(interpreter, source, body, arguments))
            }
        }
        streamOperator("filter", "isIncluded") { interpreter, source, test, _ in
            {
                while let item = try source() {
                    if try interpreter.call(test, with: [item]).casting(to: Bool.self) == true {
                        return item
                    }
                }
                return nil
            }
        }
        streamOperator("map", "transform") { interpreter, source, transform, _ in
            { try source().map { try interpreter.call(transform, with: [$0]) } }
        }
        streamOperator("compactMap", "transform") { interpreter, source, transform, _ in
            {
                while let item = try source() {
                    let mapped = try interpreter.call(transform, with: [item])
                    if mapped.kind != .nothing { return mapped }
                }
                return nil
            }
        }
        add("ThrowingStream.prefix") { [unowned self] arguments in
            guard let receiver = arguments["self"], let source = preludeTypes.reader(of: receiver)
            else {
                return .nothing
            }
            let limit = arguments["maxLength"]?.casting(to: Int.self) ?? 1
            nonisolated(unsafe) var taken = 0
            return preludeTypes.stream {
                guard taken < limit else { return nil }
                taken += 1
                return try source()
            }
        }

        add("from") { [unowned self] arguments in
            guard let text = arguments["text"]?.casting(to: [String].self) else { return .nothing }
            switch try InputFormat(arguments["format"] ?? .nothing) {
            case .json: return preludeTypes.jsonWrap(try JSON.parse(text.joined(separator: "\n")))
            }
        }
        add("to") { [unowned self] arguments in
            let items = arguments["items"]?.casting(to: [Value].self) ?? []
            switch try OutputFormat(arguments["format"] ?? .nothing) {
            case .json:
                let interpreter = interpreter
                return Value(
                    try JSON.text(
                        items.count == 1 ? items[0] : Value(items),
                        rawValue: { value in
                            guard let id = value.typeID,
                                ScriptType.named(id)
                                    .conforms(to: .rawRepresentable, in: interpreter)
                            else { return nil }
                            return try? interpreter.value(forMember: "rawValue", of: value)
                        }
                    )
                )
            case .text: return Value(laidOut(items, useViews: true).joined(separator: "\n"))
            }
        }
        add("table") { [unowned self] arguments in
            Value(
                laidOut(arguments["items"]?.casting(to: [Value].self) ?? [], useViews: false)
                    .map { Value($0) }
            )
        }
        add("list") { [unowned self] arguments in
            var lines: [String] = []
            for item in arguments["items"]?.casting(to: [Value].self) ?? [] {
                if !lines.isEmpty { lines.append("") }
                if let record = item.fields {
                    lines += DisplayFormatter.keyValueLines(record, registry: displayRegistry)
                } else {
                    lines.append(item.description)
                }
            }
            return Value(lines.map { Value($0) })
        }
        add("pwd") { _ in Value(pwd()) }
        add("with") { [unowned self] arguments in
            var variables: [String: String] = [:]
            for (key, value) in arguments["variables"]?.entries ?? [] {
                variables[key.description] = value.description
            }
            guard let body = arguments["body"] else { return .nothing }
            return try with(env: variables) { try runner.callBlock(body) }
        }
        add("ls") { [unowned self] arguments in
            let paths = try (arguments["paths"]?.casting(to: [Value].self) ?? [])
                .map { try FilePath($0) }
            let partial = ls(paths, all: arguments["all"]?.casting(to: Bool.self) ?? false)
            for error in partial.errors { reportItemError("ls: \(error)") }
            return Value(partial.value.map(\.value))
        }
        add("ps") { _ in Value(ps().map(\.value)) }
        add("readLine") { arguments in
            readLine(
                strippingNewline: arguments["strippingNewline"]?.casting(to: Bool.self) ?? true
            )
            .map { Value($0) }
                ?? .nothing
        }
        add("shellStyled") { [unowned self] arguments in
            let text = arguments["text"]?.description ?? ""
            let styles = try (arguments["styles"]?.casting(to: [Value].self) ?? [])
                .map { try TextStyle($0) }
            guard !styles.isEmpty, !text.isEmpty, interpreter.host.output.traits().isStyled else {
                return Value(text)
            }
            return Value(
                "\u{1B}[\(styles.map(\.rawValue).joined(separator: ";"))m" + text + "\u{1B}[0m"
            )
        }
        add("help") { [unowned self] arguments in try helpBody(arguments) }
        add("members") { [unowned self] arguments in try membersBody(arguments) }
        add("capture") { [unowned self] arguments in try runner.captureBody(arguments) }
        add("captureThrowing") { [unowned self] arguments in
            try runner.captureThrowingBody(arguments)
        }
        add("startTask") { [unowned self] arguments in
            guard let source = arguments["source"]?.casting(to: String.self),
                let body = arguments["body"]
            else {
                return .nothing
            }
            return Value(try runner.startTask(source: source) { try self.runner.callBlock(body) })
        }
        add("displayItems") { [unowned self] arguments in
            try runner.displayItems(arguments["value"] ?? .nothing)
            return .nothing
        }
        add("exitStatus") { [unowned self] arguments in
            runner.statusValue(runner.status(of: arguments["value"] ?? .nothing))
        }
        add("exitShell") { [unowned self] arguments in
            _ = try runner.runCommands([arguments["command"] ?? .nothing], from: nil, display: true)
            throw RuntimeError("exit did not leave")
        }
        add("shellText") { [unowned self] arguments in
            Value(try interpreter.description(of: arguments["value"] ?? .nothing))
        }
        add("escapingWildcards") { arguments in
            Value(Glob.escape(arguments["text"]?.description ?? ""))
        }
        add("environmentValue") { [unowned self] arguments in
            runner.environment.get(arguments["name"]?.description ?? "").map { Value($0) }
                ?? .nothing
        }
        add("setEnvironmentValue") { [unowned self] arguments in
            let name = arguments["name"]?.description ?? ""
            guard !name.isEmpty, !name.contains("=") else {
                throw RuntimeError(
                    "an environment variable's name must be a String without '=', not \(name)"
                )
            }
            let value = arguments["value"] ?? .nothing
            runner.environment.set(name, value.kind == .nothing ? nil : value.description)
            return .nothing
        }
        add("loadEnvironment") { [unowned self] arguments in
            guard let script = arguments["script"]?.casting(to: String.self) else {
                throw LibraryError("the script to run must be a String")
            }
            try loadEnvironment(fromShell: script)
            return .nothing
        }
        for (name, body) in jsonBodies { add(name, body) }
        return bodies
    }

    /// The lines the display step would show for `items`.
    private func laidOut(_ items: [Value], useViews: Bool) -> [String] {
        var lines: [String] = []
        let formatter = DisplayFormatter(useViews: useViews, registry: displayRegistry) { text in
            lines.append(String(text.dropLast()))
            return true
        }
        for item in items { formatter.add(item) }
        formatter.finish()
        return lines
    }
}
