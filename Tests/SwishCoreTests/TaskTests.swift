@testable import SwishCore
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

@Test func tasksRunFromTheNearestTaskFile() throws {
    let shell = Shell()
    let directory = try output("mktemp -d", in: shell).trimmingCharacters(in: .newlines)
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
    func run(_ task: String?, _ arguments: [String] = []) throws -> (String, Int32) {
        let tasks = Shell()
        let printed = try onLargeStack { try tasks.capturing { _ = tasks.runTasks(at: file, task: task, arguments: arguments) } }
        return (printed, tasks.lastStatus)
    }
    // The top level runs first; arguments are the function's, not `args`.
    #expect(try run("hello", ["--name", "Rak", "--loud"]) == ("hi RAK 0\n", 0))
    #expect(try run("hello") == ("hi you 0\n", 0))
    // Alone: the tasks, with their doc comments' first sentence, helpers left out.
    let (list, status) = try run(nil)
    #expect(status == 0 && list.contains("hello   Says hello.\n") && list.contains("broken  Fails.\n") && !list.contains("_helper"))
    #expect(try run("broken").1 == 1)
    #expect(try run("missing").1 == 127)

    // `run` finds the file from a subdirectory, and runs it as its own Swish.
    shell.execute("mkdir \(directory)/sub")
    let command = try shell.taskCommand(["hello", "--loud"], from: directory + "/sub")
    #expect(Array(command.dropFirst()) == ["--tasks", file, "hello", "--loud"])
}
