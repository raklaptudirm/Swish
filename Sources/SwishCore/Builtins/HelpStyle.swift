import Foundation
import SwishKit

/// How `help` is colored: with the roles `DisplayStyle` names, the colors the
/// highlighter gives the same things, so a signature reads as it would in code.
enum HelpStyle {
    /// A hand-written usage (a shell builtin's): `--name`, `-a`, `<value>` and
    /// the rest, each colored as what it is, the command's name first. A
    /// function's usage is built from its parameters instead.
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
        if isName { return [.init(word, .command)] }
        // Brackets and bars around a flag or a placeholder stay plain.
        var segments: [StyledText.Segment] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            let style: DisplayStyle? = current.hasPrefix("-") ? .flag : current.hasPrefix("<") ? .variable : nil
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
