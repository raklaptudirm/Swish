import Foundation
import SwishKit

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    /// The status the failure gives: a failed command's own, for `$(…)`.
    var status: Int32 = 1
    /// For a failed command, its output, so `catch` can look at it.
    var output: Output?

    init(_ description: String, status: Int32 = 1, output: Output? = nil) {
        self.description = description
        self.status = status
        self.output = output
    }

    /// What `catch` binds: the message, how it ended (`status.code`,
    /// `status.signal`, `status.succeeded`), and a failed command's `text`.
    var value: Value {
        let code = output.map { $0.code } ?? Int(status)
        return .record(Record([
            "message": .string(description),
            "status": .record(Record([
                "code": code.map(Value.int) ?? .nothing,
                "signal": output?.signal.map(Value.int) ?? .nothing,
                "succeeded": .bool(false),
            ], typeName: "Status")),
            "text": .string(output?.text ?? ""),
        ], typeName: "Error"))
    }
}

/// A runtime error under `try!`: it stops a script, not just the line.
struct FatalError: Error {
    let error: RuntimeError
}

/// ^C while the shell itself was running code.
/// ^C, or in a script SIGTERM or SIGHUP: stops what's running.
struct Interrupted: Error {
    var reason: StopReason
}

/// Non-local exits, thrown up to the loop or call that handles them. The
/// parser guarantees each one has a handler.
enum ControlFlow: Error {
    case returned(Value)
    case breakLoop
    case continueLoop
    case fallthroughCase
}
