@_spi(Shell) import Swiit
import SwishKit

extension RuntimeError {
    /// A command that failed under `try`: what `catch` binds is a
    /// `CommandFailure`, with how it ended (`status.code`, `status.signal`)
    /// and the `text` it wrote.
    static func commandFailure(_ message: String, status: Int32, output: Output) -> RuntimeError {
        var error = RuntimeError(message, status: status)
        error.thrown = .record(Record([
            "message": .string(message),
            "status": .record(Record([
                "code": output.code.map(Value.int) ?? .nothing,
                "signal": output.signal.map(Value.int) ?? .nothing,
                "succeeded": .bool(false),
            ], typeName: "Status")),
            "text": .string(output.text),
            "localizedDescription": .string(message),
        ], typeName: "CommandFailure"))
        return error
    }
}
