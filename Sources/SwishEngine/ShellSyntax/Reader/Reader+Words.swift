import Foundation

// A command's words: bare words, quoted and interpolated strings, escapes.

extension Reader {
    mutating func parseWord() throws -> [Piece] {
        var parts: [Piece] = []
        var literal = ""
        var wildcard = false
        func flush() {
            if !literal.isEmpty { parts.append(wildcard ? .glob(literal) : .literal(literal)) }
            literal = ""
            wildcard = false
        }

        if peek() == "~", peek(1).map({ $0 == "/" || isWordBoundary($0) }) ?? true {
            parts.append(.expression(environment("HOME")))
            pos += 1
        }

        while let c = peek() {
            if c == "{" && peek(1) == "}" {
                literal += "{}"
                pos += 2
                continue
            }
            if isWordBoundary(c) { break }
            switch c {
            case "'":
                flush()
                parts.append(.literal(try parseRawString()))
            case "\"":
                flush()
                parts += try parseInterpolatedString()
            case "\\":
                guard let next = peek(1) else {
                    throw Failure.incomplete("expected a character after '\\'")
                }
                if next == "(" {
                    flush()
                    parts.append(.spread(try parseInterpolation()))
                } else if next == "\n" {
                    pos += 2
                } else if "*[".contains(next) {
                    flush()
                    parts.append(.literal(String(next)))
                    pos += 2
                } else {
                    literal.append(next)
                    pos += 2
                }
            case "$":
                if let expr = try parseDollar() {
                    flush()
                    parts.append(.spread(expr))
                } else {
                    literal.append(c)
                    pos += 1
                }
            default:
                if "*[".contains(c) { wildcard = true }
                literal.append(c)
                pos += 1
            }
        }

        flush()
        return parts
    }

    mutating func parseRawString() throws -> String {
        guard let end = chars[(pos + 1)...].firstIndex(of: "'") else {
            mark(.string, from: pos, to: chars.count)
            throw Failure.incomplete("unterminated string")
        }
        let text = String(chars[(pos + 1)..<end])
        mark(.string, from: pos, to: end + 1)
        pos = end + 1
        return text
    }

    mutating func parseInterpolatedString() throws -> [Piece] {
        let start = pos
        pos += 1
        var parts: [Piece] = []
        var literal = ""

        while true {
            guard let c = peek() else {
                mark(.string, from: start, to: chars.count)
                throw Failure.incomplete("unterminated string")
            }

            switch c {
            case "\"":
                pos += 1
                mark(.string, from: start)
                if !literal.isEmpty || parts.isEmpty { parts.append(.literal(literal)) }
                return parts
            case "\\":
                guard let next = peek(1) else {
                    mark(.string, from: start, to: chars.count)
                    throw Failure.incomplete("unterminated string")
                }
                if next == "(" {
                    if !literal.isEmpty { parts.append(.literal(literal)) }
                    literal = ""
                    parts.append(.expression(try parseInterpolation()))
                    continue
                }
                pos += 2
                switch next {
                case "n": literal.append("\n")
                case "t": literal.append("\t")
                case "r": literal.append("\r")
                case "0": literal.append("\0")
                case "\\", "\"", "'", "$": literal.append(next)
                case "u": literal.append(try parseUnicodeEscape())
                default:
                    throw Failure(
                        "invalid escape '\\\(next)' in string: write \\\\ for a backslash, or use single quotes to keep every backslash"
                    )
                }
            case "$":
                if let expr = try parseDollar() {
                    if !literal.isEmpty { parts.append(.literal(literal)) }
                    literal = ""
                    parts.append(.expression(expr))
                } else {
                    literal.append(c)
                    pos += 1
                }
            default:
                literal.append(c)
                pos += 1
            }
        }
    }

    mutating func parseUnicodeEscape() throws -> Character {
        guard consume("{") else { throw Failure("expected '{' after '\\u'") }
        var hex = ""
        while let c = peek(), c.isHexDigit {
            hex.append(c)
            pos += 1
        }
        guard consume("}"), let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value)
        else {
            throw Failure("invalid unicode escape '\\u{\(hex)'")
        }
        return Character(scalar)
    }
}
