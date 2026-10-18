import Foundation

extension SourceReader {
    // MARK: Quotes and interpolation in a command's words

    /// `'text'`, positioned at the opening quote: the text, as it is.
    mutating func parseRawString() throws(ParseFailure) -> String {
        guard let end = characters[(position + 1)...].firstIndex(of: "'") else {
            mark(.string, from: position, to: characters.count)
            throw ParseFailure.incomplete("unterminated string")
        }
        let text = String(characters[(position + 1)..<end])
        mark(.string, from: position, to: end + 1)
        position = end + 1
        return text
    }

    /// A double-quoted word: Swift's escapes and `\(…)`, and `$name` and `$(…)`
    /// as a command's words have them, so `"costs $5"` keeps its `$5`.
    mutating func parseInterpolatedString() throws(ParseFailure) -> [StringPiece] {
        let start = position
        position += 1
        var parts: [StringPiece] = []
        var literal = ""
        while true {
            guard let c = peek() else {
                mark(.string, from: start, to: characters.count)
                throw ParseFailure.incomplete("unterminated string")
            }
            switch c {
            case "\"":
                position += 1
                mark(.string, from: start)
                if !literal.isEmpty || parts.isEmpty { parts.append(.literal(literal)) }
                return parts
            case "\\":
                guard let next = peek(1) else {
                    mark(.string, from: start, to: characters.count)
                    throw ParseFailure.incomplete("unterminated string")
                }
                if next == "(" {
                    if !literal.isEmpty { parts.append(.literal(literal)) }
                    literal = ""
                    parts.append(.expression(try parseInterpolation()))
                    continue
                }
                position += 2
                switch next {
                case "n": literal.append("\n")
                case "t": literal.append("\t")
                case "r": literal.append("\r")
                case "0": literal.append("\0")
                case "\\", "\"", "'", "$": literal.append(next)
                case "u": literal.append(try parseUnicodeEscape())
                default: throw ParseFailure("invalid escape '\\\(next)' in string: write \\\\ for a backslash, or use single quotes to keep every backslash")
                }
            case "$":
                if let expr = try parseDollar() {
                    if !literal.isEmpty { parts.append(.literal(literal)) }
                    literal = ""
                    parts.append(.expression(expr))
                } else {
                    literal.append(c)
                    position += 1
                }
            default:
                literal.append(c)
                position += 1
            }
        }
    }

    /// `\u{1F600}`, positioned after the `u`.
    mutating func parseUnicodeEscape() throws(ParseFailure) -> Character {
        guard consume("{") else { throw ParseFailure("expected '{' after '\\u'") }
        var hex = ""
        while let c = peek(), c.isHexDigit {
            hex.append(c)
            position += 1
        }
        guard consume("}"), let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw ParseFailure("invalid unicode escape '\\u{\(hex)'")
        }
        return Character(scalar)
    }

    /// `\(expression)`, positioned at the backslash.
    mutating func parseInterpolation() throws(ParseFailure) -> SwiftExpression {
        mark(.punctuation, from: position, to: position + 2)
        position += 2
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        skipSpaces()
        let expr = try parseExpression()
        skipSpaces()
        guard consume(")") else { throw expected("')'") }
        mark(.punctuation, from: position - 1)
        return expr
    }

    /// Digits with optional `_` separators, which are dropped.
    mutating func readDigits() -> String {
        var digits = ""
        while let c = peek(), SourceReader.isDigit(c) || c == "_" {
            if c != "_" { digits.append(c) }
            position += 1
        }
        return digits
    }

    /// `$0` in a closure, or a `$` form of the shell's (`$(…)`, `$name`),
    /// positioned at the dollar sign; nil if the dollar is just a character.
    mutating func parseDollar() throws(ParseFailure) -> SwiftExpression? {
        switch peek(1) {
        case let c? where SourceReader.isDigit(c):
            // Only special in a closure without named parameters; elsewhere,
            // as in "costs $5", it's just text.
            guard inAnonymousClosure else { return nil }
            let start = position
            position += 1
            guard let index = Int(readDigits()) else { throw ParseFailure("closure parameter number is too large") }
            mark(.variable, from: start)
            return .closureParameter(index)
        case "(", "?":
            return try parseShellDollar()
        case let c? where SourceReader.isIdentifierStart(c):
            return try parseShellDollar()
        default:
            return nil
        }
    }
}
