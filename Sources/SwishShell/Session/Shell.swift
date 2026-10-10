@_spi(Shell) import Swiit
@_spi(Shell) import SwiitSwiftSyntax
import Foundation
import SwishKit

/// The shell: a process with a terminal, jobs and a line editor, over an
/// `Interpreter` that knows none of that. It supplies the interpreter's host
/// (the process) and the shell constructs the core still depends on.
public final class Shell {
    /// The language.
    let interpreter: Interpreter

    /// The status the last statement gave. The interpreter's, which keeps it
    /// for now (the `status` group of Docs/Design/boundaries.md).
    public internal(set) var lastStatus: Int32 {
        get { interpreter.lastStatus }
        set { interpreter.lastStatus = newValue }
    }

    /// Where builtins, displayed values and the last stage of a pipeline
    /// write. Redirected while capturing `$(…)`.
    var stdoutFD = STDOUT_FILENO
    /// Where errors are reported, and programs' standard error goes, while
    /// running something with `2>`.
    var stderrFD = STDERR_FILENO
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
    /// The signal that stopped the script, which it then ends by.
    var endingSignal: Int32?
    /// The running script's directory, which relative `import` paths start
    /// from; nil at the prompt, where they start from the working directory.
    var scriptDirectory: String?
    /// Imported plugins: each module's name, and the package it came from.
    var plugins: [String: String] = [:]

    let editor = LineEditor()

    /// What's been entered at the prompt: this shell's history, or the
    /// history file's outside the interactive shell.
    var historyEntries: [String] {
        interactive ? editor.history.entries : History(path: History.defaultPath).entries
    }

    public init() {
        // The shell writes into pipes itself now; a reader exiting early
        // should end that write with EPIPE, not kill the shell.
        signal(SIGPIPE, SIG_IGN)
        interpreter = Interpreter(host: SwishHost(), shellLayer: nil)
        interpreter.syntax = ShellSyntax()
        interpreter.frontEnd = SwiftSyntaxFrontEnd()
        interpreter.host = SwishHost(process: self)
        interpreter.shellLayer = ShellLayer(process: self)
        interpreter.owner = self
        interpreter.displayRegistryProvider = { [unowned interpreter] in interpreter.tableRegistry() }
        interpreter.bind("env", to: EnvironmentObject(access: .process))
        interpreter.objectMembers["Job"] = Dictionary(uniqueKeysWithValues: Job.members.map { ($0.name, $0.type) })
        interpreter.installBuiltinFunctions(libraries: [.shell(for: self)])
        interpreter.installJSON()
        installJobs()
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

    private func run(_ source: String, atPrompt: Bool) -> Int32 {
        switch interpreter.parse(source) {
        case .failure(let error):
            interpreter.report("syntax error: \(error)")
            lastStatus = 2
        case .success(let program):
            if let program = typeCheck(program) { runReportingErrors(program, atPrompt: atPrompt) }
        }
        return lastStatus
    }

    /// Checks types before anything runs, reporting what's wrong (with the
    /// line, in a file). The program as checked, with what the checker
    /// decided written in, or nil if it mustn't run.
    func typeCheck(_ program: Program, file: String? = nil) -> Program? {
        let checker = TypeChecker(interpreter: interpreter)
        do {
            let checked = try checker.check(program)
            interpreter.staticTypes.merge(checker.declaredGlobals) { $1 }
            // Now what the checker knows is written in: the shell's constructs become Swift.
            return Desugarer().program(checked)
        } catch {
            let place = file.map { "\($0):\(error.line.map(String.init) ?? "")" + (error.line == nil ? "" : ":") + " " } ?? ""
            interpreter.report("\(place)error: \(error.message)")
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
            lastStatus = try interpreter.run(program, observing: atPrompt ? { [unowned interpreter] value, expression, discarded in
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
            interpreter.report("error: \(fatal.error)")
            lastStatus = fatal.error.status
            // At the prompt, stopping would mean exiting your shell; the
            // config file stops, as a script does.
            scriptStopped = !interactive || interpreter.file != nil
        } catch let error as RuntimeError {
            interpreter.report("error: \(error)")
            lastStatus = error.status
        } catch {
            interpreter.report("error: \(error)")
            lastStatus = 1
        }
    }
}
