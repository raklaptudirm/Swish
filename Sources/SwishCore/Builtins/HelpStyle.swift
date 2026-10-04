import Foundation
import SwishKit

/// How `help` is colored: the colors the highlighter gives the same things
/// (keywords, types, names that run, flags, constants), so a signature reads
/// as it would in code.
enum HelpStyle {
    static let heading = DisplayStyle.bold
    static let keyword = DisplayStyle.magenta
    static let type = DisplayStyle.brightYellow
    static let name = DisplayStyle.green
    static let flag = DisplayStyle.blue
    static let parameter = DisplayStyle.cyan
    static let constant = DisplayStyle.brightMagenta
    static let string = DisplayStyle.yellow
    static let secondary = DisplayStyle.dim

    private static let keywords: Set = [
        "init", "case", "mutating", "static", "throws", "rethrows", "func", "let", "var", "get", "set", "inout", "some", "any", "where",
    ]

    /// A Swift declaration's text in pieces by what each is: its keywords,
    /// its name, parameter labels and names, types, numbers and strings.
    static func signature(_ text: String) -> [StyledText.Segment] {
        var segments: [StyledText.Segment] = []
        var plain = ""
        func flush() {
            if !plain.isEmpty { segments.append(.init(plain)); plain = "" }
        }
        func add(_ piece: String, _ style: DisplayStyle) {
            flush()
            segments.append(.init(piece, style))
        }
        let chars = Array(text)
        var depth = 0
        var named = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isLetter || c == "_" {
                var j = i
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" { j += 1 }
                let word = String(chars[i..<j])
                var k = j
                while k < chars.count, chars[k] == " " { k += 1 }
                let next = k < chars.count ? chars[k] : nil
                // `where` in `contains(where:)` is a label, though a keyword
                // elsewhere; `throws`, `inout` and `some` are keywords anywhere.
                let canBeLabel = depth > 0 && !["throws", "rethrows", "inout", "some", "any"].contains(word)
                    && (next == ":" || next.map { $0.isLetter || $0 == "_" } == true)
                if canBeLabel && keywords.contains(word) {
                    add(word, parameter)
                } else if keywords.contains(word) {
                    add(word, keyword)
                } else if word == "_" {
                    plain += word
                } else if depth == 0 && !named && (next == "(" || next == ":" || next == nil || next == "{" || next == "<") {
                    // The member's name, before its parameters or its type.
                    named = true
                    add(word, name)
                } else if word.first!.isUppercase {
                    add(word, type)
                } else if depth > 0 && (next == ":" || next.map { $0.isLetter || $0 == "_" } == true) {
                    add(word, parameter)
                } else {
                    plain += word
                }
                i = j
            } else if c.isNumber {
                var j = i
                while j < chars.count, chars[j].isNumber || chars[j] == "." { j += 1 }
                add(String(chars[i..<j]), constant)
                i = j
            } else if c == "\"" {
                var j = i + 1
                while j < chars.count, chars[j] != "\"" { j += 1 }
                add(String(chars[i..<min(j + 1, chars.count)]), string)
                i = min(j + 1, chars.count)
            } else {
                if c == "(" || c == "<" { depth += 1 }
                if c == ")" || c == ">" && !(i > 0 && chars[i - 1] == "-") { depth = max(0, depth - 1) }
                plain.append(c)
                i += 1
            }
        }
        flush()
        return segments
    }

    /// A usage or option: `--name`, `-a`, `<value>` and the rest, each colored
    /// as what it is, the command's name first.
    static func usage(_ text: String) -> [StyledText.Segment] {
        var segments: [StyledText.Segment] = []
        var first = true
        for (index, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { segments.append(.init(" ")) }
            segments += usageWord(String(word), isName: first && !word.isEmpty)
            if !word.isEmpty { first = false }
        }
        return segments
    }

    private static func usageWord(_ word: String, isName: Bool) -> [StyledText.Segment] {
        if isName { return [.init(word, name)] }
        // Brackets and bars around a flag or a placeholder stay plain.
        var segments: [StyledText.Segment] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            let style: DisplayStyle? = current.hasPrefix("-") ? flag : current.hasPrefix("<") ? parameter : nil
            segments.append(.init(current, style))
            current = ""
        }
        for c in word {
            if "[]|".contains(c) {
                flush()
                segments.append(.init(String(c)))
            } else {
                current.append(c)
            }
        }
        flush()
        return segments
    }
}

extension StyledText {
    /// One piece of a line: with a style, or without.
    static func line(_ segments: [Segment]) -> StyledText { StyledText(segments) }

    /// The width it takes on a line.
    var width: Int { text.count }

    /// As a String: with the terminal's escapes if `styled`.
    func rendered(_ styled: Bool) -> String { styled ? colored : text }
}
