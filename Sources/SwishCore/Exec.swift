import CShim
import Foundation

struct Job {
    /// 0 when the job has no process group of its own (non-interactive mode).
    var pgid: pid_t = 0
    /// Processes not yet reaped, in pipeline order.
    var running: [pid_t] = []
    /// nil when the last command failed to spawn.
    var lastPid: pid_t?
    /// The status of the pipeline's last command.
    var status: Int32 = 0
    let commandLine: String
}

struct SpawnFailure: Error {
    let message: String
    let status: Int32
}

struct ResolvedCommand {
    var argv: [String]
    /// Skip functions and builtins (`^name`).
    var external = false
    /// Set when the name refers to a Swish function, which runs in-process.
    var function: Function?
}

extension Shell {
    /// Runs a pipeline. Function stages run in the shell's own process once
    /// the external stages have been spawned, writing into their pipe; they
    /// don't read their input yet (that arrives with `@input`).
    ///
    /// `display` shows the result of a lone function call, as for any statement.
    func runPipeline(_ commands: [ResolvedCommand], source: String, display: Bool) throws -> Int32 {
        if commands.count == 1 {
            if let function = commands[0].function {
                return try callCommand(function, Array(commands[0].argv.dropFirst()), display: display)
            }
            if !commands[0].external, let status = runBuiltin(commands[0].argv) {
                return status
            }
        }

        var job = Job(commandLine: source)
        var functionStages: [(function: Function, args: [String], output: Int32, ownsOutput: Bool)] = []
        var input: Int32 = -1
        for (index, command) in commands.enumerated() {
            let isLast = index == commands.count - 1
            var next: (read: Int32, write: Int32)?
            if !isLast {
                guard let pipe = makePipe() else {
                    report("pipe: \(errorMessage(errno))")
                    if input >= 0 { close(input) }
                    job.status = 1
                    break
                }
                next = pipe
            }
            let output = next?.write ?? (stdoutFD == STDOUT_FILENO ? -1 : stdoutFD)
            defer { input = next?.read ?? -1 }

            if let function = command.function {
                if input >= 0 { close(input) }
                // Its output end stays open until the function has run.
                functionStages.append((function, Array(command.argv.dropFirst()), output, next != nil))
                continue
            }

            let result = spawn(command.argv, pgid: interactive ? job.pgid : -1, input: input, output: output)
            if input >= 0 { close(input) }
            if let next { close(next.write) }

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
        if input >= 0 { close(input) }

        var failure: (any Error)?
        for stage in functionStages {
            if failure == nil {
                let savedOutput = stdoutFD
                if stage.output >= 0 { stdoutFD = stage.output }
                do {
                    let status = try callCommand(stage.function, stage.args, display: true)
                    if stage.function === commands.last?.function { job.status = status }
                } catch {
                    failure = error
                }
                stdoutFD = savedOutput
            }
            // Closing lets the next stage see EOF.
            if stage.ownsOutput { close(stage.output) }
        }

        var status = job.status
        if !job.running.isEmpty {
            let externalStatus = waitForeground(job)
            if commands.last?.function == nil { status = externalStatus }
        }
        if let failure { throw failure }
        return status
    }

    /// Gives `job` the terminal and waits until it finishes or stops.
    func waitForeground(_ job: Job) -> Int32 {
        var job = job
        if interactive && job.pgid > 0 {
            tcsetpgrp(terminal, job.pgid)
        }
        defer {
            if interactive {
                tcsetpgrp(terminal, shellPgid)
                tcsetattr(terminal, TCSANOW, &shellModes)
            }
        }

        while let pid = job.running.first {
            var raw: Int32 = 0
            guard waitpid(pid, &raw, WUNTRACED) == pid else {
                if errno == EINTR { continue }
                job.running.removeFirst()
                continue
            }
            if swish_wifstopped(raw) != 0 {
                stoppedJobs.append(job)
                writeAll(STDERR_FILENO, "\n[\(stoppedJobs.count)]+  Stopped    \(job.commandLine)\n")
                return 128 + SIGTSTP
            }
            job.running.removeFirst()
            if pid == job.lastPid {
                job.status = decode(raw)
            }
        }
        return job.status
    }

    private func decode(_ raw: Int32) -> Int32 {
        if swish_wifexited(raw) != 0 {
            return swish_wexitstatus(raw)
        }
        if swish_wifsignaled(raw) != 0 {
            let signal = swish_wtermsig(raw)
            switch signal {
            case SIGINT: if interactive { writeAll(STDERR_FILENO, "\n") }
            case SIGPIPE: break
            default: report(String(cString: strsignal(signal)))
            }
            return 128 + signal
        }
        return 1
    }

    private func spawn(_ argv: [String], pgid: pid_t, input: Int32, output: Int32) -> Result<pid_t, SpawnFailure> {
        let name = argv[0]
        guard let path = resolve(name) else {
            return .failure(SpawnFailure(message: "\(name): command not found", status: 127))
        }

        let cArgs = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        let pid = swish_spawn(path, cArgs, pgid, input, output, interactive ? terminal : -1)
        guard pid < 0 else { return .success(pid) }

        let code = -pid
        let status: Int32 = code == ENOENT ? 127 : 126
        return .failure(SpawnFailure(message: "\(name): \(errorMessage(code).lowercased())", status: status))
    }

    /// Finds `name` on PATH; names containing a slash are used as-is.
    private func resolve(_ name: String) -> String? {
        if name.contains("/") { return name }
        let searchPath = env("PATH") ?? "/usr/bin:/bin"
        for directory in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = (directory.isEmpty ? "." : String(directory)) + "/" + name
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               access(candidate, X_OK) == 0 {
                return candidate
            }
        }
        return nil
    }
}

/// A pipe whose ends are closed on exec, so children inherit only what's
/// dup'd onto their stdin/stdout, never a stray end that would keep a
/// reader from seeing EOF.
func makePipe() -> (read: Int32, write: Int32)? {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { return nil }
    for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    return (fds[0], fds[1])
}
