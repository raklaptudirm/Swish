import Foundation

// The Swift inside the shell's forms: interpolation, closures, arguments and `$`.

extension Reader {
    /// `\(expression)`, at the backslash: the expression, cured.
    mutating func parseInterpolation() throws -> String {
        guard let close = Lex.closing(chars, from: pos + 1) else {
            mark(.punctuation, from: pos, to: pos + 2)
            throw Failure.incomplete("expected ')'")
        }
        mark(.punctuation, from: pos, to: pos + 2)
        let innerStart = pos + 2
        let inner = text.slice(innerStart..<close)
        mark(.punctuation, from: close, to: close + 1)
        pos = close + 1
        return try cureSlice(inner, from: innerStart)
    }

    /// `{ … }` at the brace: the closure, cured.
    mutating func parseClosure(arityOf command: Command? = nil) throws -> String {
        guard let close = Lex.closing(chars, from: pos) else {
            throw Failure.incomplete("expected '}'")
        }
        let source = text.slice(pos..<(close + 1))
        let sourceStart = pos
        pos = close + 1
        let cured = try cureSlice(source, from: sourceStart)
        // A closure word takes what its stage gives it; Swift's closure without parameters or `$0`
        // takes none.
        if SwiftProbe.isParameterlessClosure(source),
            cured.range(of: #"\$\d"#, options: .regularExpression) == nil
        {
            var name: String?
            if let command, case .text(let pieces)? = command.words.first, pieces.count == 1,
                case .literal(let literal) = pieces[0]
            {
                name = literal
            }
            let arity = name.flatMap { names.closureArities[$0] ?? front.closureArity($0) } ?? 1
            if arity > 0 {
                let body = cured.dropFirst().dropLast()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return "{ " + Array(repeating: "_", count: arity).joined(separator: ", ") + " in "
                    + body + " }"
            }
        }
        return cured
    }

    /// `(a, b: c)` at the parenthesis: what is between, cured.
    mutating func parseArguments() throws -> String {
        guard let close = Lex.closing(chars, from: pos) else {
            throw Failure.incomplete("expected ')'")
        }
        let innerStart = pos + 1
        let inner = text.slice(innerStart..<close)
        pos = close + 1
        // As the arguments of a call, so that a label is a label (`while:`, `in:`), not the start
        // of a statement.
        let cured = try cureSlice("_(\(inner))", from: innerStart, prefix: 2)
        return String(cured.dropFirst(2).dropLast())
    }

    func environment(_ name: String) -> String { "env[\"\(name)\"]!" }

    /// `$0` in a closure, or a `$` form of the shell's, at the dollar sign; nil if the dollar is
    /// just a character.
    mutating func parseDollar() throws -> String? {
        switch peek(1) {
        case let c? where Lex.isDigit(c): return nil
        case "(", "?": return try parseShellDollar()
        case let c? where Lex.isIdentifierStart(c): return try parseShellDollar()
        default: return nil
        }
    }

    /// `$(…)`, `$?` or `$name`, at the dollar sign: `capture { … }`, the variable, or the
    /// environment's.
    mutating func parseShellDollar() throws -> String? {
        switch peek(1) {
        case "(":
            mark(.punctuation, from: pos, to: pos + 2)
            guard let close = Lex.closing(chars, from: pos + 1) else {
                throw Failure.incomplete("expected ')'")
            }
            let innerStart = pos + 2
            let inner = text.slice(innerStart..<close)
            let throwing = tryDepth > 0
            mark(.punctuation, from: close, to: close + 1)
            pos = close + 1
            let program = try cureSlice(inner, from: innerStart, asExpression: false)
            return throwing ? "captureThrowing({ \(program) })" : "capture({ \(program) })"
        case "?":
            throw Failure(
                "$? isn't Swish: a captured command has its own .status, and `try` makes a failure throw"
            )
        case let c? where Lex.isIdentifierStart(c):
            let start = pos
            pos += 1
            let name = identifier()!
            pos += name.count
            mark(.variable, from: start)
            front.record(.dollar, "$" + name)
            return dollar(name)
        default:
            return nil
        }
    }

    /// The byte offset of the position, which scopes are asked by.
    var here: Int { text.byteOf[min(pos, text.count)] }

    func dollar(_ name: String) -> String {
        switch names.role(of: name, at: here) {
        case .variable?, .member?, .staticMember?: name
        default: environment(name)
        }
    }
}
