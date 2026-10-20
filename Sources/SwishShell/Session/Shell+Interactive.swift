import Swiit
import Foundation

extension Shell {
    /// Runs the read-eval loop until EOF or `exit`.
    public func runInteractive() -> Int32 {
        takeTerminal()
        if !interactive {
            return runScript { [unowned self] in Interpreter.whileWaiting { Swift.readLine() } }
        }
        editor.history = History(path: History.defaultPath)
        editor.continuationPrompt = "…".styled(DisplayStyle.dim) + " "
        // These run while a line is read, when nothing else runs.
        editor.isComplete = { [unowned self] text in
            if case .failure(let error) = prepare(text), error.isIncomplete { return false }
            return true
        }
        editor.highlight = { [unowned self] text in highlightStyles(text) }
        editor.complete = { [unowned self] text, cursor in completions(for: text, cursor: cursor) }
        loadConfig()
        // Lines of a statement that isn't finished yet, like an open `if` block.
        var pending = ""
        while true {
            // Finished and stopped background jobs, before the prompt.
            if pending.isEmpty {
                for notice in announceJobs(styled: DisplayStyle.enabled(for: STDERR_FILENO)) { writeAll(STDERR_FILENO, notice + "\n") }
            }
            let prompt = pending.isEmpty ? prompt() : "…".styled(DisplayStyle.dim) + " "
            switch Interpreter.whileWaiting({ editor.readLine(prompt: prompt) }) {
            case .eof:
                if !pending.isEmpty { enter(pending) }
                return lastStatus
            case .interrupted:
                pending = ""
            case .line(let line):
                pending = pending.isEmpty ? line : pending + "\n" + line
                diagnosticSource = (pending, nil)
                switch prepare(pending) {
                case .failure(let error) where error.isIncomplete:
                    continue
                case .failure(let error):
                    reportReadingFailure(error)
                case .success(let reading):
                    // Checked first, as everywhere else: a type error runs nothing.
                    runReportingErrors(reading, atPrompt: true)
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
            diagnosticSource = (pending, nil)
            switch prepare(pending) {
            case .failure(let error) where error.isIncomplete:
                continue
            case .failure(let error):
                reportReadingFailure(error)
            case .success(let reading):
                runReportingErrors(reading)
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
