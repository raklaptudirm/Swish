import Swiit
import Foundation
import SwishKit
import SwishStandardLibrary

extension SwishHost {
    /// The shell as a host: the process it is. Output goes to the
    /// descriptors (as redirected for a `$(…)`), and a signal asks it to stop.
    init(process shell: Shell) {
        self.init(
            output: OutputSink(write: { [unowned shell] in writeAll(shell.stdoutFD, $0) },
                               traits: { [unowned shell] in StreamTraits(fd: shell.stdoutFD) }),
            error: OutputSink(write: { [unowned shell] in writeAll(shell.stderrFD, $0) },
                              traits: { [unowned shell] in StreamTraits(fd: shell.stderrFD) }),
            interrupt: { takeInterruptSignal().map(StopReason.init) }
        )
    }
}

extension ShellLayer {
    /// The process's environment, and commands that are programs.
    init(process shell: Shell) {
        self.init(
            commands: CommandAccess(
                jobs: { [unowned shell] in
                    shell.updateJobs() // So their states are current.
                    return shell.jobs.map { .object($0) }
                },
                await: { [unowned shell] value, throwing in
                    let job: Job
                    if let value {
                        guard case .object(let object as Job) = value else {
                            throw RuntimeError("await needs a Job, not \(value.typeName)")
                        }
                        job = object
                    } else {
                        guard let latest = shell.jobs.last else { throw RuntimeError("there are no jobs to await") }
                        job = latest
                    }
                    let output = try shell.awaitJob(job)
                    if throwing && !output.succeeded {
                        throw RuntimeError("\(job.source) failed with status \(job.status)", status: job.status, output: output)
                    }
                    return .output(output)
                },
                callSequenceMethod: { [unowned shell] methods, items, arguments in
                    try shell.callSequenceMethod(methods, on: items, arguments)
                }),
            importPlugin: { [unowned shell] name, path in try shell.importPlugin(name, from: path) },
            history: { [unowned shell] in shell.historyEntries },
            columns: ["Job": Job.columns, "Help": Shell.helpColumns]
        )
    }
}

extension Interrupted {
    /// The signal that asked the shell to stop: the shell's reason is one.
    var signal: Int32 { reason.code }
}

extension StreamTraits {
    /// What the descriptor is: a terminal of some width, or a file or pipe.
    init(fd: Int32) {
        self.init(isTerminal: isatty(fd) != 0, width: terminalWidth(fd), styled: DisplayStyle.enabled(for: fd))
    }
}

extension DisplayFormatter {
    /// Writes to `fd`, fitting the terminal and styling the header when it
    /// is one. A file gets every character: nothing is cut to fit.
    convenience init(fd: Int32, registry: DisplayRegistry) {
        self.init(traits: StreamTraits(fd: fd), registry: registry) { writeAll(fd, $0) }
    }

    /// Rows for another program to read, as in `ls | grep x`: the view's
    /// columns, no header, nothing cut short.
    static func forProgram(fd: Int32, registry: DisplayRegistry) -> DisplayFormatter {
        DisplayFormatter(header: false, columnCap: .max, registry: registry) { writeAll(fd, $0) }
    }
}

/// The width of the terminal `fd` is, if it is one.
func terminalWidth(_ fd: Int32) -> Int? {
    var size = winsize()
    // TIOCGWINSZ is a UInt on macOS and an Int32 on Linux.
    guard isatty(fd) != 0, ioctl(fd, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return nil }
    return Int(size.ws_col)
}
