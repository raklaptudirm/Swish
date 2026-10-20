import Swiit
import Foundation

/// The shell: a process with a terminal, jobs and a line editor, over an
/// `Interpreter` that knows none of that. It supplies the interpreter's host
/// (the process) and the shell constructs the core still depends on.
public final class Shell: @unchecked Sendable {
    /// Whether a pipeline of Swift's own calls runs as those calls (see
    /// `Desugarer`); tests turn it off to compare.

    /// The language.
    let interpreter: Interpreter

    /// What the shell keeps for the task running now (`ShellTask`): the one
    /// holding the lock, or for code that doesn't hold it, the main task's.
    var task: ShellTask { interpreter.taskState as! ShellTask }

    /// The status the current task's last statement gave.
    public internal(set) var lastStatus: Int32 {
        get { task.lastStatus }
        set { task.lastStatus = newValue }
    }
    /// The status the current task's last signal-killed command gave.
    var lastSignalStatus: Int32? {
        get { task.lastSignalStatus }
        set { task.lastSignalStatus = newValue }
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
    /// The command lines the last program read has (Front/), to check against the functions they name.
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
    /// The source being run, so an error can show the line it is in (and the file it is from, if it is one).
    var diagnosticSource: (text: String, path: String?)?
    /// The signal that stopped the script, which it then ends by.
    var endingSignal: Int32?
    /// The signal that asked the run to stop, as the run is stopping.
    var stoppedBySignal: Int32?
    /// The running script's directory; nil at the prompt.
    var scriptDirectory: String?

    let editor = LineEditor()

    /// The names a stage could be, known from the types.
    lazy var stageNames: StageNames = computeStageNames()

    /// The enums the program being checked declares, which a word for one can't be read against yet.
    /// What the functions a script declared say of their parameters (`@input`, `@flag`), by `function.parameter`.
    var scriptMarks: [String: CommandMarks.Marks] = [:]

    var staticEnums: [String: Interpreter.Declarations.Enumeration] = [:]

    /// What's been entered at the prompt: this shell's history, or the
    /// history file's outside the interactive shell.
    var historyEntries: [String] {
        interactive ? editor.history.entries : History(path: History.defaultPath).entries
    }

    /// Tasks still running end with the shell: they're cancelled, and waited
    /// for, as the scope that starts a task closes it (https://github.com/raklaptudirm/Swiit/blob/main/Docs/async.md).
    deinit {
        finishTasks()
    }

    public init() {
        // The shell writes into pipes itself now; a reader exiting early
        // should end that write with EPIPE, not kill the shell.
        signal(SIGPIPE, SIG_IGN)
        interpreter = Interpreter()
        interpreter.taskState = ShellTask()
        interpreter.host = Interpreter.Host(process: self)
        interpreter["env"] = Value(EnvironmentObject(access: .process))
        installLibrary()
        installJSON()
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
            guard let self, task.inForeground, let state = awaited as? ShellTask, !state.inForeground else { return {} }
            state.inForeground = true
            return { state.inForeground = false }
        }
        // A task in the background reads the input only once it's awaited
        // from the foreground; reading sooner would take the prompt's.
        interpreter.host.inputTurn = { [unowned self] read in
            let state = task
            if !state.inForeground {
                let cancellation = interpreter.cancellation
                guard Interpreter.whileWaiting(wake: { state.poke() }, { state.waitForForeground(unless: cancellation) }) else {
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

    /// Reports what went wrong the way a compiler does: the message, and the line it is in with the place marked.
    func reportDiagnostic(_ diagnostic: Diagnostic) {
        let kind = diagnostic.kind
        guard let (text, path) = diagnosticSource, diagnostic.range != nil else {
            report((kind == .syntax ? "syntax error: " : "error: ") + diagnostic.message)
            return
        }
        // Where errors go decides whether the source is shown in color, as the line editor shows it.
        var style: Diagnostic.Style?
        if interpreter.host.error.traits().styled {
            nonisolated(unsafe) let shell = self // safe: called holding the interpreter lock, as the report is
            style = Diagnostic.Style(
                source: { shell.highlightStyles($0) },
                frame: { $0.styled(DisplayStyle.boldBlue) },
                mark: { $0.styled(DisplayStyle.error) },
                reset: DisplayStyle.reset)
        }
        report(diagnostic.rendered(in: text, path: path, style: style))
    }

    private func run(_ source: String, atPrompt: Bool) -> Int32 {
        diagnosticSource = (source, nil)
        switch prepare(source) {
        case .failure(let diagnostic):
            reportReadingFailure(diagnostic)
        case .success(let reading):
            runReportingErrors(reading, atPrompt: atPrompt)
        }
        return lastStatus
    }

    /// Closes the top level as a scope: the tasks started there are cancelled
    /// and waited for, as at the end of a script or `swish -c`.
    public func finishTasks() {
        interpreter.finishTasks()
    }

    /// A program read: the source as Swift, and what it declares at its top level.
    struct Reading {
        var swift: String
        var declared: Interpreter.Declarations
    }

    /// Reads a program: its shell forms cured to Swift, which is checked whole, so a mistake anywhere runs none of it.
    func prepare(_ source: String) -> Result<Reading, Diagnostic> {
        let swift: String
        do {
            swift = try cured(source)
        } catch let failure as Failure {
            return .failure(Diagnostic(kind: .syntax, message: failure.message, isIncomplete: failure.incomplete))
        } catch {
            return .failure(Diagnostic(kind: .syntax, message: "\(error)"))
        }
        do {
            let declared = try interpreter.check(swift)
            if let message = firstCommandLineError(commandUses, declared: declared) {
                return .failure(Diagnostic(kind: .type, message: message, status: 2, isReported: false))
            }
            return .success(Reading(swift: swift, declared: declared))
        } catch {
            return .failure(error)
        }
    }

    /// Tells what was wrong with a program that mustn't run (with the line, in a file), and fails the input.
    func reportReadingFailure(_ diagnostic: Diagnostic, file: String? = nil) {
        if diagnostic.range != nil, diagnosticSource != nil {
            reportDiagnostic(diagnostic)
        } else if diagnostic.kind == .syntax {
            report((file.map { "\($0): " } ?? "") + "syntax error: \(diagnostic.message)")
        } else {
            let place = file.map { "\($0):\(diagnostic.line.map(String.init) ?? "")" + (diagnostic.line == nil ? "" : ":") + " " } ?? ""
            report("\(place)error: \(diagnostic.message)")
        }
        lastStatus = 2
    }

    /// A runtime error abandons the rest of the input, unlike a failing
    /// command, which only sets the status.
    func runReportingErrors(_ reading: Reading, atPrompt: Bool = false, then finish: (() -> Void)? = nil) {
        // Drop a stale ^C from while the prompt was up; a script's stops it.
        if interactive && interpreter.file == nil { _ = takeInterrupt() }
        stoppedBySignal = nil
        var handled = false
        // Only the prompt shows values; running code prints what it prints. A script goes on with the next statement
        // after an error in one.
        let observer: ((Interpreter.Observation) throws -> Void)? = atPrompt ? { [unowned self] in present($0) } : nil
        let onError: ((Diagnostic) -> Bool)? = atPrompt ? nil : { [unowned self] diagnostic in
            handled = true
            return handleRunFailure(diagnostic)
        }
        do {
            try interpreter.execute(reading.swift, observing: observer, onError: onError, then: finish)
        } catch {
            if !handled || error.kind != .runtime { _ = handleRunFailure(error) }
        }
    }

    /// Reports how a run failed, and says whether a script goes on with its next statement.
    func handleRunFailure(_ diagnostic: Diagnostic) -> Bool {
        if diagnostic.cause is JobSuspended {
            lastStatus = 128 + SIGTSTP // Already announced; the job is in `jobs`.
            return false
        }
        if diagnostic.kind == .cancelled, let signal = stoppedBySignal {
            stoppedBySignal = nil
            if interactive && interpreter.file == nil {
                writeAll(STDERR_FILENO, "\n")
                lastStatus = 128 + SIGINT
            } else {
                // A script stops, running its defers, then ends by the signal.
                lastStatus = 128 + signal
                scriptStopped = true
                endingSignal = signal
            }
            return false
        }
        if diagnostic.isReported {
            lastStatus = diagnostic.status
            return true
        }
        if diagnostic.isFatal {
            reportDiagnostic(diagnostic)
            lastStatus = diagnostic.status
            // At the prompt, stopping would mean exiting your shell; the
            // config file stops, as a script does.
            scriptStopped = !interactive || interpreter.file != nil
            return false
        }
        if diagnostic.kind == .runtime {
            reportDiagnostic(diagnostic)
            lastStatus = diagnostic.status
            return true
        }
        report("error: \(diagnostic.message)")
        lastStatus = 1
        return false
    }
}

/// What the shell keeps for each task (the core's `TaskContext`): where its
/// output and errors go, and how its last statement went. The prompt is the
/// one task for now (https://github.com/raklaptudirm/Swiit/blob/main/Docs/async.md, step 1).
final class ShellTask {
    /// Where builtins, displayed values and the last stage of a pipeline
    /// write. Redirected while capturing `$(…)`.
    var stdoutFD = STDOUT_FILENO
    /// Where errors are reported, and programs' standard error goes, while
    /// running something with `2>`.
    var stderrFD = STDERR_FILENO
    /// Problems with single items reported so far (a file `ls` couldn't read), and how many the last statement had seen.
    var itemErrors = 0
    var itemErrorsSeen = 0
    /// The status the last statement gave, kept as statements run
    /// (`recordStatuses`).
    var lastStatus: Int32 = 0
    /// The status the last signal-killed command gave, to tell 130 from ^C
    /// apart from a command that exited with 130.
    var lastSignalStatus: Int32?
    /// Whether it's the task in the foreground, whose programs get the
    /// terminal and which reads the input: the prompt's, or a task while it's
    /// awaited from there. Set from the task awaiting it, on another thread.
    var inForeground: Bool {
        get {
            turn.lock()
            defer { turn.unlock() }
            return foreground
        }
        set {
            turn.lock()
            foreground = newValue
            turn.broadcast()
            turn.unlock()
        }
    }
    private var foreground = true
    private let turn = NSCondition()

    /// Blocks until it's in the foreground, or `cancellation` is asked
    /// (false). (Through `suspend`, so the lock is let go.)
    func waitForForeground(unless cancellation: Cancellation) -> Bool {
        turn.lock()
        defer { turn.unlock() }
        while !foreground && !cancellation.isSet { turn.wait() }
        return foreground
    }

    /// Wakes a wait for the foreground, to look again.
    func poke() {
        turn.lock()
        turn.broadcast()
        turn.unlock()
    }
}
