import Foundation
import Swiit

// The shell's halves of what the interpreter does with environment and words: a command's words
// and redirects expanded.
extension Shell {
    /// Sets environment variables around `body`, then puts them back.
    func withEnvironment<T>(_ variables: [(String, String)], _ body: () throws -> T) rethrows -> T {
        // A name given twice is the last one's.
        try with(env: Dictionary(variables, uniquingKeysWith: { $1 }), body)
    }

    /// The functions a command name refers to, if it was declared with `func`.
    func commandFunctions(named name: String) -> Callee? {
        let functions = interpreter.globals(named: name).filter { $0.function != nil }
        return functions.isEmpty
            ? nil
            : Callee(
                name: name,
                overloads: functions,
                receiver: nil,
                marks: programKnowledge.scriptMarks
            )
    }

    /// The paths a pattern matches; without a wildcard, itself.
    func expand(_ pattern: String) throws -> [String] {
        guard Glob.hasWildcards(pattern) else { return [Glob.unescape(pattern)] }
        let matches = Glob.expand(pattern)
        guard !matches.isEmpty else {
            throw RuntimeError("no matches for \(Glob.unescape(pattern))")
        }
        return matches
    }
}
