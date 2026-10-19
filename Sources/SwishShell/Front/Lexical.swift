import Foundation

// Spike: the shell's own text, read by the shell. Nothing here knows the interpreter: this is the lexical level of Swift's
// text with the shell's in it (strings and their interpolations, comments, brackets), enough to find where a form ends.

/// The characters of a source, and what its bytes are (SwiftParser's positions are bytes).
struct Text {
    let chars: [Character]
    /// The byte offset each character starts at, and the end.
    let byteOf: [Int]

    init(_ source: String) { self.init(Array(source)) }

    init(_ chars: [Character]) {
        self.chars = chars
        var offsets: [Int] = []
        var bytes = 0
        for c in chars {
            offsets.append(bytes)
            bytes += String(c).utf8.count
        }
        offsets.append(bytes)
        byteOf = offsets
    }

    var string: String { String(chars) }
    var count: Int { chars.count }

    func slice(_ range: Range<Int>) -> String { String(chars[range]) }

    /// The character that starts at (or contains) a byte offset.
    func character(atByte byte: Int) -> Int {
        var low = 0, high = byteOf.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if byteOf[middle] <= byte { low = middle } else { high = middle - 1 }
        }
        return low
    }
}

enum Lex {
    static func isIdentifierStart(_ c: Character) -> Bool { c == "_" || c.isLetter }
    static func isIdentifierPart(_ c: Character) -> Bool { isIdentifierStart(c) || isDigit(c) }
    static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
    /// Whether `name` can be written as a name: `count`, not `$json`.
    static func isIdentifier(_ name: String) -> Bool {
        guard let first = name.first, isIdentifierStart(first) else { return false }
        return name.dropFirst().allSatisfy(isIdentifierPart)
    }

    /// The index of the bracket that closes the one at `open`, skipping strings (a shell's `'…'` too) and comments.
    static func closing(_ chars: [Character], from open: Int) -> Int? {
        var stack: [Character] = []
        var i = open
        while i < chars.count {
            let c = chars[i]
            switch c {
            case "(": stack.append(")"); i += 1
            case "[": stack.append("]"); i += 1
            case "{": stack.append("}"); i += 1
            case ")", "]", "}":
                guard stack.last == c else { return nil }
                stack.removeLast()
                if stack.isEmpty { return i }
                i += 1
            case "\"": i = skipString(chars, from: i)
            case "'": i = skipRaw(chars, from: i)
            case "/" where i + 1 < chars.count && chars[i + 1] == "/": i = skipLine(chars, from: i)
            case "/" where i + 1 < chars.count && chars[i + 1] == "*": i = skipBlockComment(chars, from: i)
            default: i += 1
            }
        }
        return nil
    }

    /// Past a double-quoted string starting at `start`, its interpolations (`\(…)`, and `$(…)` as a command's word has it) included.
    static func skipString(_ chars: [Character], from start: Int) -> Int {
        var i = start + 1
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                if chars[i + 1] == "(" {
                    guard let close = closing(chars, from: i + 1) else { return chars.count }
                    i = close + 1
                } else {
                    i += 2
                }
            } else if c == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                guard let close = closing(chars, from: i + 1) else { return chars.count }
                i = close + 1
            } else if c == "\"" {
                return i + 1
            } else {
                i += 1
            }
        }
        return chars.count
    }

    static func skipRaw(_ chars: [Character], from start: Int) -> Int {
        var i = start + 1
        while i < chars.count, chars[i] != "'" { i += 1 }
        return min(i + 1, chars.count)
    }

    static func skipLine(_ chars: [Character], from start: Int) -> Int {
        var i = start
        while i < chars.count, chars[i] != "\n" { i += 1 }
        return i
    }

    static func skipBlockComment(_ chars: [Character], from start: Int) -> Int {
        var depth = 0
        var i = start
        while i < chars.count {
            if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" { depth += 1; i += 2 }
            else if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "/" {
                depth -= 1
                i += 2
                if depth == 0 { return i }
            } else { i += 1 }
        }
        return chars.count
    }

    /// Each outermost `$(…)` of the code: from the `$` to the `)` that closes it, or to the end when it is left open.
    /// Strings are skipped, except for the code in their interpolations.
    static func substitutions(in chars: [Character]) -> (ranges: [Range<Int>], unclosed: Bool) {
        let found = scan(chars)
        return (found.substitutions, found.unclosed)
    }

    /// Each `'…'` in the code, outside the substitutions: the shell's raw strings, which Swift has no spelling for.
    static func rawStrings(in chars: [Character]) -> [Range<Int>] { scan(chars).rawStrings }

    private static func scan(_ chars: [Character]) -> (substitutions: [Range<Int>], rawStrings: [Range<Int>], unclosed: Bool) {
        var ranges: [Range<Int>] = []
        var raws: [Range<Int>] = []
        var unclosed = false
        let n = chars.count

        /// Scans code from `start`; stops at the `)` that ends an interpolation when `inInterpolation`.
        func code(from start: Int, inInterpolation: Bool) -> Int {
            var i = start
            var depth = 0
            while i < n {
                let c = chars[i]
                switch c {
                case "/" where i + 1 < n && chars[i + 1] == "/": i = skipLine(chars, from: i)
                case "/" where i + 1 < n && chars[i + 1] == "*": i = skipBlockComment(chars, from: i)
                case "'":
                    let end = skipRaw(chars, from: i)
                    raws.append(i..<end)
                    i = end
                case "\"": i = string(from: i)
                case "$" where i + 1 < n && chars[i + 1] == "(":
                    if let close = closing(chars, from: i + 1) {
                        ranges.append(i..<(close + 1))
                        i = close + 1
                    } else {
                        ranges.append(i..<n)
                        unclosed = true
                        i = n
                    }
                case "(": depth += 1; i += 1
                case ")":
                    if inInterpolation && depth == 0 { return i }
                    depth -= 1
                    i += 1
                default: i += 1
                }
            }
            return n
        }

        /// Past a string, looking for substitutions only in its interpolations.
        func string(from start: Int) -> Int {
            var i = start + 1
            while i < n {
                let c = chars[i]
                if c == "\\", i + 1 < n {
                    if chars[i + 1] == "(" {
                        i = code(from: i + 2, inInterpolation: true) + 1
                    } else {
                        i += 2
                    }
                } else if c == "\"" {
                    return i + 1
                } else {
                    i += 1
                }
            }
            return n
        }

        _ = code(from: 0, inInterpolation: false)
        return (ranges.sorted { $0.lowerBound < $1.lowerBound }, raws.sorted { $0.lowerBound < $1.lowerBound }, unclosed)
    }

    /// The code with what is inside each `$(…)` replaced by blanks (newlines stay), so SwiftParser reads the call `$()` and
    /// leaves the shell's text to the reader; the same length, so positions agree.
    static func blankingSubstitutions(_ chars: [Character]) -> [Character] {
        let found = substitutions(in: chars)
        guard !found.ranges.isEmpty else { return chars }
        var blanked = chars
        for range in found.ranges {
            let inner = (range.lowerBound + 2)..<(found.unclosed && range.upperBound == chars.count ? range.upperBound : range.upperBound - 1)
            guard inner.lowerBound < inner.upperBound else { continue }
            for index in inner where blanked[index] != "\n" { blanked[index] = " " }
        }
        return blanked
    }

    /// The code with what is inside each outermost `{ … }` replaced by blanks: the statements in a closure's body are read
    /// in their turn, so what a stretch of code is (where it ends) is asked with the bodies left out.
    static func blankingBlocks(_ chars: [Character]) -> [Character] {
        var blanked = chars
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "/" where i + 1 < chars.count && chars[i + 1] == "/": i = skipLine(chars, from: i)
            case "/" where i + 1 < chars.count && chars[i + 1] == "*": i = skipBlockComment(chars, from: i)
            case "'": i = skipRaw(chars, from: i)
            case "\"": i = skipString(chars, from: i)
            case "{":
                guard let close = closing(chars, from: i) else { return blanked }
                for index in (i + 1)..<close where blanked[index] != "\n" { blanked[index] = " " }
                i = close + 1
            default: i += 1
            }
        }
        return blanked
    }

    /// The code up to the first `{` that is not inside brackets: in a condition, that brace opens the body.
    static func truncatingAtBlock(_ chars: [Character]) -> [Character] {
        var depth = 0
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "/" where i + 1 < chars.count && chars[i + 1] == "/": i = skipLine(chars, from: i)
            case "/" where i + 1 < chars.count && chars[i + 1] == "*": i = skipBlockComment(chars, from: i)
            case "'": i = skipRaw(chars, from: i)
            case "\"": i = skipString(chars, from: i)
            case "(", "[": depth += 1; i += 1
            case ")", "]": depth -= 1; i += 1
            case "{":
                if depth <= 0 { return Array(chars[..<i]) }
                i += 1
            default: i += 1
            }
        }
        return chars
    }
}
