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
        // Told after every statement, loops and function bodies included: it takes what it needs
        // from the runner once, and counts no references (the shell outlives its interpreter's host).
        unowned(unsafe) let runner = self.runner
        interpreter.host.didFinishStatement = { value, caught in
            let state = runner.task
            var status = value.map(runner.status(of:)) ?? .success
            // A `try?` that caught an error failed; other nils, like a function that returns
            // nothing, didn't.
            if caught { status = .exited(1) }
            let itemErrors = state.itemErrors > state.itemErrorsSeen
            state.itemErrorsSeen = state.itemErrors
            state.lastStatus = itemErrors && status.succeeded ? .exited(1) : status
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
