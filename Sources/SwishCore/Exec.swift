import CShim
import Foundation
import SwishKit

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

enum Stage {
    case external([String], skipBuiltins: Bool, redirects: [ResolvedRedirect], environment: [(String, String)])
    /// A Swish function, which runs in the shell's own process.
    case function(OverloadSet, [CommandArgument], redirects: [ResolvedRedirect], environment: [(String, String)])
    /// A value feeding the pipeline, as in `[3, 1, 2] | sort`.
    case value(Value)

    var isExternal: Bool {
        if case .external = self { true } else { false }
    }

    var redirects: [ResolvedRedirect] {
        switch self {
        case .external(_, _, let redirects, _), .function(_, _, let redirects, _): redirects
        case .value: []
        }
    }

    /// `NAME=value` given before the command.
    var environment: [(String, String)] {
        switch self {
        case .external(_, _, _, let environment), .function(_, _, _, let environment): environment
        case .value: []
        }
    }
}

extension Shell {
    /// Runs a pipeline. External stages are spawned first; then the
    /// in-process stages run on the shell's thread, streaming values
    /// between themselves and text to and from their external neighbours.
    ///
    /// `display` shows the result of a lone function call, as for any statement.
    func runPipeline(_ stages: [Stage], source: String, display: Bool) throws -> Int32 {
        if stages.count == 1 {
            switch stages[0] {
            // A function reading a file (`double < numbers`) streams it, below.
            case .function(let set, let args, let redirects, let environment) where !redirects.contains(where: { $0.fd == 0 }):
                return try withEnvironment(environment) {
                    try withRedirects(redirects) { _, _ in try callCommand(set, args, display: display) }
                }
            case .external(let argv, let skipBuiltins, let redirects, let environment)
                where !skipBuiltins && Shell.builtinNames.contains(argv[0]):
                return try withEnvironment(environment) {
                    try withRedirects(redirects) { _, _ in runBuiltin(argv)! }
                }
            default:
                break
            }
        }

        // Only one thread runs Swish code, so a pipeline can have one run of
        // in-process stages; two runs would each wait on the other.
        let inProcess = stages.indices.filter { !stages[$0].isExternal }
        if let first = inProcess.first, let last = inProcess.last, last - first + 1 != inProcess.count {
            throw RuntimeError("a pipeline can only have one run of Swish functions for now")
        }
        let segment = inProcess.first.map { $0...inProcess.last! }
        // The run as a whole can read a file at its start, write one at its
        // end, and send standard error anywhere.
        var segmentRedirects: [ResolvedRedirect] = []
        if let segment {
            for index in segment {
                for redirect in stages[index].redirects {
                    let allowed = redirect.fd == 2
                        || (redirect.fd == 0 && index == segment.lowerBound)
                        || (redirect.fd != 0 && index == segment.upperBound)
                    guard allowed else {
                        throw RuntimeError("only the first and last Swish functions in a pipeline can redirect their input and output")
                    }
                    segmentRedirects.append(redirect)
                }
            }
        }

        var job = Job(commandLine: source)
        var input: Int32 = -1
        var segmentInput: Int32 = -1
        var segmentOutput: Int32 = -1
        for (index, stage) in stages.enumerated() {
            let isLast = index == stages.count - 1
            var next: (read: Int32, write: Int32)?
            if !isLast, segment?.contains(index) != true || index == segment?.upperBound {
                guard let pipe = makePipe() else {
                    if input >= 0 { close(input) }
                    if segmentInput >= 0 { close(segmentInput) }
                    if segmentOutput >= 0 { close(segmentOutput) }
                    _ = waitForeground(job)
                    throw RuntimeError("pipe: \(errorMessage(errno))")
                }
                next = pipe
            }
            defer { input = next?.read ?? -1 }

            guard case .external(let argv, _, let redirects, let environment) = stage else {
                // In-process: remember where the run reads from and writes to.
                if index == segment?.lowerBound { segmentInput = input }
                if index == segment?.upperBound, let next { segmentOutput = next.write }
                continue
            }

            var descriptors = DescriptorTable([0: input >= 0 ? input : 0, 1: next?.write ?? stdoutFD, 2: stderrFD])
            let result: Result<pid_t, SpawnFailure>
            do {
                try descriptors.apply(redirects)
                // Children inherit the environment as it is when they start.
                result = withEnvironment(environment) {
                    spawn(argv, pgid: interactive ? job.pgid : -1, descriptors: descriptors)
                }
                descriptors.closeFiles()
            } catch {
                // Like a command that fails to start: this stage fails, the
                // others still run.
                result = .failure(SpawnFailure(message: "\(error)", status: 1))
            }
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
        if let segment {
            do {
                let pipeOutput = segmentOutput >= 0 ? segmentOutput : stdoutFD
                try withEnvironment(stages[segment].flatMap(\.environment)) {
                try withRedirects(segmentRedirects, input: segmentInput, output: pipeOutput) { input, output in
                    // Text for the next program, or, if it went to a file or
                    // the terminal, formatted as it would be displayed.
                    try runSegment(stages[segment], input: input, output: output,
                                   toExternal: segmentOutput >= 0 && output == segmentOutput)
                }
                }
            } catch {
                failure = error
            }
            // Closing lets the stages on either side see EOF or SIGPIPE.
            if segmentInput >= 0 { close(segmentInput) }
            if segmentOutput >= 0 { close(segmentOutput) }
        }

        var status: Int32 = 0
        if !job.running.isEmpty || stages.last?.isExternal == true {
            let externalStatus = job.running.isEmpty ? job.status : waitForeground(job)
            if stages.last?.isExternal == true { status = externalStatus }
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
            lastSignalStatus = 128 + signal
            switch signal {
            case SIGINT: if interactive { writeAll(STDERR_FILENO, "\n") }
            case SIGPIPE: break
            default: report(String(cString: strsignal(signal)))
            }
            return 128 + signal
        }
        return 1
    }

    private func spawn(_ argv: [String], pgid: pid_t, descriptors: DescriptorTable) -> Result<pid_t, SpawnFailure> {
        let name = argv[0]
        guard let path = findExecutable(name) else {
            return .failure(SpawnFailure(message: "\(name): command not found", status: 127))
        }

        // Each changed descriptor, as (the child's, ours). One of ours that
        // is also a target, as in `>&2 2> file`, is copied out of the way
        // first, so the order the child applies them in can't matter.
        let changed = descriptors.map.filter { $0.key != $0.value }
        var targets: [Int32] = []
        var sources: [Int32] = []
        var copies: [Int32] = []
        for (target, source) in changed {
            var source = source
            if changed.keys.contains(source) {
                source = fcntl(source, F_DUPFD_CLOEXEC, 10)
                copies.append(source)
            }
            targets.append(target)
            sources.append(source)
        }
        defer { copies.forEach { close($0) } }

        let cArgs = argv.map { strdup($0) } + [nil]
        defer { cArgs.forEach { free($0) } }
        let pid = swish_spawn(path, cArgs, pgid, targets, sources, Int32(targets.count), interactive ? terminal : -1)
        guard pid < 0 else { return .success(pid) }

        let code = -pid
        let status: Int32 = code == ENOENT ? 127 : 126
        return .failure(SpawnFailure(message: "\(name): \(errorMessage(code).lowercased())", status: status))
    }

    /// Finds `name` on PATH; names containing a slash are used as-is.
    func findExecutable(_ name: String) -> String? {
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
