import Foundation
import Swiit

extension Shell {
    /// Runs the read-eval loop until EOF or `exit`.
    public func runInteractive() -> Int32 {
        guard takeTerminal() else {
            return runScript { [unowned self] in Interpreter.whileWaiting { Swift.readLine() } }
        }
        editor.history = History(path: History.defaultPath)
        editor.continuationPrompt = "…".styled(DisplayStyle.dim) + " "
        // These run while a line is read, when nothing else runs.
        editor.isComplete = { [unowned self] text in !isUnfinished(text) }
        editor.highlight = { [unowned self] text in highlightStyles(text) }
        editor.complete = { [unowned self] text, cursor in
            completions(for: text, cursor: cursor).map(LineEditor.Completion.init)
        }
        loadConfig()

        while true {
            // Finished and stopped background jobs, before the prompt.
            if !hasUnfinishedStatement {
                for notice in jobNotices(styled: DisplayStyle.enabled(for: STDERR_FILENO)) {
                    writeAll(STDERR_FILENO, notice + "\n")
                }
                willPrompt()
            }

            let prompt = hasUnfinishedStatement ? "…".styled(DisplayStyle.dim) + " " : prompt()
            switch Interpreter.whileWaiting({ editor.readLine(prompt: prompt) }) {
            case .eof:
                return finishInput(atPrompt: true)
            case .interrupted:
                discardUnfinishedStatement()
            case .line(let line):
                accept(line: line, atPrompt: true)
            }
        }
    }
}

extension Shell {
    /// Runs lines as they come, grouping those of an unfinished statement.
    private func runScript(nextLine: () -> String?) -> Int32 {
        while let line = nextLine() {
            if case .ran(_, let shouldStop) = accept(line: line, atPrompt: false), shouldStop {
                return lastStatus.number
            }
        }
        return finishInput(atPrompt: false)
    }
}

extension Shell {
    /// Takes the terminal as a job-control shell does, when standard input is one: waits to be in
    /// the foreground, ignores the job-control signals, and leads a process group of its own.
    /// Says whether it is a terminal.
    public func takeTerminal() -> Bool {
        guard isatty(terminal) != 0 else { return false }
        // If we were started in the background, wait until we're brought forward.
        while tcgetpgrp(terminal) != getpgrp() {
            kill(-getpgrp(), SIGTTIN)
        }
        for jobSignal in [SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU] {
            signal(jobSignal, SIG_IGN)
        }
        catchInterrupts()
        _ = setpgid(0, 0)  // Fails harmlessly if we're already a session leader.
        shellPgid = getpgrp()
        tcsetpgrp(terminal, shellPgid)
        tcgetattr(terminal, &shellModes)
        interactive = true
        return true
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
        let directory = Shell.abbreviated(FileManager.default.currentDirectoryPath)
        let failed = !lastStatus.succeeded
        let status = failed ? "[\(lastStatus.number)]".styled(DisplayStyle.red) + " " : ""
        return directory.styled(DisplayStyle.cyan) + " " + status
            + "❯".styled(failed ? DisplayStyle.red : DisplayStyle.green) + " "
    }
}

extension LineEditor.Completion {
    /// The editor's form of what the shell offers to complete the word being typed.
    init(_ completions: Shell.Completions) {
        self.init(
            start: completions.start,
            candidates: completions.candidates.map {
                LineEditor.Candidate(
                    replacement: $0.replacement,
                    suffix: $0.suffix,
                    display: $0.display,
                    description: $0.description
                )
            }
        )
    }
}
