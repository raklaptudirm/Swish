import Foundation
import Swiit
import SwishShell
import Testing

@testable import Swish

@Test func tasksRunFromTheNearestTaskFile() throws {
    let directory = NSTemporaryDirectory() + "swish-tasks-" + UUID().uuidString
    try FileManager.default.createDirectory(
        atPath: directory + "/sub",
        withIntermediateDirectories: true
    )
    let file = directory + "/Tasks.swish"
    let tasks = """
        let greeting = "hi"
        func _helper() -> String { greeting }
        /// Says hello. More detail here.
        func hello(name: String = "you", loud: Bool = false) {
            var shown = name
            if loud { shown = name.uppercased() }
            echo "\\(_helper()) \\(shown) \\(args.count)"
        }
        /// Fails.
        func broken() {
            try! false
            echo never
        }
        """
    try tasks.write(toFile: file, atomically: true, encoding: .utf8)

    // What a task prints goes to standard output, so it is read from a pipe.
    func run(_ task: String?, _ arguments: [String] = []) throws -> (String, Int32) {
        let shell = Shell()
        var status: Int32 = 0
        let printed = try capturingStandardOutput {
            status = TaskRunner(shell: shell).run(at: file, task: task, arguments: arguments)
        }
        return (printed, status)
    }
    // The top level runs first; arguments are the function's, not `args`.
    #expect(try run("hello", ["--name", "Rak", "--loud"]) == ("hi RAK 0\n", 0))
    #expect(try run("hello") == ("hi you 0\n", 0))
    // Alone: the tasks, with their doc comments' first sentence, helpers left out.
    let (list, status) = try run(nil)
    #expect(
        status == 0 && list.contains("hello   Says hello.\n") && list.contains("broken  Fails.\n")
            && !list.contains("_helper")
    )
    #expect(try run("broken").1 == 1)
    #expect(try run("missing").1 == 127)

    // `run` finds the file from a subdirectory, and runs it as its own Swish.
    let command = try TaskRunner.command(for: ["hello", "--loud"], from: directory + "/sub")
    #expect(Array(command.dropFirst()) == ["--tasks", file, "hello", "--loud"])
}
