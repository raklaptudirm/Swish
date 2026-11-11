import Swiit
import Testing

@testable import SwishEngine

// What the shell says each stretch of source is, as it is typed.

@Test func highlightSpansFollowTheParse() {
    let source = #"if x > 1 { echo "hi \(x)" --flag } // note"#
    let shell = Shell()
    shell.execute("let x = 2")
    let spans = shell.highlightSpans(source)
    func kinds(_ text: String) -> [HighlightKind] {
        let chars = Array(source)
        return spans.filter { String(chars[$0.range]) == text }.map(\.kind)
    }
    #expect(kinds("if") == [.keyword])
    #expect(kinds("x") == [.variable, .variable])
    #expect(kinds("1") == [.number])
    #expect(kinds("echo") == [.command])
    #expect(kinds(#""hi \(x)""#) == [.string])
    #expect(kinds(#"\("#) == [.punctuation])
    #expect(kinds("--flag") == [.flag])
    #expect(kinds("// note") == [.comment])
}

@Test func unfinishedInputStillHighlights() {
    let spans = Shell().highlightSpans(#"echo "unterminated"#)
    #expect(spans.map(\.kind) == [.command, .string])
}

@Test func commandsAreGreenWhenTheyExist() {
    let shell = Shell()
    let styles = shell.highlightStyles("ls; nosuchcommandzz")
    #expect(styles[0] == "\u{1B}[32m")
    #expect(styles[4] == "\u{1B}[31m")
}

@Test func methodsAfterAPipeAreGreen() {
    // A member of some type is a stage after `|`, but not a command on its own.
    let shell = Shell()
    let line = "[1, 2] | contains 2; contains 2; [1] | nosuchmemberzz"
    let styles = shell.highlightStyles(line)
    let at = { (word: String, from: Int) in
        styles[
            line.range(
                of: word,
                range: line.index(line.startIndex, offsetBy: from)..<line.endIndex
            )!
            .lowerBound
            .utf16Offset(in: line)
        ]
    }
    #expect(at("contains", 0) == "\u{1B}[32m")
    #expect(at("contains", 20) == "\u{1B}[31m")
    #expect(at("nosuchmemberzz", 0) == "\u{1B}[31m")
}

@Test func redirectOperatorsHighlight() {
    let source = "sort < in e>o > out o+e>> log"
    let chars = Array(source)
    let marked = Shell().highlightSpans(source).filter { $0.kind == .punctuation }
        .map { String(chars[$0.range]) }
    #expect(marked == ["<", "e>o", ">", "o+e>>"])
}

// The completion menu (`LineEditor.Menu`).
