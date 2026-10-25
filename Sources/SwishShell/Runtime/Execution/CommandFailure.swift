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
    static func commandFailure(_ message: String, status: Int32, output: Output) -> Diagnostic {
        .runtime(
            message,
            thrown: Value(
                struct: "CommandFailure",
                fields: [
                    "message": Value(message),
                    "status": Value(
                        struct: "Status",
                        fields: [
                            "code": output.code.map { Value($0) } ?? Value.nothing,
                            "signal": output.signal.map { Value($0) } ?? Value.nothing,
                            "succeeded": Value(false),
                        ]
                    ),
                    "text": Value(output.text),
                    "localizedDescription": Value(message),
                ]
            ),
            cause: ShellFailure(status: status)
        )
    }

    /// The host's own error behind it (`ShellFailure`, `JobSuspended`).
    var cause: (any Error)? {
        guard case .hostError(let error)? = failure?.origin else { return nil }
        return error
    }

    /// The status the command line ends with.
    var status: Int32 { (cause as? ShellFailure)?.status ?? 1 }

    /// Where it is told, when a redirect sent it somewhere other than the shell's own errors.
    var output: OutputSink? {
        guard case .sink(let output)? = failure?.destination else { return nil }
        return output
    }

    /// The same failure, to be told where `other` is.
    func told(where other: Diagnostic) -> Diagnostic {
        guard let destination = other.failure?.destination, case .runtime(var failure) = kind else {
            return self
        }
        failure.destination = destination
        var copy = self
        copy.kind = .runtime(failure)
        return copy
    }

    var isRuntime: Bool { if case .runtime = kind { true } else { false } }
    var isFatal: Bool { if case .fatal = kind { true } else { false } }
    var isSyntax: Bool { if case .syntax = kind { true } else { false } }
    var isCancelled: Bool { if case .cancelled = kind { true } else { false } }
    var isIncomplete: Bool { if case .syntax(isIncomplete: true) = kind { true } else { false } }
}
