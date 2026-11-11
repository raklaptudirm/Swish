import Swiit

/// What a shell failure carries beyond its message, which the run hands back as the diagnostic's
/// cause: the status the command line ends with.
struct ShellFailure: Error {
    var status: Int32
}

/// An error the shell's own code gives, shown as a script's error is.
typealias RuntimeError = Diagnostic

extension Diagnostic {
    /// A run-time failure with the `status` it ends the command line with.
    init(_ message: String, status: Int32 = 1) {
        self = .runtime(message, cause: ShellFailure(status: status))
    }

    /// A command that failed under `try`: what `catch` binds is a `CommandFailure`, with how it
    /// ended (`status.code`, `status.signal`) and the `text` it wrote.
    static func commandFailure(
        _ message: String,
        output: Output,
        shell: Shell
    ) -> Diagnostic {
        .runtime(
            message,
            thrown: shell.make(
                shell.preludeTypes.commandFailure,
                [
                    "message": Value(message),
                    "status": shell.statusValue(output.status),
                    "text": Value(output.text),
                    "localizedDescription": Value(message),
                ]
            ),
            cause: ShellFailure(status: output.status.number)
        )
    }

    /// The host's own error behind it (`ShellFailure`, `JobSuspended`).
    var cause: (any Error)? {
        guard case .hostError(let error)? = failure?.origin else { return nil }
        return error
    }

    /// The status the command line ends with.
    var status: Int32 { (cause as? ShellFailure)?.status ?? 1 }

    var isRuntime: Bool { if case .runtime = kind { true } else { false } }
    var isFatal: Bool { if case .fatal = kind { true } else { false } }
    var isSyntax: Bool { if case .syntax = kind { true } else { false } }
    var isCancelled: Bool { if case .cancelled = kind { true } else { false } }
    var isIncomplete: Bool { if case .syntax(isIncomplete: true) = kind { true } else { false } }
}
