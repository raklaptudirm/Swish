@testable import SwishCore
import SwishKit
import Testing

// The core on its own: the target builds and runs without the shell.

/// What a script wrote and how it ended, run on an `Interpreter` alone: no
/// `Shell`, no layer, only a host that collects output.
private func runOnTheCore(_ source: String) -> (output: String, problem: String?) {
    var output = ""
    let host = SwishHost(output: OutputSink(write: { output += $0; return true }),
                         error: OutputSink(write: { output += "err: " + $0; return true }))
    let interpreter = Interpreter(host: host, limits: Limits())
    // As at a prompt: a bare value is shown.
    interpreter.echoesValues = true
    switch interpreter.parse(source) {
    case .failure(let error):
        return (output, "syntax error: \(error)")
    case .success(let program):
        do {
            let checked = try TypeChecker(interpreter: interpreter).check(program)
            _ = try interpreter.run(checked)
            return (output, nil)
        } catch let error as TypeError {
            return (output, "error: \(error.message)")
        } catch {
            return (output, "error: \(error)")
        }
    }
}

@Test func theCoreRunsSwiftWithoutAShell() {
    let (output, problem) = runOnTheCore("""
    let xs = [3, 1, 2]
    xs.sorted()
    struct P { var x: Int; static let origin = P(x: 0) }
    P(x: 1)
    P.origin
    func double(_ n: Int) -> Int { n * 2 }
    xs.map { double($0) }
    """)
    #expect(problem == nil)
    #expect(output == "[1, 2, 3]\nP(x: 1)\nP(x: 0)\n[6, 2, 4]\n")
}

@Test func theCoreRefusesWhatItWasNotGiven() {
    // Shell syntax doesn't parse, and the environment, which no layer gives, reads as empty.
    #expect(runOnTheCore("git status").problem?.contains("no variable named 'git'") == true)
    #expect(runOnTheCore("let h = $(echo hi)").problem?.contains("runs commands") == true)
    let (output, problem) = runOnTheCore(#"let h = env.HOME; h ?? "none""#)
    #expect(problem == nil)
    #expect(output == "\"none\"\n")
}

@Test func theCoreHasTheStandardLibraryButNotTheShellsFunctions() {
    // Conversions are the core's; `ls`, `ps` and `pwd` reach the file system and the process.
    let (output, problem) = runOnTheCore(#"[1, 2].map { $0 * 2 }; try from(.json, ["[1, 2]"])"#)
    #expect(problem == nil)
    #expect(output == "[2, 4]\n[1, 2]\n")
    for name in ["ls", "ps", "pwd", "history", "readLine"] {
        #expect(runOnTheCore("\(name)()").problem?.contains("no function named '\(name)'") == true, "\(name)")
    }
}
