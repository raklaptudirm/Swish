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
            environment: EnvironmentAccess(
                get: { env($0) },
                all: { ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key }).map { (name: $0.key, value: $0.value) } },
                set: { name, value in
                    if let value { setenv(name, value, 1) } else { unsetenv(name) }
                }),
            commands: CommandAccess(
                capture: { [unowned shell] in try shell.capturing($0) },
                hasProgram: { [unowned shell] in shell.findExecutable($0) != nil },
                run: { [unowned shell] node, display in
                    try shell.runPipeline(try shell.stages(for: node), source: node.source, display: display)
                },
                start: { [unowned shell] node, capture in
                    .object(try shell.startJob(try shell.stages(for: node), source: node.source, capture: capture))
                },
                jobs: { [unowned shell] in
                    shell.updateJobs() // So their states are current.
                    return shell.jobs.map { .object($0) }
                })
        )
    }
}

extension Interrupted {
    /// The signal that asked the shell to stop: the shell's reason is one.
    var signal: Int32 { reason.code }
}

extension Shell {
    /// The environment, or a refusal where there is no shell layer.
    func environmentAccess() throws -> EnvironmentAccess {
        guard let layer = shellLayer else { throw RuntimeError("the environment isn't available here") }
        return layer.environment
    }

    /// Commands, jobs and `$(…)`, or a refusal where there is no shell layer.
    func commandAccess() throws -> CommandAccess {
        guard let layer = shellLayer else { throw RuntimeError("commands aren't available here") }
        return layer.commands
    }
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
