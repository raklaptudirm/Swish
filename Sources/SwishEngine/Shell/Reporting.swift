import Foundation
import Swiit
import SwishLibrary

extension Shell {
    /// Reports an error, to wherever standard error is redirected.
    public func report(_ message: String) {
        writeReport(message, to: interpreter.host.error)
    }
}

extension Shell {
    /// Keeps the exit status as statements run: an expression statement's
    /// value says it (`false` fails, a command's `Status` is how it ended),
    /// a per-item error reported makes it a failure, and anything else, as a
    /// `let`, succeeds. An `if` or a loop is what ran in it last.
    func recordStatuses() {
        interpreter.host.didFinishStatement = { [unowned self] value, caught in
            var status = value.map(runner.status(of:)) ?? .success
            // A `try?` that caught an error failed; other nils, like a function that returns
            // nothing, didn't.
            if caught { status = .exited(1) }
            let state = runner.task
            let itemErrors = state.itemErrors > state.itemErrorsSeen
            state.itemErrorsSeen = state.itemErrors
            lastStatus = itemErrors && status.succeeded ? .exited(1) : status
        }
    }
}

extension Shell: ExecutionServices {
    func hasBuiltin(named name: String) -> Bool {
        builtins[name] != nil
    }

    func program(ofBuiltin name: String, arguments: [String]) throws -> [String]? {
        guard case .program(let make)? = builtins[name]?.action else { return nil }
        return try make(self, arguments)
    }

    var staticMembers: [String: [Symbol]] {
        programKnowledge.staticMembers
    }

    var scriptMarks: [String: CommandMarks.Marks] {
        programKnowledge.scriptMarks
    }
}
