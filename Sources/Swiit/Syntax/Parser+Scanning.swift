import Foundation
import SwishKit

extension Parser {
    // MARK: Scanning

    /// Digits with optional `_` separators, which are dropped.
    package mutating func readDigits() -> String {
        var digits = ""
        while let c = peek(), Parser.isDigit(c) || c == "_" {
            if c != "_" { digits.append(c) }
            pos += 1
        }
        return digits
    }

    package func peek(_ offset: Int = 0) -> Character? {
        let index = pos + offset
        return index < chars.count ? chars[index] : nil
    }

    package func startsWith(_ text: String) -> Bool {
        var index = pos
        for c in text {
            guard index < chars.count, chars[index] == c else { return false }
            index += 1
        }
        return true
    }

    package mutating func consume(_ text: String) -> Bool {
        guard startsWith(text) else { return false }
        pos += text.count
        return true
    }

    /// The identifier starting at the current position, without consuming it.
    package func identifier() -> String? {
        guard let first = peek(), Parser.isIdentifierStart(first) else { return nil }
        var name = String(first)
        while let c = peek(name.count), Parser.isIdentifierPart(c) {
            name.append(c)
        }
        return name
    }

    /// The identifier starting at `index`, without moving.
    package func identifier(at index: Int) -> String? {
        guard index < chars.count, Parser.isIdentifierStart(chars[index]) else { return nil }
        var end = index + 1
        while end < chars.count, Parser.isIdentifierPart(chars[end]) { end += 1 }
        return String(chars[index..<end])
    }

    package func kind(of name: String) -> NameKind? {
        for scope in scopes.reversed() {
            if let kind = scope[name] { return kind }
        }
        return nil
    }

    /// Skips blanks, line continuations and comments; newlines too when
    /// asked or inside brackets.
    package mutating func skipSpaces(newlines: Bool = false) {
        while let c = peek() {
            if c == " " || c == "\t" {
                pos += 1
            } else if c == "\\" && peek(1) == "\n" {
                pos += 2
            } else if c == "\n" && (newlines || bracketDepth > 0) {
                pos += 1
            } else if (c == "/" && peek(1) == "/") || (c == "#" && pos == 0 && peek(1) == "!") {
                // `//` and `///` comments, as in Swift; `#!` only as a shebang.
                let start = pos
                while let d = peek(), d != "\n" { pos += 1 }
                mark(.comment, from: start)
            } else {
                return
            }
        }
    }

    package mutating func skipSeparators() {
        while true {
            skipSpaces()
            guard peek() == ";" || peek() == "\n" else { return }
            pos += 1
        }
    }

    package func unexpected(_ c: Character) -> SyntaxError {
        SyntaxError(c == "\n" ? "unexpected newline" : "unexpected '\(c)'")
    }

    package func expected(_ what: String) -> SyntaxError {
        guard let c = peek() else { return .incomplete("expected \(what)") }
        return SyntaxError("expected \(what), found \(c == "\n" ? "newline" : "'\(c)'")")
    }

    package static func isDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }

    /// Whether `name` can be written as a name: `count`, not `$json`.
    package static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first, isIdentifierStart(first) else { return false }
        return name.dropFirst().allSatisfy(isIdentifierPart)
    }

    package static func isIdentifierStart(_ c: Character) -> Bool {
        c == "_" || c.isLetter
    }

    package static func isIdentifierPart(_ c: Character) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }
}
