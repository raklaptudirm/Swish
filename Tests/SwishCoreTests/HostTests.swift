@testable import SwishCore
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
    /// Programs the host says exist, what running a pipeline gives, and
    /// what a `$(…)` is told it gathered.
    var programs: Set<String> = []
    var pipelineStatus: Int32 = 0
    var captured = ""
    var ranPipelines: [String] = []
}

/// A shell whose host records everything and runs nothing.
private func shellWithRecorder() -> (Shell, Recorder) {
    let shell = Shell()
    let recorder = Recorder()
    shell.host = SwishHost(
        output: OutputSink(write: { recorder.written.append("out: " + $0); return true }),
        error: OutputSink(write: { recorder.written.append("err: " + $0); return true }),
        interrupt: { recorder.interrupt() })
    shell.shellLayer = ShellLayer(
        environment: EnvironmentAccess(
            get: { recorder.variables[$0] },
            all: { recorder.variables.sorted { $0.key < $1.key }.map { (name: $0.key, value: $0.value) } },
            set: { recorder.variables[$0] = $1 }),
        commands: CommandAccess(
            capture: { _ in recorder.captured },
            hasProgram: { recorder.programs.contains($0) },
            run: { node, _ in recorder.ranPipelines.append(node.source); return recorder.pipelineStatus },
            start: { node, _ in recorder.ranPipelines.append("async " + node.source); return .nothing },
            jobs: { [] }))
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

@Test func commandsRunThroughTheHost() {
    let (shell, recorder) = shellWithRecorder()
    recorder.pipelineStatus = 7
    recorder.captured = "gathered"
    #expect(shell.execute("build --fast") == 7)
    shell.execute("let x = $(whatever); x.text")
    shell.execute("async sleep 1")
    #expect(recorder.ranPipelines == ["build --fast", "async sleep 1"])
    #expect(recorder.written == ["out: \"gathered\"\n"])
}

@Test func theCheckerAsksTheHostWhichProgramsExist() {
    // `sorted` is a method, so alone it's an error unless a program has the name.
    #expect(Shell().execute("sorted") != 0)
    let (shell, recorder) = shellWithRecorder()
    recorder.programs = ["sorted"]
    #expect(shell.execute("sorted") == 0)
    #expect(recorder.ranPipelines == ["sorted"])
}

@Test func aHostThatGrantsNothingRefusesPlainly() {
    // The sandbox: output goes where it's told, `env` is empty and read-only
    // nowhere, and commands, `$(…)` and jobs can't run.
    let (shell, recorder) = shellWithRecorder()
    shell.shellLayer = nil
    #expect(shell.execute("let h = env.HOME; h ?? \"none\"") == 0)
    #expect(shell.execute(#"env.X = "1""#) != 0)
    #expect(shell.execute("make") != 0)
    #expect(shell.execute("$(make)") != 0)
    #expect(shell.execute("async make") != 0)
    #expect(recorder.written == [
        "out: \"none\"\n",
        "err: swish: error: the environment isn't available here\n",
        "err: swish: error: commands aren't available here\n",
        "err: swish: error: commands aren't available here\n",
        "err: swish: error: commands aren't available here\n",
    ])
}
