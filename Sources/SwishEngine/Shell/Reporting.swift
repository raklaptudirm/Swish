import Foundation
import Swiit

extension Shell {
    /// Reports an error, to wherever standard error is redirected.
    public func report(_ message: String) {
        let output = interpreter.host.error
        let styled = output.traits().isStyled
        if message.hasPrefix("error: ") {
            output.write(
                "swish: error:".styled(DisplayStyle.error, styled) + message.dropFirst(6) + "\n"
            )
        } else {
            output.write("swish:".styled(DisplayStyle.error, styled) + " \(message)\n")
        }
    }

    /// Reports a problem with one item, like a file `ls` couldn't read, without stopping; the
    /// statement's status becomes a failure.
    func reportItemError(_ message: String) {
        report(message)
        runner.task.itemErrors += 1
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
