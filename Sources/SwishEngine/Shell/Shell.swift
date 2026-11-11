import Foundation
import SwiftSyntax
import Swiit

/// The shell: a process with a terminal and jobs, over an `Interpreter` that knows
/// none of that. It is the interpreter's host (the process), and declares the shell's own types and
/// functions in Swift for it (ScriptLibrary/Prelude/Prelude.swift).
public final class Shell: @unchecked Sendable {
    /// The language underneath. A client adds its own functions to it through Swiit's public
    /// interface.
    public let interpreter: Interpreter

    /// How the current task's last statement ended.
    public internal(set) var lastStatus: Status {
        get { runner.lastStatus }
        set { runner.lastStatus = newValue }
    }

    /// Runs command lines (Execution/).
    private(set) lazy var runner = CommandRunner(
        interpreter: interpreter,
        jobControl: jobControl,
        services: self
    )

    /// The terminal the shell holds and the jobs it keeps.
    let jobControl = JobControl()

    /// What the last run left behind (`RunState`).
    var runState = RunState()

    /// What the front end knows of the programs around a command line (`ProgramKnowledge`).
    var programKnowledge = ProgramKnowledge()

    /// The builtins by name: the shell's own, and a client's (`register(_:)`).
    var builtins: [String: Builtin] = Shell.standardBuiltins
    /// The lines of a statement that is not finished yet, like the start of an `if` block.
    var unfinishedStatement = ""

    /// What the prelude declared that Swift code builds values of; set once, at the end of
    /// `installLibrary`, which is why it is not a `let`.
    var preludeTypes: PreludeTypes!

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
        runner.installJobs()
        recordStatuses()
        // Swift's `Task { }` writes where the code that started it writes, as
        // in Swift, but is in the background: it waits for its turn at the
        // input and the terminal, as a job's task does.
        // (Weakly: the shell closes its tasks as it goes, in `deinit`.)
        interpreter.host.makeTaskState = { [weak self] in
            guard let self else { return ShellTask() }
            let state = ShellTask()
            state.inForeground = false
            state.stdoutFD = runner.stdoutFD
            state.stderrFD = runner.stderrFD
            return state
        }
        // Awaited from the foreground, a task is in the foreground while it
        // runs: it reads the input, and its programs get the terminal.
        interpreter.host.willAwait = { [weak self] awaited in
            guard let self, runner.task.inForeground, let state = awaited as? ShellTask,
                !state.inForeground
            else { return {} }
            state.inForeground = true
            return { state.inForeground = false }
        }
        // A task in the background reads the input only once it's awaited
        // from the foreground; reading sooner would take the prompt's.
        interpreter.host.withInputTurn = { [unowned self] read in
            let state = runner.task
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
        guard let (text, path) = runState.diagnosticSource, diagnostic.range != nil else {
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
        runState.diagnosticSource = (source, nil)
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
            if let message = firstCommandLineError(programKnowledge.commandUses, declared: declared)
            {
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
        if diagnostic.range != nil, runState.diagnosticSource != nil {
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
        if jobControl.isInteractive && interpreter.file == nil { _ = takeInterrupt() }
        runState.stoppedBySignal = nil
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

        if diagnostic.isCancelled, let signal = runState.stoppedBySignal {
            runState.stoppedBySignal = nil
            if jobControl.isInteractive && interpreter.file == nil {
                writeAll(STDERR_FILENO, "\n")
                lastStatus = .signaled(SIGINT)
            } else {
                // A script stops, running its defers, then ends by the signal.
                lastStatus = .signaled(signal)
                runState.scriptStopped = true
                runState.endingSignal = signal
            }
            return false
        }

        if diagnostic.isFatal {
            reportDiagnostic(diagnostic)
            lastStatus = .exited(diagnostic.status)
            // At the prompt, stopping would mean exiting your shell; the
            // config file stops, as a script does.
            runState.scriptStopped = !jobControl.isInteractive || interpreter.file != nil
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
