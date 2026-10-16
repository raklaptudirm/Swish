import Foundation
@testable @_spi(Layer) import Swiit
@_spi(Shell) @_spi(Layer) @testable import SwishShell
import SwiitKit
import Testing

/// What a test host saw, and what it was told to answer: proof that the
/// interpreter reaches the world only through its `SwiitHost`.
private final class Recorder {
    /// Everything written, as `out: …` or `err: …`.
    var written: [String] = []
    var variables: [String: String] = [:]
    /// Asked at each interrupt check.
    var interrupt: () -> StopReason? = { nil }
}

/// A shell whose host records everything and runs nothing.
private func shellWithRecorder() -> (Shell, Recorder) {
    let shell = Shell()
    let recorder = Recorder()
    shell.interpreter.host = SwiitHost(
        name: "swish",
        output: OutputSink(write: { recorder.written.append("out: " + $0); return true }),
        error: OutputSink(write: { recorder.written.append("err: " + $0); return true }),
        interrupt: { recorder.interrupt() })
    shell.interpreter.bind("env", to: EnvironmentObject(access: EnvironmentAccess(
        get: { recorder.variables[$0] },
        all: { recorder.variables.sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) } },
        set: { recorder.variables[$0] = $1 })))
    return (shell, recorder)
}

@Test func outputAndErrorsGoToTheHost() {
    let (shell, recorder) = shellWithRecorder()
    // A bare value is shown as its debug form; an error is reported.
    #expect(shell.enter("1 + 1; 1 / 0") != 0)
    // The error shows the line it is in, with the place marked.
    #expect(recorder.written.count == 2 && recorder.written[0] == "out: 2\n")
    #expect(recorder.written[1].hasPrefix("err: swish: error: division by zero\n --> 1:8\n"))
    #expect(recorder.written[1].contains("1 | 1 + 1; 1 / 0"))
}

@Test func theEnvironmentIsTheHosts() {
    let (shell, recorder) = shellWithRecorder()
    recorder.variables = ["GREETING": "hi"]
    shell.enter(#"let a = env.GREETING; let b = env["MISSING"]; a; b; env.NEW = "x"; env.GREETING = nil; env.NEW"#)
    // Reads, writes and removals went to the host's variables, and the process was left alone.
    #expect(recorder.written == ["out: \"hi\"\n", "out: \"x\"\n"])
    #expect(recorder.variables == ["NEW": "x"])
}

@Test func theHostCanStopTheInterpreter() {
    let (shell, recorder) = shellWithRecorder()
    var checks = 0
    recorder.interrupt = {
        checks += 1
        return checks > 100 ? StopReason(code: 2) : nil
    }
    // An endless loop ends at the host's say-so, as ^C ends it in the shell.
    #expect(shell.execute("var n = 0; while true { n += 1 }") == 130)
    #expect(checks == 101)
}

@Test func aHostThatGrantsNothingRefusesPlainly() {
    // The sandbox: output goes where it's told, and there is no `env` to read
    // or write unless the host registers one. (Commands, `$(…)` and `async`
    // are refused at the parser: an interpreter with no shell syntax plugged
    // in doesn't read them; see SwiftDialectTests.)
    let (shell, recorder) = shellWithRecorder()
    shell.interpreter.scopes[0].bindings["env"] = nil
    #expect(shell.execute("let h = env.HOME; h ?? \"none\"") != 0)
    #expect(shell.execute(#"env.X = "1""#) != 0)
    #expect(recorder.written.count == 2)
    #expect(recorder.written[0].hasPrefix("err: swish: error: no variable named 'env'\n --> 1:9\n"))
    #expect(recorder.written[1] == "err: swish: env.X: command not found\n")
}

/// Runs a file of these lines in a shell whose errors are recorded, and gives the errors.
private func errorsOfScript(_ lines: [String]) throws -> (errors: String, status: Int32, path: String) {
    let (shell, recorder) = shellWithRecorder()
    let path = NSTemporaryDirectory() + "diagnostic-\(UUID().uuidString).swish"
    try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: path) }
    let status = try onLargeStack { shell.runScript(at: path) }
    return (recorder.written.filter { $0.hasPrefix("err: ") }.joined(), status, path)
}

@Test func anErrorShowsTheLineItIsInWithThePlaceMarked() throws {
    // A run-time error: the statement it happened in, in the file, with the line and column.
    let runtime = try errorsOfScript(["print(1)", "let xs = [1, 2]", "print(xs[7])", "print(2)"])
    #expect(runtime.errors.contains("error: index 7 is out of range for a list of 2\n --> \(runtime.path):3:1\n"))
    #expect(runtime.errors.contains("3 | print(xs[7])\n  | ^^^^^^^^^^^^"))
    // Inside a function: where it was called from too.
    let called = try errorsOfScript(["func half(_ n: Int) -> Int {", "    let h = 10 / n", "    return h", "}", "print(half(0))"])
    #expect(called.errors.contains("note: in 'half', called from here\n --> \(called.path):5:1"))
    #expect(called.errors.contains(" --> \(called.path):2:5\n"))
    // A type error: the part of the line that is wrong.
    let typed = try errorsOfScript(["let a = 1", #"let x: Int = "s""#])
    #expect(typed.status == 2)
    #expect(typed.errors.contains(" --> \(typed.path):2:14\n"))
    #expect(typed.errors.contains("2 | let x: Int = \"s\"\n  |              ^^^"))
    // A syntax error: the token.
    let syntax = try errorsOfScript(["func f() {", "  print(1", "}"])
    #expect(syntax.errors.contains("syntax error: expected ')'"))
    #expect(syntax.errors.contains(" --> \(syntax.path):2:"))
}

@Test func whatFollowsACommandSubstitutionWithAClosureIsStillRead() throws {
    // SwiftParser takes `$(echo hi | map { … })` for a Swift call that ends at the closure and leaves the rest of the
    // line out of every statement; the layer reads on from where its own text ended.
    let shell = Shell()
    let cases: [(source: String, statements: Int)] = [
        (#"let a = $(echo hi | map { "x" }); touch /tmp/never; print(a)"#, 3),
        ("let a = $(echo hi | map { $0 })\nprint(a)\nprint(a)", 3),
        (#"print($(echo hi | map { "x" })); print(1)"#, 2),
    ]
    for (source, statements) in cases {
        switch shell.interpreter.parse(source) {
        case .success(let program): #expect(program.statements.count == statements, "\(source)")
        case .failure(let error): Issue.record("\(source): \(error)")
        }
    }
}

@Test func anUnknownOptionSaysWhichSideOfAShadowedCommandItIs() throws {
    // `ps` is Swish's function, not the program: a flag it lacks says how to reach the program, and never runs it instead.
    let (shell, recorder) = shellWithRecorder()
    #expect(shell.execute("ps -ax") != 0)
    #expect(recorder.written.contains { $0.contains("unknown option -a in -ax; this is Swish's ps: ^ps runs the program") })
}

@Test func anInvalidEscapeSaysWhatToWriteInstead() throws {
    let (shell, recorder) = shellWithRecorder()
    #expect(shell.execute(#"print("a\|b")"#) != 0)
    #expect(recorder.written.contains { $0.contains(#"write \\ for a backslash, or use single quotes"#) })
}
