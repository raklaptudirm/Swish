import Foundation

/// A job-control shell's hold on the terminal, and the jobs it keeps: what the shell does beyond
/// running commands. A `Shell` owns one. Only a shell that took the terminal (`isInteractive`)
/// hands it to the jobs it starts.
final class JobControl {
    /// The terminal: standard input.
    let terminal = STDIN_FILENO

    /// Whether the shell owns the terminal and does job control.
    var isInteractive = false

    /// Jobs in the background: started with `async`, or stopped with ^Z.
    var jobs: [Job] = []

    /// Whether `exit` has warned of jobs in the background, so that asking again leaves.
    var hasWarnedAboutJobs = false

    /// The shell's own process group, which gets the terminal back from a job.
    private var shellProcessGroup = getpgrp()

    /// The terminal's modes as the shell left them, put back after a job.
    private var shellModes = termios()

    /// Takes the terminal as a job-control shell does, when standard input is one: waits to be in
    /// the foreground, ignores the job-control signals, and leads a process group of its own.
    /// Says whether it is a terminal.
    func takeTerminal() -> Bool {
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
        shellProcessGroup = getpgrp()
        tcsetpgrp(terminal, shellProcessGroup)
        tcgetattr(terminal, &shellModes)
        isInteractive = true
        return true
    }

    /// Gives the terminal to a job's process group, so it can read it without being stopped.
    func give(terminalTo processGroup: pid_t) {
        tcsetpgrp(terminal, processGroup)
    }

    /// Takes the terminal back from a job, with the modes the shell left it in.
    func takeTerminalBack() {
        tcsetpgrp(terminal, shellProcessGroup)
        tcsetattr(terminal, TCSANOW, &shellModes)
    }

    /// The terminal's modes now, which a job stopped with ^Z keeps to find them as it left them.
    func currentModes() -> termios {
        var modes = termios()
        tcgetattr(terminal, &modes)
        return modes
    }

    /// Sets the terminal's modes, as a job continued from a stop had them.
    func setModes(_ modes: termios) {
        var modes = modes
        tcsetattr(terminal, TCSANOW, &modes)
    }

    /// Puts back the modes the shell left, before it is replaced by another program (`exec`).
    func restoreShellModes() {
        guard isInteractive else { return }
        tcsetattr(terminal, TCSANOW, &shellModes)
    }
}
