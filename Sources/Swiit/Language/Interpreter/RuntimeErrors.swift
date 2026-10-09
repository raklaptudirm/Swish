import Foundation
import SwishKit

package struct RuntimeError: Error, CustomStringConvertible {
    package let description: String
    /// The status the failure gives: a failed command's own, for `$(…)`.
    package var status: Int32 = 1
    /// For a failed command, its output, so `catch` can look at it.
    package var output: Output?

    package init(_ description: String, status: Int32 = 1, output: Output? = nil) {
        self.description = description
        self.status = status
        self.output = output
    }

    /// What `catch` binds: the message, how it ended (`status.code`,
    /// `status.signal`, `status.succeeded`), and a failed command's `text`.
    package var value: Value {
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
package struct FatalError: Error {
    package let error: RuntimeError

    package init(error: RuntimeError) {
        self.error = error
    }
}

/// ^C while the shell itself was running code.
/// ^C, or in a script SIGTERM or SIGHUP: stops what's running.
package struct Interrupted: Error {
    package var reason: StopReason

    package init(reason: StopReason) {
        self.reason = reason
    }
}

/// Non-local exits, thrown up to the loop or call that handles them. The
/// parser guarantees each one has a handler.
package enum ControlFlow: Error {
    case returned(Value)
    case breakLoop
    case continueLoop
    case fallthroughCase
}

/// A runtime error that has been reported already; it still fails the input.
package struct AlreadyReported: Error {
    package let error: RuntimeError

    package init(error: RuntimeError) { self.error = error }
}
