import Foundation

// The shell as a job-control shell: owning the terminal.

extension Shell {
    /// Takes the terminal as a job-control shell does, when standard input is one: waits to be in
    /// the foreground, ignores the job-control signals, and leads a process group of its own.
    /// Says whether it is a terminal.
    public func takeTerminal() -> Bool {
        guard isatty(terminal) != 0 else { return false }
        // If we were started in the background, wait until we're brought forward.
        while tcgetpgrp(terminal) != getpgrp() {
            kill(-getpgrp(), SIGTTIN)
        }
        for jobSignal in [SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU] {
            signal(jobSignal, SIG_IGN)
        }
        catchInterrupts()
        _ = setpgid(0, 0)  // Fails harmlessly if we're already a session leader.
        shellPgid = getpgrp()
        tcsetpgrp(terminal, shellPgid)
        tcgetattr(terminal, &shellModes)
        interactive = true
        return true
    }
}
