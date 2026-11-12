import Foundation
import Swiit

/// What a task keeps of the problems with single items reported so far, which a function that goes
/// on past an error in one item (`ls` of a path it cannot read) adds to; the host's task state
/// conforms.
public protocol ItemErrors: AnyObject {
    /// How many problems with single items have been reported.
    var itemErrors: Int { get set }
}

/// Writes an error to `output`, as the shell reports one: `swish: message`.
package func writeReport(_ message: String, to output: OutputSink) {
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
/// statement's status becomes a failure. For a function that goes on past an error in one of its
/// items, to the standard error of the task running it.
package func reportItemError(_ message: String) {
    guard let interpreter = Interpreter.running else { return }
    writeReport(message, to: interpreter.host.error)
    (interpreter.taskState as? any ItemErrors)?.itemErrors += 1
}
