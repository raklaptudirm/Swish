import SwishShellLibrary
@_spi(Shell) import Swiit
import Foundation
import SwishKit
import SwishStandardLibrary

// The shell's halves of what the interpreter does with environment, words and
// statuses: a command's words and redirects expanded, and a status read as an
// exit code or the signal that ended the command.
extension Interpreter {
    /// A status as an exit code, or the signal that ended the command.
    func exitCode(_ status: Int32) -> (code: Int?, signal: Int?) {
        if status > 128 && status == lastSignalStatus { return (nil, Int(status - 128)) }
        return (Int(status), nil)
    }

    /// Sets environment variables around `body`, then puts them back.
    func withEnvironment<T>(_ variables: [(String, String)], _ body: () throws -> T) rethrows -> T {
        // A name given twice is the last one's.
        try with(env: Dictionary(variables, uniquingKeysWith: { $1 }), body)
    }

    /// The paths a pattern matches; without a wildcard, itself.
    func expand(_ pattern: String) throws -> [String] {
        guard Glob.hasWildcards(pattern) else { return [Glob.unescape(pattern)] }
        let matches = Glob.expand(pattern)
        guard !matches.isEmpty else { throw RuntimeError("no matches for \(Glob.unescape(pattern))") }
        return matches
    }
}
