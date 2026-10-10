@_spi(Shell) import Swiit
import SwishKit

extension Library {
    /// The shell's own: `ls`, `ps`, `pwd`, `with(env:)`, `readLine`, `history`,
    /// `from`, `to`, `table`, `list` and the types they use (SwishShellLibrary),
    /// with the prelude declarations that are the shell's: `Status`,
    /// `CommandFailure`, `help`, `members`, `select` and `JSON`.
    static func shell(for shell: Shell) -> Library {
        Library(
            types: Bridge.shellTypes, columns: Bridge.shellColumns,
            enumStyles: Bridge.shellEnumStyles, functions: Bridge.shellFunctions,
            declarations: shellDeclarations,
            bodies: shell.commandMethods.merging([
                "help": (shell.help().body, nil),
                "members": (shell.interpreter.members().body, nil),
                "Sequence.select": selectBody,
                "capture": (shell.captureBody, nil),
                "displayItems": (.native { [unowned shell] _, arguments in
                    try shell.displayItems(arguments["value"] ?? .nothing)
                    return .nothing
                }, nil),
                "exitStatus": (.native { [unowned shell] _, arguments in shell.statusValue(shell.status(of: arguments["value"] ?? .nothing)) }, nil),
                "importPlugin": (.native { interpreter, arguments in
                    guard case .string(let name)? = arguments["name"], case .string(let path)? = arguments["path"] else { return .nothing }
                    try interpreter.importPlugin(name, from: path)
                    return .nothing
                }, nil),
                "escapingWildcards": (.native { _, arguments in .string(Glob.escape(arguments["text"]?.description ?? "")) }, nil),
            ]) { $1 }
        )
    }

    /// Swish source read after the core's prelude. The checker works from the
    /// signatures; the bodies are in Swift, found by name (`bodies`).
    private static let shellDeclarations = #"""
    /// How a command exited: `output.status`, and what `Command.run()` gives.
    /// A command statement is a `Status`, and `a && b || c` is
    /// `a.and { b }.or { c }`: run on the status, left to right.
    struct Status: Equatable, Hashable, Encodable {
        let code: Int?
        let signal: Int?
        let succeeded: Bool

        /// `next` when this succeeded; otherwise this.
        func and(_ next: () -> Status) -> Status {
            if succeeded { return next() }
            return self
        }

        /// This when it succeeded; otherwise `next`.
        func or(_ next: () -> Status) -> Status {
            if succeeded { return self }
            return next()
        }
    }

    /// What `try $(…)` throws when the command fails, and `try await job`:
    /// `catch let` it with a cast, `if let failure = error as? CommandFailure`.
    struct CommandFailure {
        let message: String
        let status: Status
        let text: String
        let localizedDescription: String
    }

    /// Unquoted text with a wildcard in a command's word: `Command("ls",
    /// Glob("*.swift"))` is the paths it matches. Where a pattern has a value
    /// in it, `escapingWildcards` keeps the value's own `*` literal.
    struct Glob {
        let pattern: String
        init(_ pattern: String) { self.pattern = pattern }
    }

    /// Text with its wildcards escaped, to stand for itself in a `Glob`.
    func escapingWildcards(_ text: String) -> String

    /// An unquoted list alone in a command's word: a word for each item, as
    /// `rm $files` gives.
    struct Spread {
        let value: Any
        init(_ value: Any) { self.value = value }
    }

    /// A program or function with its words, to run by hand: what a command
    /// typed at the prompt means. A word is a String, a `Glob`, a `Spread` or
    /// a closure; the first is the name.
    ///
    ///     Command("ls", "-la", Glob("*.swift")).writing(1, to: "out").run()
    struct Command {
        let words: [Any]
        var isExternal: Bool = false
        var redirections: [Redirection] = []
        var variables: [String: String] = [:]
        /// A call's arguments, as a tuple: `sorted(by: "size")` after a `|`.
        var arguments: Any? = nil
        /// What the checker decided about it as a stage of a pipeline.
        var hint: Any? = nil

        init(_ words: Any...) { self.words = words }

        /// `^name`: the program, even where a function or builtin has its name.
        func external() -> Command {
            var command = self
            command.isExternal = true
            return command
        }

        /// `X=1 cmd`: environment variables for this command only.
        func environment(_ variables: [String: String]) -> Command {
            var command = self
            for name in variables.keys { command.variables[name] = variables[name]! }
            return command
        }

        /// `< file`, `0< file`.
        func reading(_ fd: Int, from path: Any) -> Command {
            var command = self
            command.redirections = command.redirections + [Redirection(fd: fd, mode: "read", path: path, other: 0)]
            return command
        }

        /// `> file`, `e> file`.
        func writing(_ fd: Int, to path: Any) -> Command {
            var command = self
            command.redirections = command.redirections + [Redirection(fd: fd, mode: "write", path: path, other: 0)]
            return command
        }

        /// `>> file`, `e>> file`.
        func appending(_ fd: Int, to path: Any) -> Command {
            var command = self
            command.redirections = command.redirections + [Redirection(fd: fd, mode: "append", path: path, other: 0)]
            return command
        }

        /// `e>o`: a descriptor to wherever another one goes at this point.
        func sending(_ fd: Int, to other: Int) -> Command {
            var command = self
            command.redirections = command.redirections + [Redirection(fd: fd, mode: "send", path: nil, other: other)]
            return command
        }

        /// `sorted(by: "size")` after a `|`: the stage called with these.
        func calling(_ arguments: Any) -> Command {
            var command = self
            command.arguments = arguments
            return command
        }

        /// What the checker decided about it as a stage.
        func checked(_ hint: Any) -> Command {
            var command = self
            command.hint = hint
            return command
        }

        /// Runs it as a statement does, its output going where the shell's does.
        func run() -> Status
        /// Runs it as part of a chain or a condition does: a function used as a
        /// command shows nothing it gives.
        func runQuietly() -> Status
        /// Runs it as `try cmd` does: failing throws a `CommandFailure`.
        func check() throws -> Status
        /// Runs it as `$(…)` does, gathering its output whatever its status.
        func output() -> Output
        /// Starts it in the background, as `async cmd` does: a `Job`.
        func start() -> Any
        /// Starts it in the background keeping its output, as `async $(cmd)` does.
        func startCapturing() -> Any
    }

    /// Commands joined by `|`, fed a value or nothing.
    ///
    ///     Pipeline(from: [3, 1, 2], Command("sorted")).run()
    struct Pipeline {
        let input: Any?
        let commands: [Command]

        init(_ commands: Command...) {
            self.input = nil
            self.commands = commands
        }

        /// Fed a value: its items, if it is a sequence.
        init(from input: Any, _ commands: Command...) {
            self.input = input
            self.commands = commands
        }

        func run() -> Status
        func runQuietly() -> Status
        func check() throws -> Status
        func output() -> Output
        func start() -> Any
        func startCapturing() -> Any
    }

    /// A redirect of a `Command`'s: `mode` is "read", "write", "append", or
    /// "send" (to the descriptor `other`).
    struct Redirection {
        let fd: Int
        let mode: String
        let path: Any?
        let other: Int
    }

    /// A value as a status, as it is where commands join it with `&&` and
    /// `||`: a Bool succeeds when true, an `Output` as its command did, a
    /// `Status` is itself, and anything else succeeds.
    func exitStatus(of value: Any) -> Status

    /// Shows a value as a pipeline at the end of a statement does: its items,
    /// one a line, or as a table when they are records.
    func displayItems(_ value: Any)

    /// `import Tools from "./Tools"`: builds the Swift package at `path` and
    /// loads the functions it exports, as `Tools`.
    func importPlugin(_ name: String, from path: String)

    /// Runs the block with its output gathered, as `$(…)` does. Throwing,
    /// a status other than 0 throws a `CommandFailure`.
    func capture(throwing: Bool = false, _ body: () -> Void) -> Output

    /// A member `members` describes.
    struct Member: Equatable, Hashable, Encodable {
        let type: String
        let name: String
        let kind: String
    }

    /// Describes the input: each type's fields and members.
    func members(@input _ items: [Any]) -> [Member]

    /// A function `help` lists.
    struct Help: Equatable, Hashable, Encodable {
        let name: String
        let source: String
        let summary: String
        let usage: String
        let description: String
    }

    /// Parsed JSON: read by field (json.name, json["name"]) or element
    /// (json[0]), each giving JSON?, and as a type with .string, .int,
    /// .double, .bool, .array, .object and .isNull.
    struct JSON {}

    /// Lists every function you can call.
    func help() -> [Help]

    /// Shows a function, shell builtin or program in full, or a type's
    /// members: `help String`, `help FilePath`, or a struct of yours.
    /// - Parameter name: a function, shell builtin, type or program
    func help(_ name: String) -> [AttributedString]

    extension Sequence {
        /// Keeps only the named fields of each record.
        func select(_ fields: String...) -> [Any]
    }
    """#

    /// `xs | select name size`: a sequence method that reads each item.
    private static var selectBody: (body: FunctionBody, input: Parameter?) {
        let method = Function.builtin(
            "select", "Keeps only the named fields of each record or object.",
            [.input("item", .any), .positional("fields", .string, variadic: true)],
            .native { _, args in
                guard let record = args["item"]?.asRecord else {
                    throw RuntimeError("select: \(args["item"]!.description) has no fields")
                }
                var selected = Record()
                for field in args.strings("fields") { selected[field] = record[field] ?? .nothing }
                return .record(selected)
            }
        )
        let input = method.parameters.first(where: \.isInput)!
        // Each item is an Element; all of them, a list of Elements.
        let type: TypeAnnotation = input.type.isList ? .list(.parameter("Element")) : .parameter("Element")
        return (method.body, Parameter(label: nil, name: input.name, type: type, isInput: true))
    }
}
