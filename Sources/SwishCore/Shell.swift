import CShim
import Foundation
import SwishKit

public final class Shell {
    public internal(set) var lastStatus: Int32 = 0

    /// Where builtins, displayed values and the last stage of a pipeline
    /// write. Redirected while capturing `$(…)`.
    var stdoutFD = STDOUT_FILENO
    /// Where errors are reported, and programs' standard error goes, while
    /// running something with `2>`.
    var stderrFD = STDERR_FILENO
    /// Variable scopes, innermost last. The outermost holds the builtin
    /// functions, so a `func` at the prompt shadows one rather than
    /// overloading it.
    var scopes = [Scope(), Scope()]
    /// Per-item errors reported so far, like a file `ls` couldn't read.
    var itemErrorCount = 0
    /// Programs on PATH, for highlighting and completion.
    var executableCache: (path: String, time: Date, names: Set<String>)?
    /// How many Swish function calls are in progress.
    var callDepth = 0

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
    /// The status the last signal-killed command gave, to tell 130 from ^C
    /// apart from a command that exited with 130.
    var lastSignalStatus: Int32?

    private let editor = LineEditor()

    public init() {
        // The shell writes into pipes itself now; a reader exiting early
        // should end that write with EPIPE, not kill the shell.
        signal(SIGPIPE, SIG_IGN)
        installBuiltinFunctions()
    }

    /// Runs the read-eval loop until EOF or `exit`.
    public func runInteractive() -> Int32 {
        takeTerminal()
        if !interactive {
            return runScript { Swift.readLine() }
        }
        editor.history = History(path: History.defaultPath)
        editor.continuationPrompt = "\u{1B}[90m…\u{1B}[0m "
        editor.isComplete = { [unowned self] text in
            if case .failure(let error) = parse(text), error.incomplete { return false }
            return true
        }
        editor.highlight = { [unowned self] in highlightStyles($0) }
        editor.complete = { [unowned self] in completions(for: $0, cursor: $1) }
        // Lines of a statement that isn't finished yet, like an open `if` block.
        var pending = ""
        while true {
            // Finished and stopped background jobs, before the prompt.
            if pending.isEmpty {
                for notice in announceJobs() { writeAll(STDERR_FILENO, notice + "\n") }
            }
            switch editor.readLine(prompt: pending.isEmpty ? prompt() : "\u{1B}[90m…\u{1B}[0m ") {
            case .eof:
                if !pending.isEmpty { execute(pending) }
                return lastStatus
            case .interrupted:
                pending = ""
            case .line(let line):
                pending = pending.isEmpty ? line : pending + "\n" + line
                switch parse(pending) {
                case .failure(let error) where error.incomplete:
                    continue
                case .failure(let error):
                    report("syntax error: \(error)")
                    lastStatus = 2
                case .success(let program):
                    runReportingErrors(program)
                }
                pending = ""
            }
        }
    }

    /// Runs a script file. A `try!` that fails stops it; any other error
    /// only abandons the statement it's in.
    ///
    /// `arguments` are the script's `args`. If the script declares `main`,
    /// it's then called with them as its command line, so a script gets
    /// flags, `--help` and completion from `main`'s signature.
    public func runScript(at path: String, arguments: [String] = []) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            report("\(path): \(errorMessage(errno).lowercased())")
            return 127
        }
        scopes[0].bindings["args"] = Binding(value: .list(arguments.map(Value.string)), mutable: false)
        // Parsed whole, so doc comments reach their functions and a syntax
        // error anywhere stops the script before any of it runs; then run a
        // statement at a time, so a runtime error only abandons its own.
        let program: Program
        switch parse(String(decoding: data, as: UTF8.self)) {
        case .failure(let error):
            report("\(path): syntax error: \(error)")
            return 2
        case .success(let parsed):
            program = parsed
        }
        var status: Int32 = 0
        for statement in program.statements {
            runReportingErrors(Program(statements: [statement]))
            status = lastStatus
            if scriptStopped { return status }
        }
        guard let main = scopes[1].bindings["main"], main.isFunction,
              case .function(let set as OverloadSet) = main.value else { return status }
        // `main` stands for the script, so its help and errors use the script's name.
        let name = (path as NSString).lastPathComponent
        let script = OverloadSet(name: name, candidates: set.candidates.map {
            Function(name: name, parameters: $0.parameters, returnType: $0.returnType, body: $0.body,
                     captured: $0.captured, documentation: $0.documentation)
        })
        do {
            lastStatus = try callCommand(script, arguments.map(CommandArgument.text), display: true)
        } catch let fatal as FatalError {
            report("error: \(fatal.error)")
            lastStatus = fatal.error.status
        } catch let error as RuntimeError {
            report("error: \(error)")
            lastStatus = error.status
        } catch is AlreadyReported {
            lastStatus = 1
        } catch {
            report("error: \(error)")
            lastStatus = 1
        }
        return lastStatus
    }

    /// Runs lines as they come, grouping those of an unfinished statement.
    private func runScript(nextLine: () -> String?) -> Int32 {
        var pending = ""
        while let line = nextLine() {
            pending = pending.isEmpty ? line : pending + "\n" + line
            switch parse(pending) {
            case .failure(let error) where error.incomplete:
                continue
            case .failure(let error):
                report("syntax error: \(error)")
                lastStatus = 2
            case .success(let program):
                runReportingErrors(program)
                if scriptStopped { return lastStatus }
            }
            pending = ""
        }
        if !pending.isEmpty { execute(pending) }
        return lastStatus
    }

    @discardableResult
    public func execute(_ source: String) -> Int32 {
        switch parse(source) {
        case .failure(let error):
            report("syntax error: \(error)")
            lastStatus = 2
        case .success(let program):
            runReportingErrors(program)
        }
        return lastStatus
    }

    private func parse(_ source: String) -> Result<Program, SyntaxError> {
        do {
            return .success(try Parser.parse(source, bound: globalNames()))
        } catch {
            return .failure(error)
        }
    }

    /// A runtime error abandons the rest of the input, unlike a failing
    /// command, which only sets the status.
    private func runReportingErrors(_ program: Program) {
        _ = swish_take_interrupt() // Drop a stale ^C from while the prompt was up.
        do {
            lastStatus = try run(program)
        } catch is Interrupted {
            writeAll(STDERR_FILENO, "\n")
            lastStatus = 128 + SIGINT
        } catch is JobSuspended {
            lastStatus = 128 + SIGTSTP // Already announced; the job is in `jobs`.
        } catch is AlreadyReported {
            lastStatus = 1
        } catch let fatal as FatalError {
            report("error: \(fatal.error)")
            lastStatus = fatal.error.status
            // At the prompt, stopping would mean exiting your shell.
            scriptStopped = !interactive
        } catch let error as RuntimeError {
            report("error: \(error)")
            lastStatus = error.status
        } catch {
            report("error: \(error)")
            lastStatus = 1
        }
    }

    /// Reports an error, to wherever standard error is redirected.
    func report(_ message: String) {
        writeAll(stderrFD, "swish: \(message)\n")
    }

    /// Reports a problem with one item, like a file `ls` couldn't read,
    /// without stopping; the statement's status becomes a failure.
    func reportItemError(_ message: String) {
        report(message)
        itemErrorCount += 1
    }

    private func takeTerminal() {
        guard isatty(terminal) != 0 else { return }
        // If we were started in the background, wait until we're brought forward.
        while tcgetpgrp(terminal) != getpgrp() {
            kill(-getpgrp(), SIGTTIN)
        }
        for signal in [SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU] {
            Foundation.signal(signal, SIG_IGN)
        }
        swish_catch_interrupts()
        _ = setpgid(0, 0) // Fails harmlessly if we're already a session leader.
        shellPgid = getpgrp()
        tcsetpgrp(terminal, shellPgid)
        tcgetattr(terminal, &shellModes)
        interactive = true
    }

    private func prompt() -> String {
        var directory = FileManager.default.currentDirectoryPath
        if let home = env("HOME"), directory == home || directory.hasPrefix(home + "/") {
            directory = "~" + directory.dropFirst(home.count)
        }
        let failed = lastStatus != 0
        let status = failed ? "\u{1B}[31m[\(lastStatus)]\u{1B}[0m " : ""
        return "\u{1B}[36m\(directory)\u{1B}[0m \(status)\u{1B}[\(failed ? 31 : 32)m❯\u{1B}[0m "
    }
}
