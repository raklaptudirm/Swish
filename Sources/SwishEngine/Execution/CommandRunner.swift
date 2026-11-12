import Foundation
import Swiit
import SwishLibrary

/// What Execution asks of whatever runs it: the few things that are the shell's own and not the
/// running of a command line.
protocol ExecutionServices: AnyObject {
    /// Reports `message` where standard error goes now.
    func report(_ message: String)

    /// Whether the shell has a builtin of that name.
    func hasBuiltin(named name: String) -> Bool

    /// Runs `argv` as a builtin that runs in the shell, or returns nil if it isn't one.
    func runBuiltin(_ argv: [String]) -> Int32?

    /// What is said after "command not found": the names it was likely meant to be.
    func commandNotFoundHint(_ name: String) -> String

    /// The program a builtin stands for, as its command line, if it becomes one (`run` becomes
    /// Swish on a task file); nil for any other.
    func program(ofBuiltin name: String, arguments: [String]) throws -> [String]?

    /// What `--help` shows for a callee.
    func helpText(for callee: Callee, styled: Bool) -> String

    /// The names of the programs on PATH.
    func executableNames() -> Set<String>

    /// Shows a value to a person, as the prompt would.
    func show(_ value: Value, debug: Bool)

    /// The static members (an enum's cases among them) of the types the program being checked
    /// declares, by type.
    var staticMembers: [String: [Symbol]] { get }

    /// How types show in a table.
    var displayRegistry: DisplayRegistry { get }

    /// What the functions a script declared say of their parameters, by `function.parameter`.
    var scriptMarks: [String: CommandMarks.Marks] { get }
}

/// Runs command lines: binds words to parameters, runs pipelines and their stages, redirects,
/// keeps jobs, expands words and starts programs. It holds what that needs and asks its
/// `services` for the rest.
final class CommandRunner: @unchecked Sendable {
    let interpreter: Interpreter

    /// The terminal the shell holds and the jobs it keeps.
    let jobControl: JobControl

    /// The variables `env` reads and writes: the process's own, unless a host gives others.
    var environment = EnvironmentAccess.process

    /// What the prelude declared that Swift code builds values of; set once, as the library is
    /// installed.
    var preludeTypes: PreludeTypes!

    /// The names a stage could be, known from the types.
    lazy var stageNames: StageNames = computeStageNames()

    /// What the shell is, for what is not running a command.
    unowned let services: any ExecutionServices

    init(interpreter: Interpreter, jobControl: JobControl, services: any ExecutionServices) {
        self.interpreter = interpreter
        self.jobControl = jobControl
        self.services = services
    }

    /// What is kept for the task running now (`ShellTask`): the one holding the lock, or for code
    /// that doesn't hold it, the main task's.
    var task: ShellTask { interpreter.taskState as! ShellTask }

    /// How the current task's last statement ended.
    var lastStatus: Status {
        get { task.lastStatus }
        set { task.lastStatus = newValue }
    }

    /// Where the current task's output goes.
    var stdoutFD: Int32 {
        get { task.stdoutFD }
        set { task.stdoutFD = newValue }
    }

    /// Where the current task's errors go.
    var stderrFD: Int32 {
        get { task.stderrFD }
        set { task.stderrFD = newValue }
    }

    /// Whether the current task's programs get the terminal: the task in the foreground's do, in
    /// an interactive shell; a background task's don't.
    var ownsTerminal: Bool { jobControl.isInteractive && task.inForeground }
}
