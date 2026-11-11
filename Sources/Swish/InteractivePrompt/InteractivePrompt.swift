import Foundation
import Swiit
import SwishShell

/// The shell at a prompt: a line editor over a `Shell`, which reads a line, runs it and draws the
/// next prompt until the input ends. The shell knows nothing of the editor; they meet through the
/// shell's public interface.
final class InteractivePrompt: @unchecked Sendable {
    let shell: Shell
    let editor = LineEditor()

    /// What runs before each prompt, in the order it was added (`beforePrompt`).
    var beforePromptActions: [Value] = []

    /// What runs when the working directory has changed since the last prompt (`onDirectoryChange`).
    var directoryChangeActions: [Value] = []

    /// The working directory when the last prompt was drawn, to tell when it has changed.
    var directoryAtLastPrompt: String?

    /// Whether the editor's own history is the one to read, as it is once the prompt is running.
    var isRunning = false

    init(shell: Shell) {
        self.shell = shell
    }

    /// Runs the read-eval loop until end of input or `exit`. Where standard input is not a terminal,
    /// it runs the lines as a script.
    func run() -> Int32 {
        guard shell.takeTerminal() else { return runFromStandardInput() }
        isRunning = true
        editor.history = History(path: History.defaultPath)
        editor.continuationPrompt = continuationPrompt

        // These run while a line is read, when nothing else runs.
        editor.isComplete = { [unowned self] text in !shell.isUnfinished(text) }
        editor.highlight = { [unowned self] text in
            shell.highlighting(of: text).paintedStyles(count: text.count).map { $0?.escape }
        }
        editor.complete = { [unowned self] text, cursor in
            shell.completions(for: text, cursor: cursor).map(LineEditor.Completion.init)
        }
        loadConfiguration()

        while true {
            if !shell.hasUnfinishedStatement {
                announceJobs()
                willPrompt()
            }

            let prompt = shell.hasUnfinishedStatement ? continuationPrompt : self.prompt()
            switch Interpreter.whileWaiting({ editor.readLine(prompt: prompt) }) {
            case .eof:
                return shell.finishInput(atPrompt: true)
            case .interrupted:
                shell.discardUnfinishedStatement()
            case .line(let line):
                shell.accept(line: line, atPrompt: true)
            }
        }
    }

    /// The prompt of a line that continues an unfinished statement.
    private var continuationPrompt: String {
        "…".styled(DisplayStyle.dim) + " "
    }

    /// Finished and stopped background jobs, before the prompt.
    private func announceJobs() {
        for notice in shell.jobNotices(styled: DisplayStyle.enabled(for: STDERR_FILENO)) {
            Terminal.write(notice + "\n", to: STDERR_FILENO)
        }
    }

    /// Runs the lines of standard input as they come, grouping those of an unfinished statement.
    private func runFromStandardInput() -> Int32 {
        while let line = Interpreter.whileWaiting({ Swift.readLine() }) {
            if case .ran(_, let shouldStop) = shell.accept(line: line, atPrompt: false), shouldStop
            {
                return shell.lastStatus.number
            }
        }
        return shell.finishInput(atPrompt: false)
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
