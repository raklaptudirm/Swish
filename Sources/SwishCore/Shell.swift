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
    /// Each enum's associated value types, by case, for checking them.
    var enumPayloadTypes: [ObjectIdentifier: [String: [TypeAnnotation]]] = [:]
    /// The protocols each enum declares.
    var enumConformances: [ObjectIdentifier: [String]] = [:]
    /// The return types of the functions being run, innermost last, so a
    /// returned `.case` knows its enum.
    var returnTypes: [TypeAnnotation?] = []
    var warnedAboutJobs = false
    /// A `try!` failed in a script, which stops it.
    var scriptStopped = false
    /// The signal that stopped the script, which it then ends by.
    var endingSignal: Int32?
    /// The running script's directory, which relative `import` paths start
    /// from; nil at the prompt, where they start from the working directory.
    var scriptDirectory: String?
    /// The running script's path, for `#filePath`.
    var scriptPath: String?
    /// Imported plugins: each module's name, and the package it came from.
    var plugins: [String: String] = [:]
    /// Methods every sequence has, like `sorted` and `filter`.
    var sequenceMethods: [String: OverloadSet] = [:]
    /// The declared types of globals, from entries already checked, so a
    /// later one knows `let xs: [Int] = []` is an [Int].
    var staticTypes: [String: TypeAnnotation] = [:]
    /// The status the last signal-killed command gave, to tell 130 from ^C
    /// apart from a command that exited with 130.
    var lastSignalStatus: Int32?

    private let editor = LineEditor()

    /// What's been entered at the prompt: this shell's history, or the
    /// history file's outside the interactive shell.
    var historyEntries: [String] {
        interactive ? editor.history.entries : History(path: History.defaultPath).entries
    }

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
        editor.continuationPrompt = "…".styled(Style.dim) + " "
        editor.isComplete = { [unowned self] text in
            if case .failure(let error) = parse(text), error.incomplete { return false }
            return true
        }
        editor.highlight = { [unowned self] in highlightStyles($0) }
        editor.complete = { [unowned self] in completions(for: $0, cursor: $1) }
        loadConfig()
        // Lines of a statement that isn't finished yet, like an open `if` block.
        var pending = ""
        while true {
            // Finished and stopped background jobs, before the prompt.
            if pending.isEmpty {
                for notice in announceJobs(styled: Style.enabled(for: STDERR_FILENO)) { writeAll(STDERR_FILENO, notice + "\n") }
            }
            switch editor.readLine(prompt: pending.isEmpty ? prompt() : "…".styled(Style.dim) + " ") {
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
                    // Checked first, as everywhere else: a type error runs nothing.
                    if let program = typeCheck(program) { runReportingErrors(program) }
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
        // ^C, kill and hangup stop the script at the next statement, so its
        // defers run; then it ends by the signal (see `endBySignal`).
        catchInterrupts([SIGINT, SIGTERM, SIGHUP])
        return runFile(at: path, arguments: arguments) { _ in
            guard let main = topLevelFunction("main") else { return }
            // `main` stands for the script, so its help and errors use the script's name.
            callAsCommand(main, named: (path as NSString).lastPathComponent, arguments)
        }
    }

    /// After a script stopped by a signal has run its defers: ends the
    /// process by that signal, as the script would have without them, so
    /// whatever started it sees how it ended.
    public func endBySignal() {
        guard let ending = endingSignal else { return }
        signal(ending, SIG_DFL)
        kill(getpid(), ending)
    }

    /// Runs a task file for `run`: its top level first, with no `args`, then
    /// the function named `task` with `arguments` as its command line. No
    /// task (or `--help`) lists them.
    public func runTasks(at path: String, task: String?, arguments: [String]) -> Int32 {
        catchInterrupts([SIGINT, SIGTERM, SIGHUP])
        return runFile(at: path, arguments: []) { program in
            guard let task, task != "--help", task != "-h" else {
                listTasks(program)
                return
            }
            guard let function = topLevelFunction(task) else {
                report("run: no task named '\(task)' in \(path); `run` lists them")
                lastStatus = 127
                return
            }
            callAsCommand(function, named: "run \(task)", arguments)
        }
    }

    /// Reads, checks and runs a file's top level, then `finish`, unless a
    /// `try!` stopped it. A top-level `defer` runs when it's all over.
    func runFile(at path: String, arguments: [String], then finish: (Program) -> Void) -> Int32 {
        guard let data = FileManager.default.contents(atPath: path) else {
            report("\(path): \(errorMessage(errno).lowercased())")
            return 127
        }
        scopes[0].bindings["args"] = Binding(value: .list(arguments.map(Value.string)), mutable: false)
        scriptPath = URL(fileURLWithPath: path).standardizedFileURL.path
        scriptDirectory = URL(fileURLWithPath: path).standardizedFileURL.deletingLastPathComponent().path
        // Parsed whole, so doc comments reach their functions and a syntax
        // error anywhere stops the script before any of it runs; then run a
        // statement at a time, so a runtime error only abandons its own.
        let program: Program
        var source = String(decoding: data, as: UTF8.self)
        // `#!/usr/bin/env swish`, so it runs as a program; the line stays,
        // blank, so line numbers do too.
        if source.hasPrefix("#!") { source = String(source.drop { $0 != "\n" }) }
        switch parse(source) {
        case .failure(let error):
            report("\(path): syntax error: \(error)")
            return 2
        case .success(let parsed):
            program = parsed
        }
        // Checked whole too: a type error anywhere runs none of it.
        guard let program = typeCheck(program, file: path) else { return lastStatus }
        var deferred: [Program] = []
        defer { runDeferred(deferred) }
        // Functions and types first, so any line can use them.
        runReportingErrors(Program(statements: program.statements.filter {
            if case .function = $0 { return true }
            return $0.declaresType
        }))
        for statement in program.statements {
            if case .deferBlock(let body) = statement {
                deferred.append(body)
                continue
            }
            if statement.declaresType { continue }
            runReportingErrors(Program(statements: [statement]))
            if scriptStopped { return lastStatus }
        }
        finish(program)
        return lastStatus
    }

    /// A function the file declared at its top level.
    private func topLevelFunction(_ name: String) -> OverloadSet? {
        guard let binding = scopes[1].bindings[name], binding.isFunction,
              case .function(let set as OverloadSet) = binding.value else { return nil }
        return set
    }

    /// Calls a script's function with command-line `arguments`, under `name`
    /// for its help and errors.
    private func callAsCommand(_ set: OverloadSet, named name: String, _ arguments: [String]) {
        let command = OverloadSet(name: name, candidates: set.candidates.map {
            Function(name: name, parameters: $0.parameters, returnType: $0.returnType, body: $0.body,
                     captured: $0.captured, documentation: $0.documentation)
        })
        do {
            lastStatus = try callCommand(command, arguments.map(CommandArgument.text), display: true)
        } catch let interrupt as Interrupted {
            lastStatus = 128 + interrupt.signal
            endingSignal = interrupt.signal
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
    }

    /// `run` alone: each task, with the first sentence of its doc comment.
    private func listTasks(_ program: Program) {
        let tasks: [(name: String, summary: String)] = program.statements.compactMap {
            guard case .function(let decl) = $0, !decl.name.hasPrefix("_") else { return nil }
            return (decl.name, decl.documentation?.summary.firstSentence ?? "")
        }
        guard !tasks.isEmpty else {
            writeAll(stdoutFD, "No tasks: a task is a function in the file.\n")
            lastStatus = 0
            return
        }
        let width = tasks.map(\.name.count).max()!
        let styled = Style.enabled(for: stdoutFD)
        var text = "Usage: run <task> [<argument>...]\n\nTasks:\n"
        for task in tasks {
            let name = task.name.padding(toLength: width, withPad: " ", startingAt: 0)
            text += "  " + (styled ? name.styled(Style.bold) : name) + (task.summary.isEmpty ? "" : "  " + task.summary) + "\n"
        }
        writeAll(stdoutFD, text)
        lastStatus = 0
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
                if let program = typeCheck(program) { runReportingErrors(program) }
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
            if let program = typeCheck(program) { runReportingErrors(program) }
        }
        return lastStatus
    }

    /// Checks types before anything runs, reporting what's wrong (with the
    /// line, in a file). The program as checked, with what the checker
    /// decided written in, or nil if it mustn't run.
    func typeCheck(_ program: Program, file: String? = nil) -> Program? {
        let checker = TypeChecker(shell: self)
        do {
            let checked = try checker.check(program)
            staticTypes.merge(checker.declaredGlobals) { $1 }
            return checked
        } catch {
            let place = file.map { "\($0):\(error.line.map(String.init) ?? "")" + (error.line == nil ? "" : ":") + " " } ?? ""
            report("\(place)error: \(error.message)")
            lastStatus = 2
            return nil
        }
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
        // Drop a stale ^C from while the prompt was up; a script's stops it.
        if interactive && scriptPath == nil { _ = takeInterrupt() }
        do {
            lastStatus = try run(program)
        } catch let interrupt as Interrupted {
            if interactive && scriptPath == nil {
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
            report("error: \(fatal.error)")
            lastStatus = fatal.error.status
            // At the prompt, stopping would mean exiting your shell; the
            // config file stops, as a script does.
            scriptStopped = !interactive || scriptPath != nil
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
        let styled = Style.enabled(for: stderrFD)
        if message.hasPrefix("error: ") {
            writeAll(stderrFD, "swish: error:".styled(Style.error, styled) + message.dropFirst(6) + "\n")
        } else {
            writeAll(stderrFD, "swish:".styled(Style.error, styled) + " \(message)\n")
        }
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
        for jobSignal in [SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU] {
            signal(jobSignal, SIG_IGN)
        }
        catchInterrupts()
        _ = setpgid(0, 0) // Fails harmlessly if we're already a session leader.
        shellPgid = getpgrp()
        tcsetpgrp(terminal, shellPgid)
        tcgetattr(terminal, &shellModes)
        interactive = true
    }

    /// The prompt: what the config's `prompt` function gives, or the
    /// default. One that fails is reported, and the default shown instead.
    private func prompt() -> String {
        do {
            if let custom = try customPrompt() { return custom }
        } catch {
            report("prompt: \(error)")
        }
        return defaultPrompt()
    }

    private func defaultPrompt() -> String {
        var directory = FileManager.default.currentDirectoryPath
        if let home = env("HOME"), directory == home || directory.hasPrefix(home + "/") {
            directory = "~" + directory.dropFirst(home.count)
        }
        let failed = lastStatus != 0
        let status = failed ? "[\(lastStatus)]".styled(Style.red) + " " : ""
        return directory.styled(Style.cyan) + " " + status + "❯".styled(failed ? Style.red : Style.green) + " "
    }
}
