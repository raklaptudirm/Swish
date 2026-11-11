import Foundation
import SwiftSyntax
import Swiit

/// The shell: a process with a terminal, jobs and a line editor, over an `Interpreter` that knows
/// none of that. It is the interpreter's host (the process), and declares the shell's own types and
/// functions in Swift for it (Resources/Prelude.swift).
public final class Shell: @unchecked Sendable {
    /// The language underneath. A client adds its own functions to it through Swiit's public
    /// interface.
    public let interpreter: Interpreter

    /// What the shell keeps for the task running now (`ShellTask`): the one
    /// holding the lock, or for code that doesn't hold it, the main task's.
    var task: ShellTask { interpreter.taskState as! ShellTask }

    /// How the current task's last statement ended.
    public internal(set) var lastStatus: Status {
        get { task.lastStatus }
        set { task.lastStatus = newValue }
    }
    /// Where the current task's output goes.
    var stdoutFD: Int32 {
        get { task.stdoutFD }
        set { task.stdoutFD = newValue }
    }
    /// Whether the current task's programs get the terminal: the task in the
    /// foreground's do, in an interactive shell; a background task's don't.
    var ownsTerminal: Bool { interactive && task.inForeground }
    /// Where the current task's errors go.
    var stderrFD: Int32 {
        get { task.stderrFD }
        set { task.stderrFD = newValue }
    }
    /// Programs on PATH, for highlighting and completion.
    var executableCache: (path: String, time: Date, names: Set<String>)?
    /// The command lines the last program read has (Front/), to check against the functions they
    /// name.
    var commandUses: [Front.CommandUse] = []

    let terminal = STDIN_FILENO
    /// Whether the shell owns the terminal and does job control.
    var interactive = false
    var shellPgid = getpgrp()
    var shellModes = termios()
    /// Jobs in the background: started with `async`, or stopped with ^Z.
    var jobs: [Job] = []
    var warnedAboutJobs = false
    /// A `try!` failed in a script, which stops it.
    var scriptStopped = false
    /// The builtins by name: the shell's own, and a client's (`register(_:)`).
    var builtins: [String: Builtin] = Shell.standardBuiltins
    /// The lines of a statement that is not finished yet, like the start of an `if` block.
    var unfinishedStatement = ""
    /// The variables `env` reads and writes: the process's own, unless a host gives others.
    var environment = EnvironmentAccess.process
    /// The source being run, so an error can show the line it is in (and the file it is from, if it
    /// is one).
    var diagnosticSource: (text: String, path: String?)?
    /// The signal that stopped the script, which it then ends by.
    var endingSignal: Int32?
    /// The signal that asked the run to stop, as the run is stopping.
    var stoppedBySignal: Int32?
    /// The running script's directory; nil at the prompt.
    var scriptDirectory: String?
    /// What runs before each prompt, in the order it was added (`beforePrompt`).
    var promptHooks: [Value] = []
    /// What runs when the working directory has changed since the last prompt (`onDirectoryChange`).
    var directoryHooks: [Value] = []
    /// The working directory when the last prompt was drawn, to tell when it has changed.
    var promptDirectory: String?

    let editor = LineEditor()

    /// The names a stage could be, known from the types.
    lazy var stageNames: StageNames = computeStageNames()

    /// What the functions a script declared say of their parameters (`@input`, `@flag`), by
    /// `function.parameter`.
    var scriptMarks: [String: CommandMarks.Marks] = [:]

    /// The static members (an enum's cases among them) of the types the program being checked
    /// declares, by type: the interpreter has none of them yet, and a command's word for one is
    /// read against these.
    var staticMembers: [String: [Symbol]] = [:]

    /// What the prelude declared that Swift code builds values of; set once, at the end of
    /// `installLibrary`, which is why it is not a `let`.
    var preludeTypes: PreludeTypes!

    /// What's been entered at the prompt: this shell's history, or the
    /// history file's outside the interactive shell.
    var historyEntries: [String] {
        interactive ? editor.history.entries : History(path: History.defaultPath).entries
    }

    /// Tasks still running end with the shell: they're cancelled, and waited for, as the scope that
    /// starts a task closes it (https://github.com/raklaptudirm/Swiit/blob/main/Docs/async.md).
    deinit {
        cancelAndJoinTasks()
    }

    public init() {
        // The shell writes into pipes itself now; a reader exiting early
        // should end that write with EPIPE, not kill the shell.
        signal(SIGPIPE, SIG_IGN)
        interpreter = Interpreter()
        interpreter.taskState = ShellTask()
        interpreter.host = Interpreter.Host(process: self)
        installLibrary()
        // A prelude only declares, so `env` is made here.
        do { try interpreter.evaluate("let env = Environment()") } catch {
            preconditionFailure("the shell's env: \(error)")
        }
        installJobs()
        recordStatuses()
        // Swift's `Task { }` writes where the code that started it writes, as
        // in Swift, but is in the background: it waits for its turn at the
        // input and the terminal, as a job's task does.
        // (Weakly: the shell closes its tasks as it goes, in `deinit`.)
        interpreter.host.makeTaskState = { [weak self] in
            guard let self else { return ShellTask() }
            let state = ShellTask()
            state.inForeground = false
            state.stdoutFD = stdoutFD
            state.stderrFD = stderrFD
            return state
        }
        // Awaited from the foreground, a task is in the foreground while it
        // runs: it reads the input, and its programs get the terminal.
        interpreter.host.willAwait = { [weak self] awaited in
            guard let self, task.inForeground, let state = awaited as? ShellTask,
                !state.inForeground
            else { return {} }
            state.inForeground = true
            return { state.inForeground = false }
        }
        // A task in the background reads the input only once it's awaited
        // from the foreground; reading sooner would take the prompt's.
        interpreter.host.withInputTurn = { [unowned self] read in
            let state = task
            if !state.inForeground {
                let cancellation = interpreter.cancellation
                let turn = state.turn
                guard
                    Interpreter.whileWaiting(
                        wake: { turn.poke() },
                        { state.waitForForeground(unless: cancellation) }
                    )
                else {
                    return
                }
            }
            Interpreter.whileWaiting { read() }
        }
    }
}

extension Shell {
    /// Runs source as code: nothing is shown for a bare expression, as in a
    /// script or `swish -c`. Use `print` to show a value.
    @discardableResult
    public func execute(_ source: String) -> Int32 {
        run(source, atPrompt: false)
    }

    /// Runs what was entered at the prompt: like `execute`, but the value of
    /// each expression is shown, as a REPL does.
    @discardableResult
    public func enter(_ source: String) -> Int32 {
        run(source, atPrompt: true)
    }

    /// Runs `body`, then puts `lastStatus` back as it was: what runs a prompt, a hook or a config
    /// file is not a command, and must not change `$?`.
    public func keepingStatus<Result>(_ body: () throws -> Result) rethrows -> Result {
        let status = lastStatus
        defer { lastStatus = status }
        return try body()
    }

    /// Reports what went wrong the way a compiler does: the message, and the line it is in with the
    /// place marked.
    func reportDiagnostic(_ diagnostic: Diagnostic) {
        guard let (text, path) = diagnosticSource, diagnostic.range != nil else {
            report((diagnostic.isSyntax ? "syntax error: " : "error: ") + diagnostic.message)
            return
        }
        // Where errors go decides whether the source is shown in color, as the line editor shows
        // it.
        var style: Diagnostic.Style?
        if interpreter.host.error.traits().isStyled {
            nonisolated(unsafe) let shell = self  // safe: called holding the interpreter lock, as the report is
            style = Diagnostic.Style(
                source: { shell.highlightStyles($0) },
                frame: { $0.styled(DisplayStyle.boldBlue) },
                mark: { $0.styled(DisplayStyle.error) },
                reset: DisplayStyle.reset
            )
        }
        report(diagnostic.rendered(in: text, path: path, style: style))
    }

    func run(_ source: String, atPrompt: Bool) -> Int32 {
        diagnosticSource = (source, nil)
        switch prepare(source) {
        case .failure(let diagnostic):
            reportReadingFailure(diagnostic)
        case .success(let reading):
            runReportingErrors(reading, atPrompt: atPrompt)
        }
        return lastStatus.number
    }

    /// Closes the top level as a scope: the tasks started there are cancelled
    /// and waited for, as at the end of a script or `swish -c`.
    public func cancelAndJoinTasks() {
        interpreter.cancelAndJoinTasks()
    }

    /// A program read: the source as Swift, and what it declares at its top level.
    struct Reading {
        var swift: String
        var declared: Interpreter.Declarations
    }

    /// Reads a program: its shell forms cured to Swift, which is checked whole, so a mistake
    /// anywhere runs none of it.
    func prepare(_ source: String) -> Result<Reading, Diagnostic> {
        let swift: String
        do {
            swift = try cured(source)
        } catch let failure as Reader.Failure {
            return .failure(
                Diagnostic(
                    kind: .syntax(isIncomplete: failure.incomplete),
                    message: failure.message
                )
            )
        } catch {
            return .failure(Diagnostic(kind: .syntax(isIncomplete: false), message: "\(error)"))
        }
        do {
            let declared = try interpreter.check(swift)
            if let message = firstCommandLineError(commandUses, declared: declared) {
                return .failure(
                    Diagnostic(kind: .type, message: message)
                )
            }
            return .success(Reading(swift: swift, declared: declared))
        } catch {
            return .failure(error)
        }
    }

    /// Tells what was wrong with a program that mustn't run (with the line, in a file), and fails
    /// the input.
    func reportReadingFailure(_ diagnostic: Diagnostic, file: String? = nil) {
        if diagnostic.range != nil, diagnosticSource != nil {
            reportDiagnostic(diagnostic)
        } else if diagnostic.isSyntax {
            report((file.map { "\($0): " } ?? "") + "syntax error: \(diagnostic.message)")
        } else {
            let line = diagnostic.range?.start.line
            let place =
                file.map {
                    "\($0):\(line.map(String.init) ?? "")" + (line == nil ? "" : ":") + " "
                } ?? ""
            report("\(place)error: \(diagnostic.message)")
        }
        lastStatus = .exited(2)
    }

    /// A runtime error abandons the rest of the input, unlike a failing
    /// command, which only sets the status.
    func runReportingErrors(
        _ reading: Reading,
        atPrompt: Bool = false,
        then finish: (() -> Void)? = nil
    ) {
        // Drop a stale ^C from while the prompt was up; a script's stops it.
        if interactive && interpreter.file == nil { _ = takeInterrupt() }
        stoppedBySignal = nil
        var handled = false
        // Only the prompt shows values; running code prints what it prints. A script goes on with
        // the next statement after an error in one.
        let observer: ((_ value: Value, _ callee: Symbol?) throws -> Void)? =
            atPrompt ? { [unowned self] value, callee in present(value, from: callee) } : nil
        let onError: ((Diagnostic) -> Bool)? =
            atPrompt
            ? nil
            : { [unowned self] diagnostic in
                handled = true
                return handleRunFailure(diagnostic)
            }
        do {
            try interpreter.evaluate(
                reading.swift,
                onValue: observer,
                onError: onError,
                completion: finish
            )
        } catch {
            if !handled || !error.isRuntime { _ = handleRunFailure(error) }
        }
    }

    /// Reports how a run failed, and says whether a script goes on with its next statement.
    func handleRunFailure(_ diagnostic: Diagnostic) -> Bool {
        if diagnostic.cause is JobSuspended {
            lastStatus = .exited(128 + SIGTSTP)  // Already announced; the job is in `jobs`.
            return false
        }
        if diagnostic.isCancelled, let signal = stoppedBySignal {
            stoppedBySignal = nil
            if interactive && interpreter.file == nil {
                writeAll(STDERR_FILENO, "\n")
                lastStatus = .signaled(SIGINT)
            } else {
                // A script stops, running its defers, then ends by the signal.
                lastStatus = .signaled(signal)
                scriptStopped = true
                endingSignal = signal
            }
            return false
        }
        if diagnostic.isFatal {
            reportDiagnostic(diagnostic)
            lastStatus = .exited(diagnostic.status)
            // At the prompt, stopping would mean exiting your shell; the
            // config file stops, as a script does.
            scriptStopped = !interactive || interpreter.file != nil
            return false
        }
        if diagnostic.isRuntime {
            reportDiagnostic(diagnostic)
            lastStatus = .exited(diagnostic.status)
            return true
        }
        report("error: \(diagnostic.message)")
        lastStatus = .exited(1)
        return false
    }
}

/// What the shell keeps for each task (the interpreter's task state): where its output and errors
/// go, and how its last statement went. The prompt's is the main task's; `async` and `Task { }`
/// make one each (`Interpreter.Host.makeTaskState`).
final class ShellTask {
    /// Where builtins, displayed values and the last stage of a pipeline
    /// write. Redirected while capturing `$(…)`.
    var stdoutFD = STDOUT_FILENO
    /// Where errors are reported, and programs' standard error goes, while
    /// running something with `2>`.
    var stderrFD = STDERR_FILENO
    /// Problems with single items reported so far (a file `ls` couldn't read), and how many the
    /// last statement had seen.
    var itemErrors = 0
    var itemErrorsSeen = 0
    /// How the last statement ended, kept as statements run (`recordStatuses`).
    var lastStatus = Status.success
    /// Whether it's the task in the foreground, whose programs get the
    /// terminal and which reads the input: the prompt's, or a task while it's
    /// awaited from there. Set from the task awaiting it, on another thread.
    var inForeground: Bool {
        get { turn.isForeground }
        set { turn.isForeground = newValue }
    }
    let turn = Turn()

    /// Blocks until it's in the foreground, or `cancellation` is asked
    /// (false). (Through `suspend`, so the lock is let go.)
    func waitForForeground(unless cancellation: Interpreter.Cancellation) -> Bool {
        turn.waitForForeground(unless: cancellation)
    }
}

/// Whether a task has its turn at the terminal and the input, which another thread sets and a
/// waiting one is woken by. A `Mutex` cannot wait, so the flag is kept under the condition that can.
final class Turn: @unchecked Sendable {  // safe: `foreground` is read and written holding `condition`
    private var foreground = true
    private let condition = NSCondition()

    var isForeground: Bool {
        get { condition.withLock { foreground } }
        set {
            condition.withLock {
                foreground = newValue
                condition.broadcast()
            }
        }
    }

    func waitForForeground(unless cancellation: Interpreter.Cancellation) -> Bool {
        condition.withLock {
            while !foreground && !cancellation.isSet { condition.wait() }
            return foreground
        }
    }

    /// Wakes a wait for the foreground, to look again.
    func poke() { condition.withLock { condition.broadcast() } }
}
