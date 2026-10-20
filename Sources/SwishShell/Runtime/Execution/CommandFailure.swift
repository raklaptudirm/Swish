import Swiit

/// An error the shell's own code gives, shown as a script's error is.
typealias RuntimeError = ScriptError

extension ScriptError {
    /// A command that failed under `try`: what `catch` binds is a
    /// `CommandFailure`, with how it ended (`status.code`, `status.signal`)
    /// and the `text` it wrote.
    static func commandFailure(_ message: String, status: Int32, output: Output) -> ScriptError {
        ScriptError(message, status: status, value: Value(struct: "CommandFailure", fields: [
            "message": Value(message),
            "status": Value(struct: "Status", fields: [
                "code": output.code.map { Value($0) } ?? Value.null,
                "signal": output.signal.map { Value($0) } ?? Value.null,
                "succeeded": Value(false),
            ]),
            "text": Value(output.text),
            "localizedDescription": Value(message),
        ]))
    }
}
