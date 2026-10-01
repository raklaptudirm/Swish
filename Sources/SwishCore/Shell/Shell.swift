import Foundation
import SwishKit

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
        installBuiltinFunctions()
    }
}

extension Shell {
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

    func parse(_ source: String) -> Result<Program, SyntaxError> {
        do {
            return .success(try Parser.parse(source, bound: globalNames()))
        } catch {
            return .failure(error)
        }
    }

    /// A runtime error abandons the rest of the input, unlike a failing
    /// command, which only sets the status.
    func runReportingErrors(_ program: Program) {
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
}

extension Shell {
    /// Names the parser should know: builtins and globals, as variables or functions.
    func globalNames() -> [String: NameKind] {
        scopes[0].bindings.merging(scopes[1].bindings) { $1 }.mapValues { binding in
            if binding.isFunction { return .function }
            if case .object(is EnumType) = binding.value { return .type }
            if case .object(is StructType) = binding.value { return .type }
            if case .object(is BridgedTypeName) = binding.value { return .type }
            return .variable
        }
    }
}
