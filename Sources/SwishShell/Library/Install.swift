import Foundation
import Swiit
import SystemPackage

// What the shell adds to the language, told to the interpreter through its public interface: Swift types it holds as they
// are (a size, a column, a command's output), and the declarations of its own functions and types, whose bodies are in Swift.

extension Shell {
    /// Teaches the interpreter the shell's own: `ls`, `ps`, `pwd`, `from`, `to`, `help`, and the types they use.
    func installLibrary() {
        interpreter.register(FileSize.native)
        interpreter.register(Date.native)
        interpreter.register(DisplayColumn.native)
        interpreter.register(Output.native)
        do {
            try interpreter.prelude(Shell.prelude, bodies: preludeBodies)
        } catch {
            preconditionFailure("the shell's declarations: \(error)")
        }
    }

    /// The Swift bodies of the declarations, by name.
    private var preludeBodies: [String: @Sendable ([String: Value]) throws -> Value] {
        var bodies = commandMethods
        func add(_ name: String, _ body: @escaping @Sendable ([String: Value]) throws -> Value) { bodies[name] = body }

        add("from") { arguments in
            guard let text = arguments["text"]?.cast(to: [String].self) else { return .null }
            switch try InputFormat(arguments["format"] ?? .null) {
            case .json: return try JSON(try JSON.parse(text.joined(separator: "\n"))).value
            }
        }
        add("to") { [unowned self] arguments in
            let items = arguments["items"]?.cast(to: [Value].self) ?? []
            switch try OutputFormat(arguments["format"] ?? .null) {
            case .json: return Value(try JSON.text(items.count == 1 ? items[0] : Value(items)))
            case .text: return Value(laidOut(items, useViews: true).joined(separator: "\n"))
            }
        }
        add("table") { [unowned self] arguments in
            Value(laidOut(arguments["items"]?.cast(to: [Value].self) ?? [], useViews: false).map { Value($0) })
        }
        add("list") { [unowned self] arguments in
            var lines: [String] = []
            for item in arguments["items"]?.cast(to: [Value].self) ?? [] {
                if !lines.isEmpty { lines.append("") }
                if let record = item.fields {
                    lines += DisplayFormatter.keyValueLines(record, registry: displayRegistry)
                } else {
                    lines.append(item.description)
                }
            }
            return Value(lines.map { Value($0) })
        }
        add("pwd") { _ in Value(boxing: pwd(), as: "FilePath") }
        add("with") { [unowned self] arguments in
            var variables: [String: String] = [:]
            for (key, value) in arguments["variables"]?.entries ?? ValueDictionary() { variables[key.description] = value.description }
            guard let body = arguments["body"] else { return .null }
            return try with(env: variables) { try callBlock(body) }
        }
        add("ls") { [unowned self] arguments in
            let paths = try (arguments["paths"]?.cast(to: [Value].self) ?? []).map { try $0.unboxed(FilePath.self) }
            let partial = ls(paths, all: arguments["all"]?.cast(to: Bool.self) ?? false)
            for error in partial.errors { reportItemError("ls: \(error)") }
            return Value(partial.value.map { $0.value(in: interpreter) })
        }
        add("ps") { [unowned self] _ in Value(ps().map { $0.value(in: interpreter) }) }
        add("history") { [unowned self] _ in Value(historyEntries.map { Value($0) }) }
        add("readLine") { arguments in
            readLine(strippingNewline: arguments["strippingNewline"]?.cast(to: Bool.self) ?? true).map { Value($0) } ?? .null
        }
        add("shellStyled") { [unowned self] arguments in
            let text = arguments["text"]?.description ?? ""
            let styles = try (arguments["styles"]?.cast(to: [Value].self) ?? []).map { try TextStyle($0) }
            guard !styles.isEmpty, !text.isEmpty, interpreter.host.output.traits().styled else { return Value(text) }
            return Value("\u{1B}[\(styles.map(\.rawValue).joined(separator: ";"))m" + text + "\u{1B}[0m")
        }
        add("help") { [unowned self] arguments in try helpBody(arguments) }
        add("members") { [unowned self] arguments in try membersBody(arguments) }
        add("Sequence.select") { arguments in
            var selected: [Value] = []
            let fields = arguments["fields"]?.cast(to: [String].self) ?? []
            for item in arguments["self"]?.cast(to: [Value].self) ?? [] {
                guard let record = item.fields else { throw RuntimeError("select: \(item.description) has no fields") }
                selected.append(Value(struct: nil, fields: fields.map { ($0, record[$0] ?? Value.null) }))
            }
            return Value(selected)
        }
        add("capture") { [unowned self] arguments in try captureBody(arguments) }
        add("captureThrowing") { [unowned self] arguments in try captureThrowingBody(arguments) }
        add("startTask") { [unowned self] arguments in
            guard let source = arguments["source"]?.cast(to: String.self), let body = arguments["body"] else { return .null }
            return Value(try startTask(source: source) { try self.callBlock(body) })
        }
        add("displayItems") { [unowned self] arguments in
            try displayItems(arguments["value"] ?? .null)
            return .null
        }
        add("exitStatus") { [unowned self] arguments in statusValue(status(of: arguments["value"] ?? .null)) }
        add("exitShell") { [unowned self] arguments in
            _ = try run([arguments["command"] ?? .null], from: nil, display: true)
            throw RuntimeError("exit did not leave")
        }
        add("shellText") { [unowned self] arguments in Value(try interpreter.text(of: arguments["value"] ?? .null)) }
        add("escapingWildcards") { arguments in Value(Glob.escape(arguments["text"]?.description ?? "")) }
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

// MARK: Making values

extension FileEntry {
    /// The struct `ls` gives for it.
    func value(in interpreter: Interpreter) -> Value {
        Value(struct: "FileEntry", fields: [
            "name": Value(name), "type": interpreter.value(ofCase: "\(type)", in: "FileType") ?? .null,
            "size": size.value, "modified": Value(boxing: modified, as: "Date"), "permissions": Value(permissions),
            "owner": Value(owner), "created": Value(boxing: created, as: "Date"), "accessed": Value(boxing: accessed, as: "Date"),
            "path": Value(boxing: path, as: "FilePath"), "target": target.map { Value(boxing: $0, as: "FilePath") } ?? .null,
        ])
    }
}

extension ProcessEntry {
    /// The struct `ps` gives for it.
    func value(in interpreter: Interpreter) -> Value {
        Value(struct: "ProcessEntry", fields: [
            "pid": Value(pid), "ppid": Value(ppid), "name": Value(name), "user": Value(user),
            "memory": memory.map { $0.value } ?? .null, "cpuTime": cpuTime.map { Value($0) } ?? .null,
            "threads": threads.map { Value($0) } ?? .null,
        ])
    }
}

extension InputFormat {
    init(_ value: Value) throws {
        guard let found = Self.allCases.first(where: { "\($0)" == value.enumCase?.name }) else { throw LibraryError("expected an InputFormat") }
        self = found
    }
}

extension OutputFormat {
    init(_ value: Value) throws {
        guard let found = Self.allCases.first(where: { "\($0)" == value.enumCase?.name }) else { throw LibraryError("expected an OutputFormat") }
        self = found
    }
}

extension TextStyle {
    init(_ value: Value) throws {
        guard let found = Self.allCases.first(where: { "\($0)" == value.enumCase?.name }) else { throw LibraryError("expected a TextStyle") }
        self = found
    }
}
