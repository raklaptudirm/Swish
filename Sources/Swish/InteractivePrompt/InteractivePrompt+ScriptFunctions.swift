import Foundation
import Swiit
import SwishShell

// What the prompt adds to the language: the actions a config hooks in, and the history.

extension InteractivePrompt {
    /// Declares `beforePrompt`, `onDirectoryChange` and `history()` for scripts.
    func declareScriptFunctions() {
        do {
            try shell.interpreter.declare(
                InteractivePrompt.declarations,
                bodies: [
                    "beforePrompt": { [unowned self] arguments in
                        if let action = arguments["action"] { beforePromptActions.append(action) }
                        return .nothing
                    },
                    "onDirectoryChange": { [unowned self] arguments in
                        if let action = arguments["action"] {
                            directoryChangeActions.append(action)
                        }
                        return .nothing
                    },
                    "history": { [unowned self] _ in Value(historyEntries.map { Value($0) }) },
                ]
            )
        } catch {
            shell.report("error: \(error)")
        }
    }

    /// What's been entered at the prompt: this shell's history, or the history file's outside the
    /// interactive shell.
    private var historyEntries: [String] {
        isRunning ? editor.history.entries : History(path: History.defaultPath).entries
    }

    private static let declarations = """
        /// Runs `action` each time a prompt is about to be drawn, after those added before it: what a tool
        /// that keeps the shell up to date hooks into, as direnv does with
        /// `beforePrompt { try env.load(fromShell: #"eval "$(direnv export bash)""#) }`. One that fails is
        /// reported, and the prompt drawn.
        func beforePrompt(_ action: @escaping () throws -> Void)

        /// Runs `action` with the directory it was and the one it is, when the working directory has
        /// changed since the last prompt, before that prompt's own `beforePrompt` actions: however it
        /// changed, by `cd` or by a script.
        func onDirectoryChange(_ action: @escaping (_ from: FilePath, _ to: FilePath) throws -> Void)

        /// What you've entered at the prompt, oldest first.
        func history() -> [String]
        """
}
