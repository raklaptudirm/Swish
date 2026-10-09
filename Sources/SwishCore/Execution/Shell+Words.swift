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

    /// Joins a word's parts into one string, without splitting or matching
    /// files: an environment variable's value.
    func join(_ parts: [WordPart]) throws -> String {
        try parts.map { part in
            switch part {
            case .literal(let text), .glob(let text): text
            case .expression(let expr), .spread(let expr): try evaluate(expr).description
            }
        }.joined()
    }

    /// A command word's arguments: one, unless it has an unquoted wildcard,
    /// when it's the matching paths. Interpolated values are literal in the
    /// pattern, so `"$dir"/*.txt` works whatever `$dir` holds. A pattern
    /// that matches nothing is an error, not passed on as it is. An
    /// unquoted list alone in the word is its items: `rm $files`.
    func expandWord(_ parts: [WordPart]) throws -> [String] {
        if parts.count == 1, case .spread(let expr) = parts[0], case .list(let items) = try evaluate(expr) {
            return items.map(\.description)
        }
        var text = ""
        var pattern = ""
        var hasGlob = false
        for part in parts {
            switch part {
            case .literal(let literal):
                text += literal
                pattern += Glob.escape(literal)
            case .glob(let glob):
                text += glob
                // `?` isn't a wildcard in Swish, so URLs need no quoting.
                pattern += glob.replacingOccurrences(of: "?", with: "\\?")
                hasGlob = true
            case .expression(let expr), .spread(let expr):
                let value = try evaluate(expr).description
                text += value
                pattern += Glob.escape(value)
            }
        }
        guard hasGlob, Glob.hasWildcards(pattern) else { return [text] }
        let matches = Glob.expand(pattern)
        guard !matches.isEmpty else { throw RuntimeError("no matches for \(text)") }
        return matches
    }

    func resolve(_ redirect: Redirect) throws -> ResolvedRedirect {
        switch redirect.target {
        case .descriptor(let source):
            return ResolvedRedirect(fd: redirect.fd, action: .duplicate(source))
        case .file(let parts, let mode):
            let paths = try expandWord(parts)
            guard paths.count == 1 else {
                throw RuntimeError("ambiguous redirect: \(paths.count) files match")
            }
            return ResolvedRedirect(fd: redirect.fd, action: .open(paths[0], mode))
        }
    }
}
