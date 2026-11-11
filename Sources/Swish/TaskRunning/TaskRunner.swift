import Foundation
import Swiit
import SwishEngine

/// Running a task: a function in a `Tasks.swish`, started by `run` as a Swish of its own so that a
/// task's `cd` or variables don't touch the shell it was run from.
struct TaskRunner {
    let shell: Shell

    /// The name of the file `run` finds its tasks in.
    static let taskFileName = "Tasks.swish"

    /// Adds the `run` builtin to the shell.
    func registerRunBuiltin() {
        shell.register(
            .program(
                name: "run",
                usage: "run [<task> [<argument>...]]",
                summary:
                    "Runs a task: a function in the nearest Tasks.swish, here or in a parent directory, in a Swish of its own. Alone, lists the tasks."
            ) { _, arguments in
                try TaskRunner.command(for: arguments)
            }
        )
    }

    /// Runs a task file: its top level first, with no `args`, then the function named `task` with
    /// `arguments` as its command line. No task (or `--help`) lists them.
    func run(at path: String, task: String?, arguments: [String]) -> Int32 {
        nonisolated(unsafe) var failure: Int32?
        let status = shell.runScript(at: path, arguments: []) { file in
            guard let task, task != "--help", task != "-h" else {
                listTasks(in: file)
                return
            }
            guard file.call(task, as: "run \(task)", arguments: arguments) else {
                shell.report("run: no task named '\(task)' in \(path); `run` lists them")
                failure = 127
                return
            }
        }
        return failure ?? status
    }

    /// Each task, with the first sentence of its doc comment.
    private func listTasks(in file: Shell.ScriptFile) {
        var seen: Set<String> = []
        let tasks: [(name: String, summary: String)] = file.functions.compactMap {
            guard !$0.name.hasPrefix("_"), seen.insert($0.name).inserted else { return nil }
            return ($0.name, $0.summary?.firstSentence ?? "")
        }
        guard !tasks.isEmpty else {
            Terminal.write("No tasks: a task is a function in the file.\n", to: STDOUT_FILENO)
            return
        }

        let width = tasks.map(\.name.count).max()!
        let styled = DisplayStyle.enabled(for: STDOUT_FILENO)
        var text = "Usage: run <task> [<argument>...]\n\nTasks:\n"
        for task in tasks {
            let name = task.name.padding(toLength: width, withPad: " ", startingAt: 0)
            text +=
                "  " + (styled ? name.styled(DisplayStyle.bold) : name)
                + (task.summary.isEmpty ? "" : "  " + task.summary) + "\n"
        }
        Terminal.write(text, to: STDOUT_FILENO)
    }

    /// `run task args…` as the program that runs it: this Swish, told to run `task` from the
    /// nearest Tasks.swish, here or in a parent directory.
    static func command(
        for arguments: [String],
        from start: String = FileManager.default.currentDirectoryPath
    ) throws -> [String] {
        var directory = URL(fileURLWithPath: start).standardizedFileURL
        while true {
            let file = directory.appendingPathComponent(taskFileName).path
            if FileManager.default.fileExists(atPath: file) {
                guard let swish = Bundle.main.executablePath else {
                    throw TaskError("run: can't find the Swish executable")
                }
                return [swish, "--tasks", file] + arguments
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw TaskError("run: no \(taskFileName) here or in a parent directory")
            }
            directory = parent
        }
    }
}

/// Why `run` can't start a task.
struct TaskError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
