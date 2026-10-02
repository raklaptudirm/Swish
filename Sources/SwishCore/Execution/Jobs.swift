import Foundation
import SwishKit

/// A pipeline of processes: one running in the foreground, or a job in the
/// background, from `async` or ^Z. Jobs in the background are values:
/// `await` brings one to the foreground and waits for it, and `resume()`
/// and `cancel()` act on it.
final class Job: SwishObject, @unchecked Sendable {
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
    /// The status of the pipeline's last command.
    var status: Int32 = 0
    /// The signal that ended the last command, if one did.
    var signal: Int32?
    var state = State.running
    var cancelled = false
    /// Whether its latest change (stopping, or finishing) has been reported.
    var reported = false
    /// The terminal as the job left it when it stopped, as vim does, so it
    /// gets it back the same way.
    var modes: termios?
    /// For `async $(…)`: its output, read as it comes.
    var capture: OutputCollector?
    /// Once it's done: its output and how it exited.
    private(set) var output: CommandOutput?
    unowned let shell: Shell

    init(source: String, shell: Shell) {
        self.source = source
        self.shell = shell
    }

    func finish() {
        guard state != .done else { return }
        var text = capture?.finish() ?? ""
        while text.last == "\n" { text.removeLast() }
        output = CommandOutput(text: text, code: signal == nil ? Int(status) : nil, signal: signal.map(Int.init))
        state = .done
        capture = nil
    }

    /// Sends a signal to every process in the job.
    func send(_ signal: Int32) {
        if pgid > 0 {
            kill(-pgid, signal)
        } else {
            running.forEach { kill($0, signal) }
        }
    }

    // MARK: SwishObject

    var typeName: String { "Job" }

    /// A job's members: each one's type, for the checker, and its value.
    static let members: [(name: String, type: TypeAnnotation, value: @Sendable (Job) -> Value)] = [
        ("id", .int, { .int($0.id) }),
        ("command", .string, { .string($0.source) }),
        ("state", .named("JobState"), { job in
            job.shell.declaredCase("JobState", job.cancelled && job.state == .done ? "cancelled" : job.state.rawValue)
        }),
        ("pids", .list(.int), { .list($0.running.map { .int(Int($0)) }) }),
        ("output", .optional(.output), { $0.output.map(Value.output) ?? .nothing }),
        ("resume", .functionType([], .void), { job in method("resume") { [unowned job] in job.shell.resume(job) } }),
        ("cancel", .functionType([], .void), { job in method("cancel") { [unowned job] in job.shell.cancel(job) } }),
    ]
    var memberNames: [String] { Job.members.map(\.name) }

    func member(_ name: String) -> Value? {
        Job.members.first { $0.name == name }?.value(self)
    }

    private static func method(_ name: String, _ body: @escaping () -> Void) -> Value {
        .function(OverloadSet(name: name, candidates: [
            Function(name: name, parameters: [], returnType: nil, body: .native { _, _ in
                body()
                return .nothing
            }),
        ]))
    }

    /// `[1] running  make`, in pieces to color: the number dim, the state
    /// by how it's going.
    var segments: [PrettyPrinter.Segment] {
        let (label, style): (String, Style?) = switch state {
        case .running: ("running", Style.green)
        case .stopped: ("stopped", Style.yellow)
        case .done where cancelled: ("cancelled", Style.dim)
        case .done where signal != nil: ("failed (\(String(cString: strsignal(signal!)).lowercased()))", Style.red)
        case .done where status != 0: ("failed (\(status))", Style.red)
        case .done: ("done", nil)
        }
        return [("[\(id)]", Style.dim), (" ", nil), (label, style), ("  " + source, nil)]
    }

    var description: String { line(styled: false) }

    func line(styled: Bool) -> String {
        segments.map { $0.text.styled($0.style, styled) }.joined()
    }

    /// A job on its own reads as `jobs` announces it: `[1] running  make`.
    var debugDescription: String { description }
}

/// The job's `$?`-less status and signal, from a `waitpid` status.
struct Exit {
    let status: Int32
    let signal: Int32?

    init(_ raw: Int32) {
        let wait = WaitStatus(raw)
        if wait.exited {
            status = wait.exitCode
            signal = nil
        } else if wait.signaled {
            signal = wait.signal
            status = 128 + signal!
        } else {
            status = 1
            signal = nil
        }
    }
}

/// Stopping a job you were awaiting (^Z) leaves the line; it's in `jobs`.
struct JobSuspended: Error {}

extension Shell {
    /// Puts a job in `jobs`, giving it the next free number.
    func adopt(_ job: Job) {
        guard job.id == 0 else { return }
        job.id = (jobs.map(\.id).max() ?? 0) + 1
        jobs.append(job)
    }

    /// Starts a pipeline of programs in the background (`async`), capturing
    /// its output if asked (`async $(…)`).
    func startJob(_ stages: [Stage], source: String, capture: Bool) throws -> Job {
        guard stages.allSatisfy(\.isExternal) else {
            throw RuntimeError("async runs programs; Swish functions and values can't run in the background yet")
        }
        let job = Job(source: source, shell: self)
        var output = stdoutFD
        if capture {
            guard let pipe = makePipe() else { throw RuntimeError("pipe: \(errorMessage(errno))") }
            job.capture = OutputCollector(reading: pipe.read)
            output = pipe.write
        }
        defer { if capture { close(output) } }

        var input: Int32 = -1
        for (index, stage) in stages.enumerated() {
            guard case .external(let argv, _, let redirects, let environment) = stage else { continue }
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
            let result = launch(argv, redirects: redirects, environment: environment,
                                input: input, output: next?.write ?? output,
                                pgid: interactive ? job.pgid : -1, foreground: false)
            if input >= 0 { close(input) }
            if let next { close(next.write) }
            input = next?.read ?? -1
            switch result {
            case .success(let pid):
                if interactive && job.pgid == 0 { job.pgid = pid }
                job.running.append(pid)
                if isLast { job.lastPid = pid }
            case .failure(let failure):
                report(failure.message)
                if isLast { job.status = failure.status }
            }
        }
        if job.running.isEmpty {
            job.finish()
        } else {
            adopt(job)
        }
        return job
    }

    /// Brings a job to the foreground and waits for it (`await`). If it's
    /// stopped again with ^Z, it goes back to `jobs` and the line is left.
    func awaitJob(_ job: Job) throws -> CommandOutput {
        if job.state != .done {
            if interactive && job.pgid > 0, var modes = job.modes {
                tcsetattr(terminal, TCSANOW, &modes)
            }
            // It may have stopped for the terminal without our having noticed
            // yet, so always hand the terminal over and continue it; for a
            // job that's running, that changes nothing.
            job.state = .running
            if interactive && job.pgid > 0 { tcsetpgrp(terminal, job.pgid) }
            job.send(SIGCONT)
            _ = waitForeground(job)
            if job.state == .stopped { throw JobSuspended() }
            job.finish()
        }
        jobs.removeAll { $0 === job }
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
            job.send(SIGCONT) // So it can act on the SIGTERM.
            job.state = .running
        }
    }

    /// What's changed with background jobs, for the notices before the next
    /// prompt. Finished jobs leave `jobs` once they've been reported.
    func announceJobs(styled: Bool = false) -> [String] {
        updateJobs()
        var notices: [String] = []
        for job in jobs where job.state != .running && !job.reported {
            job.reported = true
            notices.append(job.state == .stopped
                ? job.line(styled: styled) + "  (waiting for the terminal: await it)".styled(Style.dim, styled)
                : job.line(styled: styled))
        }
        jobs.removeAll { $0.state == .done }
        return notices
    }

    /// Checks on background jobs without waiting, noting which finished or
    /// stopped. Finished jobs stay in `jobs`, shown as done, until they're
    /// announced or awaited.
    func updateJobs() {
        for job in jobs where job.state == .running {
            var stopped = false
            for pid in job.running {
                var raw: Int32 = 0
                guard waitpid(pid, &raw, WNOHANG | WUNTRACED) == pid else { continue }
                if WaitStatus(raw).stopped {
                    stopped = true
                    continue
                }
                job.running.removeAll { $0 == pid }
                if pid == job.lastPid {
                    let exit = Exit(raw)
                    job.status = exit.status
                    job.signal = exit.signal
                }
            }
            if job.running.isEmpty {
                job.finish()
            } else if stopped {
                job.state = .stopped
            }
        }
    }
}
