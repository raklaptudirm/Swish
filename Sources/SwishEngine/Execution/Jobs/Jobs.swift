import Foundation
import Swiit

/// A pipeline of processes, one running in the foreground or a job in the
/// background (from `async` or ^Z), or Swish code running as a task of its
/// own (`async f()`). Jobs in the background are values: `await` brings one
/// to the foreground and waits for it, and `resume()` and `cancel()` act on it.
final class Job: ScriptConvertible, Presentable, Tabular, CustomStringConvertible,
    CustomDebugStringConvertible, @unchecked Sendable
{
    /// Where a job is in its life.
    enum State: String {
        case running, stopped, done
    }

    /// Its number in `jobs`, from when it first went to the background; 0
    /// for a foreground job that never has.
    var id = 0
    let source: String
    /// 0 when the job has no process group of its own (non-interactive mode).
    var pgid: pid_t = 0
    /// Processes not yet reaped, in pipeline order.
    var running: [pid_t] = []
    /// nil when the last command failed to spawn.
    var lastPid: pid_t?
    /// How the pipeline's last command ended.
    var status = Status.success
    var state = State.running
    var cancelled = false
    /// Whether its latest change (stopping, or finishing) has been reported.
    var reported = false
    /// The terminal as the job left it when it stopped, as vim does, so it
    /// gets it back the same way.
    var modes: termios?
    /// For `async $(…)`, and a task: its output, read as it comes.
    var capture: OutputCollector?
    /// Swish code running as a task of its own, rather than processes.
    var task: ScriptTask?
    /// `async $(…)`: `await` gives its Output, not what its task gave.
    var givesOutput = false
    /// Its output has been written where the one who awaited it writes (or is being).
    var relayed = false
    /// Once it's done: its output and how it exited.
    private(set) var output: Output?
    unowned let runner: CommandRunner

    init(source: String, runner: CommandRunner) {
        self.source = source
        self.runner = runner
    }

    func finish() {
        guard state != .done else { return }
        // A task ended as it gave a value or threw.
        if let result = task?.result, case .failure = result { status = .exited(1) }
        var text = capture?.finish() ?? ""
        while text.last == "\n" { text.removeLast() }
        output = Output(text: text, status: status)
        state = .done
        capture = nil
    }

    /// Sends a signal to every process in the job.
    func send(_ signal: Int32) {
        // A task isn't processes: cancelling it is asking it to stop.
        if let task {
            if signal == SIGTERM { task.cancel() }
            return
        }
        if pgid > 0 {
            kill(-pgid, signal)
        } else {
            running.forEach { kill($0, signal) }
        }
    }

    /// `job.lines()`: its output a line at a time, as the lines arrive: a stream to read
    /// while the job runs (`async $(tail -f log)`), which waits for the next
    /// line, or ends when the output does. Reading goes on from the last line
    /// read, and once the job is done, from what its output has left.
    var lines: Value {
        guard let collector = capture else {
            return runner.preludeTypes.stream(of: (output?.lines ?? []).map { Value($0) })
        }
        return runner.preludeTypes.stream { [unowned self] in
            while true {
                switch Interpreter.whileWaiting({ collector.nextLine(timeout: 0.05) }) {
                case .line(let line): return Value(line)
                case .end: return nil
                // Waiting for a line is where Ctrl-C has to be noticed.
                case .pending: try runner.interpreter.checkForStop()
                }
            }
        }
    }

    // MARK: What scripts read of it

    static let id = Symbol.ID(hostType: "Job")

    /// What a table of jobs starts with: the state shown as it's going.
    static let columns: [DisplayColumn] = [
        "id", DisplayColumn("state", styledBy: "state"), "command",
    ]

    /// How it's going, as scripts see it: a job that ended because it was cancelled is
    /// `cancelled`, not `done`.
    var scriptState: JobState {
        switch state {
        case .running: .running
        case .stopped: .stopped
        case .done: cancelled ? .cancelled : .done
        }
    }

    /// The value of each of a job's members, which are what the prelude's `protocol Job` declares.
    static let members: [(name: String, value: @Sendable (Job) -> Value)] = [
        ("id", { Value($0.id) }),
        ("command", { Value($0.source) }),
        ("state", { $0.scriptState.value }),
        ("pids", { Value($0.running.map { Value(Int($0)) }) }),
        ("output", { $0.output.map { Value.output($0) } ?? .nothing }),
        // A method, as it's not data: a table or `to json` of jobs can't read it.
        ("lines", { job in method("lines") { [unowned job] in job.lines } }),
        ("resume", { job in method("resume") { [unowned job] in job.runner.resume(job) } }),
        ("cancel", { job in method("cancel") { [unowned job] in job.runner.cancel(job) } }),
    ]

    var memberNames: [String]? { Job.members.map(\.name) }

    func member(_ name: String) -> Value? {
        Job.members.first { $0.name == name }?.value(self)
    }

    private static func method(_ name: String, _ body: @escaping @Sendable () -> Void) -> Value {
        method(name) { () -> Value in
            body()
            return .nothing
        }
    }

    private static func method(_ name: String, _ body: @escaping @Sendable () -> Value) -> Value {
        Value(HostSymbol.function(name: name) { _ in body() })
    }

    /// `[1] running  make`, in pieces to color: the number dim, the state
    /// by how it's going.
    var segments: [Segment] {
        let (label, style): (String, DisplayStyle?) =
            switch state {
            case .running: ("running", DisplayStyle.green)
            case .stopped: ("stopped", DisplayStyle.yellow)
            case .done where cancelled: ("cancelled", DisplayStyle.dim)
            case .done:
                switch status {
                case .success: ("done", nil)
                case .exited(let code): ("failed (\(code))", DisplayStyle.red)
                case .signaled(let signal):
                    (
                        "failed (\(String(cString: strsignal(signal)).lowercased()))",
                        DisplayStyle.red
                    )
                }
            }
        return [("[\(id)]", DisplayStyle.dim), (" ", nil), (label, style), ("  " + source, nil)]
    }

    var styledSegments: [Segment]? { segments }

    var description: String { line(styled: false) }

    func line(styled: Bool) -> String {
        segments.map { $0.text.styled($0.style, styled) }.joined()
    }

    /// A job on its own reads as `jobs` announces it: `[1] running  make`.
    var debugDescription: String { description }
}

/// Stopping a job you were awaiting (^Z) leaves the line; it's in `jobs`.
struct JobSuspended: Error {}

extension CommandRunner {
    /// Starts a pipeline of programs in the background (`async`), capturing
    /// its output if asked (`async $(…)`).
    func startJob(_ stages: [Stage], source: String, capture: Bool) throws -> Job {
        // Swish functions in it: the pipeline runs as a task of its own.
        guard stages.allSatisfy(\.isExternal) else {
            let job = try startTask(source: source) { [unowned self] in
                statusValue(try runPipeline(stages, source: source, display: true))
            }
            // A command's job, as any command's: `await` gives its Output.
            job.givesOutput = true
            return job
        }
        let job = Job(source: source, runner: self)
        var output = stdoutFD
        if capture {
            guard let pipe = makePipe() else { throw RuntimeError("pipe: \(errorMessage(errno))") }
            job.capture = OutputCollector(reading: pipe.read)
            output = pipe.write
        }
        defer { if capture { close(output) } }

        var input: Int32 = -1
        for (index, stage) in stages.enumerated() {
            guard case .external(let argv, _, let redirects, let environment) = stage else {
                continue
            }
            let isLast = index == stages.count - 1
            var next: (read: Int32, write: Int32)?
            if !isLast {
                guard let pipe = makePipe() else {
                    if input >= 0 { close(input) }
                    throw RuntimeError("pipe: \(errorMessage(errno))")
                }
                next = pipe
            }
            // Its own process group, but not the terminal: reading it stops
            // the job until it's awaited.
            let result = launch(
                argv,
                redirects: redirects,
                environment: environment,
                input: input,
                output: next?.write ?? output,
                pgid: jobControl.isInteractive ? job.pgid : -1,
                foreground: false
            )
            if input >= 0 { close(input) }
            if let next { close(next.write) }
            input = next?.read ?? -1
            switch result {
            case .success(let pid):
                if jobControl.isInteractive && job.pgid == 0 { job.pgid = pid }
                job.running.append(pid)
                if isLast { job.lastPid = pid }
            case .failure(let failure):
                services.report(failure.message)
                if isLast { job.status = .exited(failure.status) }
            }
        }
        if job.running.isEmpty {
            job.finish()
        } else {
            jobControl.adopt(job)
        }
        return job
    }

    /// Brings a job to the foreground and waits for it (`await`). If it's
    /// stopped again with ^Z, it goes back to `jobs` and the line is left.
    func awaitJob(_ job: Job) throws -> Output {
        if let task = job.task {
            // Awaiting brings a task to the foreground, and what it printed with it: what it has
            // printed so far, and the rest as it prints. (A task that gives an Output keeps it for
            // the value.)
            var relay: Relay?
            if !job.givesOutput, !job.relayed {
                job.relayed = true
                if let collector = job.capture {
                    relay = collector.relay(to: stdoutFD)
                } else if let text = job.output?.text, !text.isEmpty {
                    writeAll(stdoutFD, text + "\n")
                }
            }

            let result = Result { () throws(Diagnostic) -> Value in try interpreter.join(task) }
            job.finish()
            relay?.stop()
            relay?.wait()

            jobControl.jobs.removeAll { $0 === job }

            if case .failure(let error) = result, !job.givesOutput {
                // How it ended is the awaiting task's error, not a reason for it to stop too.
                if error.isRuntime {
                    throw RuntimeError(error.message, status: error.status)
                }
                if error.isCancelled { throw RuntimeError("\(job.source) was cancelled") }
                throw RuntimeError("\(job.source) stopped: \(error)")
            }

            return job.output!
        }

        if job.state != .done {
            if ownsTerminal && job.pgid > 0, let modes = job.modes {
                jobControl.setModes(modes)
            }

            // It may have stopped for the terminal without our having noticed
            // yet, so always hand the terminal over and continue it; for a
            // job that's running, that changes nothing.
            job.state = .running
            if ownsTerminal && job.pgid > 0 { jobControl.give(terminalTo: job.pgid) }

            job.send(SIGCONT)
            _ = waitForeground(job)
            if job.state == .stopped {
                throw Diagnostic.fatal("job suspended", cause: JobSuspended())
            }
            job.finish()
        }

        jobControl.jobs.removeAll { $0 === job }
        return job.output!
    }

    /// `job.resume()`: a stopped job carries on in the background.
    func resume(_ job: Job) {
        guard job.state == .stopped else { return }
        job.state = .running
        job.reported = false
        job.send(SIGCONT)
    }

    /// `job.cancel()`: asks the job's processes to stop (SIGTERM).
    func cancel(_ job: Job) {
        guard job.state != .done else { return }
        job.cancelled = true
        job.send(SIGTERM)
        if job.state == .stopped {
            job.send(SIGCONT)  // So it can act on the SIGTERM.
            job.state = .running
        }
    }
}

extension CommandRunner {
    /// Starts Swish code as a task of its own (`async f()`, `async { … }`): a
    /// job, whose output is kept for `await`, as `async $(…)`'s is, and whose
    /// value `await` gives.
    func startTask(source: String, _ body: @escaping () throws -> Value) throws -> Job {
        let job = Job(source: source, runner: self)
        guard let pipe = makePipe() else { throw RuntimeError("pipe: \(errorMessage(errno))") }
        job.capture = OutputCollector(reading: pipe.read)
        let state = ShellTask()
        state.inForeground = false
        state.stdoutFD = pipe.write
        state.stderrFD = stderrFD
        nonisolated(unsafe) let body = body  // safe: runs holding the interpreter lock
        do {
            job.task = try interpreter.startTask(state: state) {
                defer { close(pipe.write) }
                return try body()
            }
        } catch {
            close(pipe.write)
            throw error
        }
        jobControl.adopt(job)
        return job
    }
}
