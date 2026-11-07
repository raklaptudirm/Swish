import Foundation
import Swiit

@testable import SwishShell

// What the tests need to know about the process they run in. In a file of
// its own: Foundation can't be imported next to Testing here.

/// This process's id.
func currentProcessID() -> Int {
    Int(ProcessInfo.processInfo.processIdentifier)
}

/// What `source` says when it fails, as written to the shell's error output (its first line), or
/// nil if it ran without a word: a failure of a pipeline's stage is found when the pipeline starts.
func errorText(_ source: String, in shell: Shell = Shell()) -> String? {
    guard let pipe = makePipe() else { return nil }
    let collector = OutputCollector(reading: pipe.read)
    let saved = shell.stderrFD
    shell.stderrFD = pipe.write
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    shell.stderrFD = saved
    close(pipe.write)
    let text = Interpreter.whileWaiting { collector.finish() }
    return text.isEmpty
        ? nil : String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
}

/// What stops `source` before it runs in `shell`, or nil if it checks: "syntax error", or the type
/// error's message.
func checkMessage(_ source: String, in shell: Shell) -> String? {
    switch shell.prepare(source) {
    case .success: return nil
    case .failure(let diagnostic):
        return diagnostic.isSyntax ? "syntax error" : diagnostic.message
    }
}

/// Runs `body` on a thread with a stack large enough for the interpreter's recursion, and waits for
/// it.
func onLargeStack<T>(_ body: @escaping () throws -> T) throws -> T {
    nonisolated(unsafe) var result: Result<T, any Error>?
    nonisolated(unsafe) let body = body
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        result = Result { try body() }
        done.signal()
    }
    thread.stackSize = 1 << 30
    thread.start()
    done.wait()
    return try result!.get()
}

/// What `body` makes the shell write to its error output.
func errorOutput(of shell: Shell, _ body: () -> Void) -> String {
    guard let pipe = makePipe() else { return "" }
    let collector = OutputCollector(reading: pipe.read)
    let saved = shell.stderrFD
    shell.stderrFD = pipe.write
    body()
    shell.stderrFD = saved
    close(pipe.write)
    return Interpreter.whileWaiting { collector.finish() }
}

/// An environment variable of this process, or nil.
func variable(_ name: String) -> String? {
    getenv(name).map { String(cString: $0) }
}

/// Sets an environment variable of this process.
func setVariable(_ name: String, _ value: String) {
    setenv(name, value, 1)
}

/// A new directory of its own for a test, removed when `body` is done, given to it.
func withTemporaryDirectory(_ body: (String) throws -> Void) rethrows {
    let directory = FileManager.default.temporaryDirectory.path + "/swish-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    try body(directory)
}

/// Writes `text` to a new file at `path`.
func writeFile(_ path: String, _ text: String) {
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
}
