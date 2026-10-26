// swift-format-ignore-file The shell's own declarations, in Swift, read after the language's
// prelude: the checker works from the signatures, and the bodies are in Swift too, found by name
// (Library/Install.swift). Not compiled: it is embedded in the target.

/// What text `from` can parse.
enum InputFormat: Equatable, Hashable {
    case json
}

/// What `to` can make of values.
enum OutputFormat: Equatable, Hashable {
    case json, text
}

/// What kind of entry `ls` found: `ls | filter { $0.type == .directory }`. In this order, so
/// `ls | sorted --by type` puts files first.
enum FileType: Equatable, Hashable, Comparable {
    case file, directory, symlink, other
}

/// How a job is going: its `state`.
enum JobState: Equatable, Hashable, Comparable {
    case running, stopped, done, cancelled
}

/// What `String.styled` can make text (the shell's: the core knows only `DisplayStyle`), each with
/// its terminal code as its raw value.
enum TextStyle: Equatable, Hashable {
    case bold, dim, italic, underline, red, green, yellow, blue, magenta, cyan, white, gray
}

/// An entry `ls` lists.
struct FileEntry: Equatable, Hashable, Encodable {
    let name: String
    let type: FileType
    let size: FileSize
    let modified: Date
    let permissions: String
    let owner: String
    let created: Date
    let accessed: Date
    let path: FilePath
    let target: FilePath?
}

/// A process `ps` lists.
struct ProcessEntry: Equatable, Hashable, Encodable {
    let pid: Int
    let ppid: Int
    let name: String
    let user: String
    let memory: FileSize?
    let cpuTime: Double?
    let threads: Int?
}

/// A struct that says which of its fields a table shows by default, in
/// order. The rest are still there for `filter`, `select` and `get`, and
/// `table` shows every one.
protocol Tabular {
    static var columns: [DisplayColumn] { get }
}

/// A command or task started in the background, which `await` joins and
/// `jobs` lists. What scripts may use of it is what the shell's jobs have
/// (Jobs.swift); a `Job<Int>` is one of these too.
protocol Job { func __jobMembers() }

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

/// `exit 1` as a statement: runs it, and what follows never does (a `guard`'s `else` may end in
/// it).
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
        command.redirections =
            command.redirections + [Redirection(fd: fd, mode: "read", path: path, other: 0)]
        return command
    }

    /// `> file`, `e> file`.
    func writing(_ fd: Int, to path: Any) -> Command {
        var command = self
        command.redirections =
            command.redirections + [Redirection(fd: fd, mode: "write", path: path, other: 0)]
        return command
    }

    /// `>> file`, `e>> file`.
    func appending(_ fd: Int, to path: Any) -> Command {
        var command = self
        command.redirections =
            command.redirections + [Redirection(fd: fd, mode: "append", path: path, other: 0)]
        return command
    }

    /// `e>o`: a descriptor to wherever another one goes at this point.
    func sending(_ fd: Int, to other: Int) -> Command {
        var command = self
        command.redirections =
            command.redirections + [Redirection(fd: fd, mode: "send", path: nil, other: other)]
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
    func start() -> Job<Output>
    /// Starts it in the background keeping its output, as `async $(cmd)` does.
    func startCapturing() -> Job<Output>
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
    func start() -> Job<Output>
    func startCapturing() -> Job<Output>
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

/// `try $(…)`: the same, and a status other than 0 throws a `CommandFailure`, which the program
/// must handle.
func captureThrowing(_ body: () -> Void) throws -> Output

/// A member `members` describes.
struct Member: Equatable, Hashable, Encodable {
    let type: String
    let name: String
    let kind: String
}

/// Describes the input: each type's fields and members.
func members(_ items: [Any]) -> [Member]

/// A function `help` lists.
struct Help: Equatable, Hashable, Encodable {
    let name: String
    let source: String
    let summary: String
    let usage: String
    let description: String
}

/// The variables of the programs the shell runs. `env.HOME` is a `String?`, nil when unset;
/// `env.PAGER = "less"` sets one and `= nil` removes it. `env["HOME"]` is the same, for a name
/// that isn't an identifier.
@dynamicMemberLookup
final class Environment: CustomStringConvertible {
    subscript(dynamicMember name: String) -> String? {
        get { environmentValue(name) }
        set { setEnvironmentValue(name, newValue) }
    }

    subscript(name: String) -> String? {
        get { environmentValue(name) }
        set { setEnvironmentValue(name, newValue) }
    }

    var description: String { "Environment" }
}

/// What `env.NAME` reads: the variable, or nil.
func environmentValue(_ name: String) -> String?
/// What `env.NAME = value` does: sets the variable, or removes it for nil.
func setEnvironmentValue(_ name: String, _ value: String?) throws

/// A value that stands for another where it flows through a pipeline and where it is shown: those
/// see what it wraps.
protocol Wrapping {
    var wrapped: Any { get }
}

/// Parsed JSON, which is read by field (`json.name`, `json["name"]`) and by position (`json[0]`),
/// each giving a `JSON?`, nil where there is none; and as `.string`, `.int`, `.double`, `.bool`,
/// `.array`, `.object` and `.isNull`. In a pipeline it flows as what it parsed to.
@dynamicMemberLookup
struct JSON: Wrapping {
    let raw: Any

    var wrapped: Any { raw }

    subscript(dynamicMember name: String) -> JSON? { jsonField(raw, name) }
    subscript(name: String) -> JSON? { jsonField(raw, name) }
    subscript(position: Int) -> JSON? { jsonField(raw, position) }

    var string: String? { jsonString(raw) }
    var int: Int? { jsonInt(raw) }
    var double: Double? { jsonDouble(raw) }
    var bool: Bool? { jsonBool(raw) }
    var array: [JSON]? { jsonArray(raw) }
    var object: [String: JSON]? { jsonObject(raw) }
    var isNull: Bool { jsonIsNull(raw) }
}

/// What a `JSON` reads of what it holds: the field or element, or nil if there is none or the
/// value isn't a record, a dictionary or a list; or the value as that type, or nil if it is of
/// another kind.
func jsonField(_ raw: Any, _ key: Any) -> JSON?
func jsonString(_ raw: Any) -> String?
func jsonInt(_ raw: Any) -> Int?
func jsonDouble(_ raw: Any) -> Double?
func jsonBool(_ raw: Any) -> Bool?
func jsonArray(_ raw: Any) -> [JSON]?
func jsonObject(_ raw: Any) -> [String: JSON]?
func jsonIsNull(_ raw: Any) -> Bool

/// Lists every function you can call.
func help() -> [Help]

/// Shows a function, shell builtin or program in full, or a type's
/// members: `help String`, `help FilePath`, or a struct of yours.
/// - Parameter name: a function, shell builtin, type or program
func help(_ name: String) -> [AttributedString]

extension Sequence {
    /// Keeps only the named fields of each record: a tuple of them, in the order named.
    /// - Parameter fields: what to make of each item, as in select name size, which is
    ///   map { (name: $0.name, size: $0.size) }
    func select<Fields>(_ fields: (Element) -> Fields) -> [Fields] {
        map(fields)
    }
}
/// Parses text into values.
/// - Parameter format: json
func from(_ format: InputFormat, _ text: [String]) throws -> JSON

/// Converts the input to text: json, or text for how it would be displayed.
/// - Parameter format: json or text
func to(_ format: OutputFormat, _ items: [Any]) throws -> String

/// Lays records out as a table with every field.
func table(_ items: [Any]) -> [String]

/// Shows each record as a list of fields.
func list(_ items: [Any]) -> [String]

/// The working directory.
func pwd() -> FilePath

/// Runs a closure with environment variables set, then puts them back.
/// - Parameter variables: the variables to set, as in with(env: ["EDITOR": "vim"]) { git commit }
/// - Parameter body: what to run with them set
func with<T>(env variables: [String: String], _ body: () throws -> T) rethrows -> T

/// Lists directory contents.
/// - Parameter paths: files or directories to list (default: the current directory)
/// - Parameter all: include hidden files
func ls(_ paths: FilePath..., all: Bool = false) -> [FileEntry]

/// What you've entered at the prompt, oldest first.
func history() -> [String]

/// A line of standard input, or nil at its end.
/// - Parameter strippingNewline: leave the line's newline off
func readLine(strippingNewline: Bool = true) -> String?

/// Lists running processes. Memory and CPU time are only known for your own processes.
func ps() -> [ProcessEntry]

func shellStyled(_ text: String, _ styles: [TextStyle]) -> String
extension String {
    /// The text in colors or emphasis, plain where color is off.
    /// - Parameter styles: how to style it, as in `.bold, .red`
    func styled(_ styles: TextStyle...) -> String { shellStyled(self, styles) }
}

extension Sequence {
    /// The items without repeats, first ones kept.
    func uniqued() -> [Element] {
        var seen: [Element: Bool] = [:]
        var kept: [Element] = []
        for item in self where seen[item] == nil {
            seen[item] = true
            kept.append(item)
        }
        return kept
    }

    /// The value of one field of each item.
    /// - Parameter key: a field, as in get name or get(\.name)
    func get<V>(_ key: KeyPath<Element, V>) -> [V] {
        map(key)
    }

    /// The items in order of a field; Swift's sorted() and sorted(by:)
    /// sort by the items themselves or a closure.
    /// - Parameter by: the field, as in --by size or by: \.size
    func sorted<V: Comparable>(by key: KeyPath<Element, V>) -> [Element] {
        // Ties keep their order.
        let items = Array(self)
        let keys = items.map(key)
        return keys.enumerated()
            .sorted { first, second in
                first.element != second.element
                    ? first.element < second.element : first.offset < second.offset
            }
            .map { items[$0.offset] }
    }
}

// `await job` is the shell's: the front end writes it as `await waited(job)` (`waitedFailing` under a `try`, and
// `latestJob()` for a bare `await`): waiting for a job is a blocking call, anywhere, typed by what the job was started
// with, and anything else is itself, awaited as Swift would.
func latestJob() -> Job<Output>
func waitForJob(_ job: Job, _ throwing: Bool) -> Any
@alreadyShown func waited<T>(_ job: Job<T>) -> T { waitForJob(job, false) }
@alreadyShown func waited<T>(_ value: T) -> T { value }
@alreadyShown func waitedFailing<T>(_ job: Job<T>) throws -> T { waitForJob(job, true) }
@alreadyShown func waitedFailing<T>(_ value: T) throws -> T { value }
