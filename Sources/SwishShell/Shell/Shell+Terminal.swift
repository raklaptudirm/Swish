import Foundation

// The shell as a job-control shell, which a client asks of it.

extension Shell {
    /// Takes the terminal as a job-control shell does, when standard input is one: waits to be in
    /// the foreground, ignores the job-control signals, and leads a process group of its own.
    /// Says whether it is a terminal.
    public func takeTerminal() -> Bool {
        jobControl.takeTerminal()
    }

    /// What's changed with background jobs, for the notices before the next prompt. Finished jobs
    /// leave the list once they've been reported.
    public func jobNotices(styled: Bool = false) -> [String] {
        jobControl.notices(styled: styled)
    }
}
