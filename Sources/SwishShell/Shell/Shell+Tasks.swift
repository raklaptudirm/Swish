import SwishCore
import Foundation
import SwishKit

extension Shell {
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
                interpreter.report("run: no task named '\(task)' in \(path); `run` lists them")
                lastStatus = 127
                return
            }
            callAsCommand(function, named: "run \(task)", arguments)
        }
    }
}

extension Shell {
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
        let styled = DisplayStyle.enabled(for: stdoutFD)
        var text = "Usage: run <task> [<argument>...]\n\nTasks:\n"
        for task in tasks {
            let name = task.name.padding(toLength: width, withPad: " ", startingAt: 0)
            text += "  " + (styled ? name.styled(DisplayStyle.bold) : name) + (task.summary.isEmpty ? "" : "  " + task.summary) + "\n"
        }
        writeAll(stdoutFD, text)
        lastStatus = 0
    }
}

extension Shell {
    /// The name of the file `run` finds its tasks in.
    static let taskFileName = "Tasks.swish"

    /// The Swish executable, which `run` starts for a task file.
    nonisolated(unsafe) static var executablePath: String? = Bundle.main.executablePath

    /// `run task args…` as the program that runs it: this Swish, told to run
    /// `task` from the nearest Tasks.swish, here or in a parent directory.
    /// Its own process, so a task's `cd` or variables don't touch the shell.
    func taskCommand(_ arguments: [String], from start: String = FileManager.default.currentDirectoryPath) throws -> [String] {
        var directory = URL(fileURLWithPath: start).standardizedFileURL
        while true {
            let file = directory.appendingPathComponent(Shell.taskFileName).path
            if FileManager.default.fileExists(atPath: file) {
                guard let swish = Shell.executablePath else { throw RuntimeError("run: can't find the Swish executable") }
                return [swish, "--tasks", file] + arguments
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else {
                throw RuntimeError("run: no \(Shell.taskFileName) here or in a parent directory")
            }
            directory = parent
        }
    }
}
