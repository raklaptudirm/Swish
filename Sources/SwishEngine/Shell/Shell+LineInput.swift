import Foundation
import Swiit

// Input that arrives a line at a time, from a person at a prompt or from standard input: lines
// are gathered until they make a whole statement, which is then run.

extension Shell {
    /// What taking a line led to.
    public enum Acceptance: Sendable {
        /// The line starts or continues a statement that is not finished, like an open `if` block.
        case needsMoreLines
        /// The lines made a statement, and it ran. `shouldStop` says a `try!` stopped the script.
        case ran(status: Int32, shouldStop: Bool)
    }

    /// Whether a statement is waiting for more lines, so a client can draw a continuation prompt.
    public var hasUnfinishedStatement: Bool { !unfinishedStatement.isEmpty }

    /// Takes one line of input. A line that finishes a statement runs it, showing what it gives
    /// when `atPrompt`; one that leaves it unfinished is kept for the next line. Reading, checking
    /// and run-time errors are reported, and the shell goes on.
    @discardableResult
    public func accept(line: String, atPrompt: Bool) -> Acceptance {
        unfinishedStatement = hasUnfinishedStatement ? unfinishedStatement + "\n" + line : line
        runState.diagnosticSource = (unfinishedStatement, nil)

        switch prepare(unfinishedStatement) {
        case .failure(let error) where error.isIncomplete:
            return .needsMoreLines
        case .failure(let error):
            reportReadingFailure(error)
        case .success(let reading):
            // Checked first, as everywhere else: a type error runs nothing.
            runReportingErrors(reading, atPrompt: atPrompt)
        }

        unfinishedStatement = ""
        return .ran(status: lastStatus.number, shouldStop: runState.scriptStopped)
    }

    /// Drops an unfinished statement, as ^C does at the prompt.
    public func discardUnfinishedStatement() {
        unfinishedStatement = ""
    }

    /// Runs what is left unfinished at the end of input, and gives the last status.
    @discardableResult
    public func finishInput(atPrompt: Bool) -> Int32 {
        let rest = unfinishedStatement
        unfinishedStatement = ""
        if !rest.isEmpty { _ = runSource(rest, atPrompt: atPrompt) }
        return lastStatus.number
    }

    /// Whether `source` is a statement that is not finished, which another line could complete.
    public func isUnfinished(_ source: String) -> Bool {
        if case .failure(let error) = prepare(source), error.isIncomplete { return true }
        return false
    }
}
