import Foundation
import Swiit
import SwishEngine
import SystemPackage

// What happens as each prompt is drawn: the actions the config added (`beforePrompt`,
// `onDirectoryChange`), and what the terminal is told of where the shell is.

extension InteractivePrompt {
    /// Runs before a prompt is drawn. A failing action is reported, and the others still run.
    /// `workingDirectory` reads where the shell is.
    func willPrompt(
        workingDirectory: () -> String = { FileManager.default.currentDirectoryPath }
    ) {
        // What the other shells sharing the history file ran since, for ↑ and ^R.
        editor.history.takeOthersEntries()

        let directory = workingDirectory()
        if let previous = directoryAtLastPrompt, previous != directory {
            for action in directoryChangeActions {
                run(
                    action,
                    named: "onDirectoryChange",
                    [Value(FilePath(previous)), Value(FilePath(directory))]
                )
            }
        }
        for action in beforePromptActions { run(action, named: "beforePrompt", []) }

        // The actions may have changed it; what is drawn is where the shell is now.
        let now = workingDirectory()
        directoryAtLastPrompt = now
        tellTerminal(directory: now)
    }

    private func run(_ action: Value, named name: String, _ arguments: [Value]) {
        do {
            // An action before the prompt isn't a command.
            _ = try shell.keepingStatus { try shell.interpreter.call(action, with: arguments) }
        } catch {
            shell.report("\(name): \(error)")
        }
    }

    /// The working directory, as a terminal reads it (OSC 7: a new tab or split opens there), and
    /// the window's title, the directory too (OSC 2). Only a terminal is told, and not a dumb one.
    private func tellTerminal(directory: String) {
        let output = STDERR_FILENO
        guard isatty(output) != 0, ProcessInfo.processInfo.environment["TERM"] != "dumb" else {
            return
        }

        let host = ProcessInfo.processInfo.hostName
        // A path in a URL: everything but its unreserved characters and slashes is escaped.
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#;"))
        let path = directory.addingPercentEncoding(withAllowedCharacters: allowed) ?? directory
        Terminal.write("\u{1B}]7;file://\(host)\(path)\u{07}", to: output)
        Terminal.write("\u{1B}]2;\(InteractivePrompt.abbreviated(directory))\u{07}", to: output)
    }
}
