import Foundation

// The reader's primitives: looking at characters, consuming them, skipping space.

extension Reader {
    func peek(_ offset: Int = 0) -> Character? {
        let index = pos + offset
        return index < chars.count ? chars[index] : nil
    }

    func startsWith(_ s: String) -> Bool {
        var index = pos
        for c in s {
            guard index < chars.count, chars[index] == c else { return false }
            index += 1
        }
        return true
    }

    mutating func consume(_ s: String) -> Bool {
        guard startsWith(s) else { return false }
        pos += s.count
        return true
    }

    func identifier() -> String? {
        guard let first = peek(), Lex.isIdentifierStart(first) else { return nil }
        var name = String(first)
        while let c = peek(name.count), Lex.isIdentifierPart(c) { name.append(c) }
        return name
    }

    mutating func skipSpaces(newlines: Bool = false) {
        while let c = peek() {
            if c == " " || c == "\t" {
                pos += 1
            } else if c == "\\" && peek(1) == "\n" {
                pos += 2
            } else if c == "\n" && newlines {
                pos += 1
            } else if (c == "/" && peek(1) == "/") || (c == "#" && pos == 0 && peek(1) == "!") {
                let start = pos
                while let d = peek(), d != "\n" { pos += 1 }
                mark(.comment, from: start)
            } else {
                return
            }
        }
    }

    func isWordBoundary(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || "|;&(){}<>".contains(c)
    }

    func expected(_ what: String) -> Failure {
        guard let c = peek() else { return .incomplete("expected \(what)") }
        return Failure("expected \(what), found \(c == "\n" ? "newline" : "'\(c)'")")
    }
}
