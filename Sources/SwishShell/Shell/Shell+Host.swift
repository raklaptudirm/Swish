import Foundation
import Swiit

extension Interpreter.Host {
    /// The shell as a host: the process it is. Output goes to the
    /// descriptors (as redirected for a `$(…)`), and a signal asks it to stop.
    init(process shell: Shell) {
        self.init(
            output: OutputSink(
                write: { [unowned shell] in writeAll(shell.stdoutFD, $0) },
                traits: { [unowned shell] in OutputSink.Traits(fd: shell.stdoutFD) }
            ),
            error: OutputSink(
                write: { [unowned shell] in writeAll(shell.stderrFD, $0) },
                traits: { [unowned shell] in OutputSink.Traits(fd: shell.stderrFD) }
            ),
            shouldStop: { [unowned shell] in
                // The signal that asked is kept, for the shell to end by once the run has stopped.
                guard let signal = takeInterruptSignal() else { return false }
                shell.stoppedBySignal = signal
                return true
            }
        )
    }
}
