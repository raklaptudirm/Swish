@_spi(Shell) import Swiit
import Foundation
import SwishKit

/// `Command("git", "status")`: a program or function with its words, as a value
/// to run by hand: `run()` runs it as a statement would and gives the
/// `Status`, `output()` runs it as `$(…)` would and gives the `Output`. The
/// words are taken as they are: no `~`, `$name` or globs, which is what
/// `Words` will be for. This is what a command statement means in Swift
/// (Docs/Design/desugaring.md).
final class CommandObject: CheckedObject, @unchecked Sendable {
    let words: [String]
    unowned let shell: Shell

    init(words: [String], shell: Shell) {
        self.words = words
        self.shell = shell
    }

    var typeName: String { "Command" }
    var checkedType: TypeAnnotation { .named("Command") }

    /// What the checker knows of its members.
    static let memberTypes: [String: TypeAnnotation] = [
        "words": .list(.string),
        "run": .functionType([], .named("Status"), throws: false),
        "runQuietly": .functionType([], .named("Status"), throws: false),
        "check": .functionType([], .named("Status"), throws: true),
        "output": .functionType([], .output, throws: false),
    ]

    var memberNames: [String] { Array(CommandObject.memberTypes.keys.sorted()) }
    var description: String { "Command(" + words.map { "\"\($0)\"" }.joined(separator: ", ") + ")" }

    func member(_ name: String) -> Value? {
        switch name {
        case "words": .list(words.map(Value.string))
        case "run": method("run") { try self.run(display: true) }
        case "runQuietly": method("runQuietly") { try self.run(display: false) }
        case "check": method("check", throwing: true) { try self.check() }
        case "output": method("output") { try self.output() }
        default: nil
        }
    }

    private func method(_ name: String, throwing: Bool = false, _ body: @escaping () throws -> Value) -> Value {
        .function(OverloadSet(name: name, candidates: [
            Function(name: name, parameters: [], returnType: nil, body: .native { _, _ in try body() }, isThrowing: throwing),
        ]))
    }

    // MARK: Running

    private var node: PipelineNode {
        PipelineNode(
            commands: [CommandNode(words: words.map { .text([.literal($0)]) })],
            source: words.joined(separator: " "), input: nil
        )
    }

    /// As a statement: its output goes where the shell's does. (`runQuietly()`
    /// is the same where a condition or a part of a chain has it: a function
    /// used as a command shows nothing it gives there.)
    func run(display: Bool) throws -> Value {
        statusValue(of: try shell.run(node, display: display))
    }

    /// As `try make`: failing throws a `CommandFailure`.
    func check() throws -> Value {
        let status = try shell.run(node, display: true)
        if status != 0 {
            let (code, signal) = shell.interpreter.exitCode(status)
            throw RuntimeError.commandFailure("\(node.source) failed with status \(status)", status: status,
                                              output: Output(text: "", code: code, signal: signal))
        }
        return statusValue(of: status)
    }

    /// As `$(…)`: its output is gathered, whatever its status.
    func output() throws -> Value {
        var status: Int32 = 0
        var text = try shell.capturing { status = try shell.run(node, display: false) }
        while text.last == "\n" { text.removeLast() }
        let (code, signal) = shell.interpreter.exitCode(status)
        return .output(Output(text: text, code: code, signal: signal))
    }

    private func statusValue(of status: Int32) -> Value {
        let (code, signal) = shell.interpreter.exitCode(status)
        return .record(Record([
            "code": code.map(Value.int) ?? .nothing,
            "signal": signal.map(Value.int) ?? .nothing,
            "succeeded": .bool(status == 0),
        ], typeName: "Status"))
    }
}

extension Shell {
    /// `Command(…)`, and the members the checker types it by.
    func installCommand() {
        interpreter.objectMembers["Command"] = CommandObject.memberTypes
        nonisolated(unsafe) let shell = self
        let function = interpreter.hostFunction(ExportedFunction(
            name: "Command", summary: "A program or function with its words, to run by hand: `run()` or `output()`.",
            parameters: [ExportedParameter(label: nil, name: "words", type: .string, variadic: true)],
            returnType: .named("Command"),
            call: { arguments in
                guard case .list(let items)? = arguments["words"], !items.isEmpty else {
                    throw RuntimeError("Command needs a name to run")
                }
                return .object(CommandObject(words: items.map(\.description), shell: shell))
            }
        ))
        interpreter.scopes[0].declare(function, named: "Command")
    }
}
