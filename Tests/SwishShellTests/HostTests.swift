@testable import SwishCore
@testable import SwishShell
import SwishKit
import Testing

/// What a test host saw, and what it was told to answer: proof that the
/// interpreter reaches the world only through its `SwishHost` and, for the
/// shell's own constructs, its `ShellLayer`.
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
    shell.interpreter.host = SwishHost(
        output: OutputSink(write: { recorder.written.append("out: " + $0); return true }),
        error: OutputSink(write: { recorder.written.append("err: " + $0); return true }),
        interrupt: { recorder.interrupt() })
    shell.interpreter.bind("env", to: EnvironmentObject(access: EnvironmentAccess(
        get: { recorder.variables[$0] },
        all: { recorder.variables.sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) } },
        set: { recorder.variables[$0] = $1 })))
    shell.interpreter.shellLayer = ShellLayer(
        commands: CommandAccess(
            jobs: { [] },
            await: { _, _ in .nothing },
            callSequenceMethod: { _, _, _ in .nothing }),
        importPlugin: { _, _ in },
        history: { [] },
        columns: [:])
    return (shell, recorder)
}

@Test func outputAndErrorsGoToTheHost() {
    let (shell, recorder) = shellWithRecorder()
    // A bare value is shown as its debug form; an error is reported.
    #expect(shell.execute("1 + 1; 1 / 0") != 0)
    #expect(recorder.written == ["out: 2\n", "err: swish: error: division by zero\n"])
}

@Test func theEnvironmentIsTheHosts() {
    let (shell, recorder) = shellWithRecorder()
    recorder.variables = ["GREETING": "hi"]
    shell.execute(#"let a = env.GREETING; let b = env["MISSING"]; a; b; env.NEW = "x"; env.GREETING = nil; env.NEW"#)
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
    #expect(recorder.written == [
        "err: swish: syntax error: no variable named 'env'\n",
        "err: swish: env.X: command not found\n",
    ])
}
