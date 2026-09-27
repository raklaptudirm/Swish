import Foundation

public final class Shell {
    public internal(set) var lastStatus: Int32 = 0

    /// Where builtins, displayed values and the last stage of a pipeline
    /// write. Redirected while capturing `$(…)`.
    var stdoutFD = STDOUT_FILENO
    /// Variable scopes, innermost last.
    var scopes: [[String: Binding]] = [[:]]

    let terminal = STDIN_FILENO
    /// Whether the shell owns the terminal and does job control.
    var interactive = false
    var shellPgid = getpgrp()
    var shellModes = termios()
    var stoppedJobs: [Job] = []
    var warnedAboutStoppedJobs = false

    private let editor = LineEditor()

    public init() {}

    /// Runs the read-eval loop until EOF or `exit`.
    public func runInteractive() -> Int32 {
        takeTerminal()
        // Lines of a statement that isn't finished yet, like an open `if` block.
        var pending = ""
        while true {
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
            return .success(try Parser.parse(source, bound: Set(scopes[0].keys)))
        } catch {
            return .failure(error)
        }
    }

    /// A runtime error abandons the rest of the input, unlike a failing
    /// command, which only sets the status.
    private func runReportingErrors(_ program: Program) {
        do {
            lastStatus = try run(program)
        } catch {
            report("error: \(error)")
            lastStatus = 1
        }
    }

    private func takeTerminal() {
        guard isatty(terminal) != 0 else { return }
        // If we were started in the background, wait until we're brought forward.
        while tcgetpgrp(terminal) != getpgrp() {
            kill(-getpgrp(), SIGTTIN)
        }
        for signal in [SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU] {
            Foundation.signal(signal, SIG_IGN)
        }
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
