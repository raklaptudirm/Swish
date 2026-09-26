import Foundation

public final class Shell {
    public internal(set) var lastStatus: Int32 = 0

    let terminal = STDIN_FILENO
    /// Whether the shell owns the terminal and does job control.
    var interactive = false
    var shellPgid = getpgrp()
    var shellModes = termios()
    var stoppedJobs: [Job] = []
    var warnedAboutStoppedJobs = false

    private let editor = LineEditor()

    public init() {}

    /// Runs the read-eval loop until EOF or `exit`.
    public func runInteractive() -> Int32 {
        takeTerminal()
        while let line = editor.readLine(prompt: prompt()) {
            execute(line)
        }
        return lastStatus
    }

    @discardableResult
    public func execute(_ line: String) -> Int32 {
        do {
            guard let pipeline = try parse(tokenize(line, home: env("HOME") ?? "~")) else {
                return lastStatus
            }
            lastStatus = run(pipeline, source: line)
        } catch {
            report("syntax error: \(error)")
            lastStatus = 2
        }
        return lastStatus
    }

    private func takeTerminal() {
        guard isatty(terminal) != 0 else { return }
        // If we were started in the background, wait until we're brought forward.
        while tcgetpgrp(terminal) != getpgrp() {
            kill(-getpgrp(), SIGTTIN)
        }
        for signal in [SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU] {
            Foundation.signal(signal, SIG_IGN)
        }
        _ = setpgid(0, 0) // Fails harmlessly if we're already a session leader.
        shellPgid = getpgrp()
        tcsetpgrp(terminal, shellPgid)
        tcgetattr(terminal, &shellModes)
        interactive = true
    }

    private func prompt() -> String {
        var directory = FileManager.default.currentDirectoryPath
        if let home = env("HOME"), directory == home || directory.hasPrefix(home + "/") {
            directory = "~" + directory.dropFirst(home.count)
        }
        let failed = lastStatus != 0
        let status = failed ? "\u{1B}[31m[\(lastStatus)]\u{1B}[0m " : ""
        return "\u{1B}[36m\(directory)\u{1B}[0m \(status)\u{1B}[\(failed ? 31 : 32)m❯\u{1B}[0m "
    }
}
