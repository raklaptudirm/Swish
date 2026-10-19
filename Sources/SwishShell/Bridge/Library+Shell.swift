@_spi(Layer) import Swiit
@_spi(Layer) import SwishShellLibrary

extension Library {
    /// The shell's own: `ls`, `ps`, `pwd`, `with(env:)`, `readLine`, `history`,
    /// `from`, `to`, `table`, `list` and the types they use (SwishShellLibrary),
    /// with the prelude declarations that are the shell's: `Status`,
    /// `CommandFailure`, `help`, `members`, `select` and `JSON`.
    static func shell(for shell: Shell) -> Library {
        Library(
            types: Bridge.shellTypes, functions: Bridge.shellFunctions,
            bridged: Bridge.shellBridged, declarations: shellDeclarations + fileSizeUnits,
            bodies: shell.commandMethods.merging([
                "help": (shell.help().body, nil),
                "members": (shell.interpreter.members().body, nil),
                "Sequence.select": selectBody,
                "capture": (shell.captureBody, nil),
                "captureThrowing": (shell.captureThrowingBody, nil),
                "startTask": (.native { [unowned shell] interpreter, arguments in
                    guard case .string(let source)? = arguments["source"], let body = arguments["body"] else { return .nothing }
                    return .object(try shell.startTask(source: source) { try interpreter.call(body, with: []) })
                }, nil),
                "displayItems": (.native { [unowned shell] _, arguments in
                    try shell.displayItems(arguments["value"] ?? .nothing)
                    return .nothing
                }, nil),
                "exitStatus": (.native { [unowned shell] _, arguments in shell.statusValue(shell.status(of: arguments["value"] ?? .nothing)) }, nil),
                "exitShell": (.native { [unowned shell] _, arguments in
                    _ = try shell.run([arguments["command"] ?? .nothing], from: nil, display: true)
                    throw RuntimeError("exit did not leave")
                }, nil),
                "shellText": (.native { interpreter, arguments in .string(try interpreter.describing(arguments["value"] ?? .nothing)) }, nil),
                "escapingWildcards": (.native { _, arguments in .string(Glob.escape(arguments["text"]?.description ?? "")) }, nil),
            ]) { $1 }.merging(jsonBodies) { $1 }
        )
    }

    /// `2.mb` and `1.5.gib`: each unit a file size is written in is a property of `Int` and `Double`.
    private static var fileSizeUnits: String {
        let units = FileSize.units.sorted { ($0.value, $0.key) < ($1.value, $1.key) }
        func properties(of number: String, _ amount: String) -> String {
            units.map { "    var \($0.key): FileSize { FileSize(\(amount), multiplier: \($0.value)) }" }.joined(separator: "\n")
        }
        return "\nextension Int {\n\(properties(of: "Int", "Double(self)"))\n}\nextension Double {\n\(properties(of: "Double", "self"))\n}\n"
    }

    /// Swish source read after the core's prelude. The checker works from the
    /// signatures; the bodies are in Swift, found by name (`bodies`).
    private static let shellDeclarations = #"""
    /// A struct that says which of its fields a table shows by default, in
    /// order. The rest are still there for `filter`, `select` and `get`, and
    /// `table` shows every one.
    protocol Tabular {
        static var columns: [DisplayColumn] { get }
    }

    /// A command or task started in the background, which `await` joins and
    /// `jobs` lists. What scripts may use of it is what the shell's jobs have
    /// (Jobs.swift); a `Job<Int>` is one of these too.
    protocol Job { \#(Job.declaration) }

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
    /// `catch let failure as CommandFailure`, or `error as? CommandFailure`.
    struct CommandFailure: Error {
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

    /// `exit 1` as a statement: runs it, and what follows never does (a `guard`'s `else` may end in it).
    func exitShell(_ command: Command) -> Never

    /// A value as a command's word has it: an optional's value, not `Optional(…)`.
    func shellText(_ value: Any?) -> String

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
        func start() -> Job
        /// Starts it in the background keeping its output, as `async $(cmd)` does.
        func startCapturing() -> Job
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
        func start() -> Job
        func startCapturing() -> Job
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

    /// Runs `body` as a task of its own, as `async f()` does: a `Job`, which
    /// `await` joins for what `body` gives. `source` is how `jobs` shows it.
    func startTask<T>(_ source: String, _ body: () throws -> T) -> Job<T>

    /// Shows a value as a pipeline at the end of a statement does: its items,
    /// one a line, or as a table when they are records.
    func displayItems(_ value: Any)

    /// Runs the block with its output gathered, as `$(…)` does. Throwing,
    /// a status other than 0 throws a `CommandFailure`.
    func capture(throwing: Bool = false, _ body: () -> Void) -> Output

    /// `try $(…)`: the same, and a status other than 0 throws a `CommandFailure`, which the program must handle.
    func captureThrowing(_ body: () -> Void) throws -> Output

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

    /// What `json.name`, `json["name"]` and `json[0]` read: the field or
    /// element, or nil if there is none or the value isn't a record, a
    /// dictionary or a list.
    func jsonField(_ value: JSON?, _ key: Any) -> JSON?
    /// What `json.string`, `.int`, `.double`, `.bool`, `.array` and `.object`
    /// read: the value as that type, or nil if it is of another kind.
    func jsonString(_ value: JSON?) -> String?
    func jsonInt(_ value: JSON?) -> Int?
    func jsonDouble(_ value: JSON?) -> Double?
    func jsonBool(_ value: JSON?) -> Bool?
    func jsonArray(_ value: JSON?) -> [JSON]?
    func jsonObject(_ value: JSON?) -> [String: JSON]?
    /// What `json.isNull` reads: whether it is nil.
    func jsonIsNull(_ value: JSON?) -> Bool

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
