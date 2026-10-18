@_spi(Layer) import Swiit
import Foundation
import SwiitKit

/// The shell: a process with a terminal, jobs and a line editor, over an
/// `Interpreter` that knows none of that. It supplies the interpreter's host
/// (the process) and the shell constructs the core still depends on.
public final class Shell {
    /// Whether a pipeline of Swift's own calls runs as those calls (see
    /// `Desugarer`); tests turn it off to compare.
    var directCalls = true

    /// The language.
    let interpreter: Interpreter

    /// What the shell keeps for the task running now (`ShellTask`): the one
    /// holding the lock, or for code that doesn't hold it, the main task's.
    var task: ShellTask {
        (interpreter.lock.isHeldByCurrentThread ? interpreter.task : interpreter.mainTask).host as! ShellTask
    }

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
    /// The running script's directory; nil at the prompt.
    var scriptDirectory: String?

    let editor = LineEditor()

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
        interpreter = Interpreter(host: SwiitHost(name: "swish"), outputCounter: OutputCounter())
        interpreter.task.host = ShellTask()
        interpreter.syntax = ShellSyntax()
        interpreter.host = SwiitHost(process: self)
        // Library functions that ask are lent what was entered before, too.
        interpreter.contextProvider = { [unowned self] in
            HostContext(history: historyEntries, colorOutput: interpreter.host.output.traits().styled,
                         display: interpreter.displayRegistryProvider())
        }
        interpreter.owner = self
        interpreter.displayRegistryProvider = { [unowned interpreter] in interpreter.tableRegistry() }
        interpreter.bind("env", to: EnvironmentObject(access: .process))
        interpreter.installBuiltinFunctions(libraries: [.shell(for: self)])
        interpreter.installJSON()
        installJobs()
        recordStatuses()
        // Swift's `Task { }` writes where the code that started it writes, as
        // in Swift, but is in the background: it waits for its turn at the
        // input and the terminal, as a job's task does.
        // (Weakly: the shell closes its tasks as it goes, in `deinit`.)
        interpreter.newTaskHost = { [weak self] in
            guard let self else { return ShellTask() }
            let state = ShellTask()
            state.inForeground = false
            state.stdoutFD = stdoutFD
            state.stderrFD = stderrFD
            return state
        }
        // Awaited from the foreground, a task is in the foreground while it
        // runs: it reads the input, and its programs get the terminal.
        interpreter.awaitingTask = { [weak self] handle in
            guard let self, task.inForeground, let state = handle.context.host as? ShellTask, !state.inForeground else { return {} }
            state.inForeground = true
            return { state.inForeground = false }
        }
        // A task in the background reads the input only once it's awaited
        // from the foreground; reading sooner would take the prompt's.
        interpreter.inputTurn = { [unowned self] read in
            let state = task
            if !state.inForeground {
                let cancellation = interpreter.task.cancellation
                guard interpreter.suspend(wake: { state.poke() }, { state.waitForForeground(unless: cancellation) }) else {
                    return
                }
            }
            interpreter.suspend { read() }
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
    func reportDiagnostic(_ kind: Diagnostic.Kind, _ message: String, at range: SourceRange?, calls: [RuntimeError.Call] = []) {
        guard let (text, path) = diagnosticSource, range != nil else {
            interpreter.report((kind == .syntax ? "syntax error: " : "error: ") + message)
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
        interpreter.report(Diagnostic(kind: kind, message: message, range: range, calls: calls).rendered(in: text, path: path, style: style))
    }

    private func run(_ source: String, atPrompt: Bool) -> Int32 {
        // The shell touches the interpreter holding its lock, as tasks do.
        interpreter.withMainTask {
        diagnosticSource = (source, nil)
        switch interpreter.parse(source) {
        case .failure(let error):
            reportDiagnostic(.syntax, "\(error)", at: error.range)
            lastStatus = 2
        case .success(let program):
            if let program = typeCheck(program) { runReportingErrors(program, atPrompt: atPrompt) }
        }
        return lastStatus
        }
    }

    /// Closes the top level as a scope: the tasks started there are cancelled
    /// and waited for, as at the end of a script or `swish -c`.
    public func finishTasks() {
        interpreter.withMainTask { interpreter.closeTasks(above: -1) }
    }

    /// Checks types before anything runs, reporting what's wrong (with the
    /// line, in a file). The program as checked, with what the checker
    /// decided written in, or nil if it mustn't run.
    func typeCheck(_ program: Program, file: String? = nil) -> Program? {
        let checker = TypeChecker(interpreter: interpreter)
        // Each shell construct becomes Swift as soon as it is checked, while the checker still has the scopes it was checked in.
        let desugarer = Desugarer(directCalls: directCalls)
        checker.rewriteExtension = { desugarer.expression($0) }
        do {
            let checked = try checker.check(program)
            interpreter.staticTypes.merge(checker.declaredGlobals) { $1 }
            return checked
        } catch {
            if error.spot ?? error.range != nil, diagnosticSource != nil {
                reportDiagnostic(.type, error.message, at: error.spot ?? error.range)
            } else {
                let place = file.map { "\($0):\(error.line.map(String.init) ?? "")" + (error.line == nil ? "" : ":") + " " } ?? ""
                interpreter.report("\(place)error: \(error.message)")
            }
            lastStatus = 2
            return nil
        }
    }

    /// A runtime error abandons the rest of the input, unlike a failing
    /// command, which only sets the status.
    func runReportingErrors(_ program: Program, atPrompt: Bool = false) {
        // Drop a stale ^C from while the prompt was up; a script's stops it.
        if interactive && interpreter.file == nil { _ = takeInterrupt() }
        do {
            // Only the prompt shows values; running code prints what it prints.
            try interpreter.run(program, observing: atPrompt ? { [unowned interpreter] value, expression, discarded in
                interpreter.present(value, from: expression, discarded: discarded)
            } : nil)
        } catch let interrupt as Interrupted {
            if interactive && interpreter.file == nil {
                writeAll(STDERR_FILENO, "\n")
                lastStatus = 128 + SIGINT
            } else {
                // A script stops, running its defers, then ends by the signal.
                lastStatus = 128 + interrupt.signal
                scriptStopped = true
                endingSignal = interrupt.signal
            }
        } catch is JobSuspended {
            lastStatus = 128 + SIGTSTP // Already announced; the job is in `jobs`.
        } catch is AlreadyReported {
            lastStatus = 1
        } catch let fatal as FatalError {
            reportDiagnostic(.runtime, "\(fatal.error)", at: fatal.error.range, calls: fatal.error.calls)
            lastStatus = fatal.error.status
            // At the prompt, stopping would mean exiting your shell; the
            // config file stops, as a script does.
            scriptStopped = !interactive || interpreter.file != nil
        } catch let error as RuntimeError {
            reportDiagnostic(.runtime, "\(error)", at: error.range, calls: error.calls)
            lastStatus = error.status
        } catch {
            interpreter.report("error: \(error)")
            lastStatus = 1
        }
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
