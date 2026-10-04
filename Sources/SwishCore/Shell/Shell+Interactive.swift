import Foundation
import SwishKit

extension Shell {
    /// Runs the read-eval loop until EOF or `exit`.
    public func runInteractive() -> Int32 {
        takeTerminal()
        if !interactive {
            return runScript { Swift.readLine() }
        }
        editor.history = History(path: History.defaultPath)
        editor.continuationPrompt = "…".styled(DisplayStyle.dim) + " "
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
                for notice in announceJobs(styled: DisplayStyle.enabled(for: STDERR_FILENO)) { writeAll(STDERR_FILENO, notice + "\n") }
            }
            switch editor.readLine(prompt: pending.isEmpty ? prompt() : "…".styled(DisplayStyle.dim) + " ") {
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
}

extension Shell {
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
}

extension Shell {
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
        let status = failed ? "[\(lastStatus)]".styled(DisplayStyle.red) + " " : ""
        return directory.styled(DisplayStyle.cyan) + " " + status + "❯".styled(failed ? DisplayStyle.red : DisplayStyle.green) + " "
    }
}
