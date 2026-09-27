@testable import SwishCore
import Testing

// MARK: History

@Test func historyEscapesMultiLineEntries() {
    let entry = "if true {\n  echo \\n\n}"
    #expect(History.encode(entry) == #"if true {\n  echo \\n\n}"#)
    #expect(History.decode(History.encode(entry)) == entry)
}

@Test func historyPersistsAndSkipsRepeats() throws {
    let shell = Shell()
    let path = try shell.capturing { shell.execute("mktemp") }.trimmingCharacters(in: .newlines)
    let history = History(path: path)
    history.add("echo one")
    history.add("echo one")
    history.add("   ")
    history.add("if x {\n}")
    #expect(History(path: path).entries == ["echo one", "if x {\n}"])
    #expect(History(path: path, limit: 1).entries == ["if x {\n}"])
    #expect(History(path: path).entries == ["if x {\n}"]) // trimmed on disk too
}

// MARK: Layout

@Test func layoutWrapsAtTheWidth() {
    var layout = LineEditor.Layout(width: 10)
    layout.advance(over: "\u{1B}[32m❯\u{1B}[0m ") // escapes take no room
    #expect(layout.position == (0, 2))
    for _ in 0..<8 { layout.advance(by: 1) }
    // Exactly full: the terminal waits to wrap, so the cursor reads as the
    // next row's start.
    #expect(layout.rawPosition == (0, 10))
    #expect(layout.position == (1, 0))
    layout.advance(by: 1)
    #expect(layout.position == (1, 1))
}

@Test func wideCharactersWrapWhole() {
    var layout = LineEditor.Layout(width: 4)
    layout.advance(by: 1)
    layout.advance(by: 1)
    layout.advance(by: 1)
    layout.advance(by: LineEditor.displayWidth(of: Character("漢")))
    #expect(layout.position == (1, 2))
}

@Test func characterWidths() {
    #expect(LineEditor.displayWidth(of: Character("a")) == 1)
    #expect(LineEditor.displayWidth(of: Character("漢")) == 2)
    #expect(LineEditor.displayWidth(of: Character("😀")) == 2)
    #expect(LineEditor.displayWidth(of: Character("e\u{301}")) == 1)
    #expect(LineEditor.displayWidth(of: "\u{1B}[1mab\u{1B}[0m") == 2)
}

// MARK: Completion

private func completion(_ text: String, in shell: Shell = Shell()) -> (start: Int, replacements: [String]) {
    let result = shell.completions(for: text, cursor: text.count)
    return (result?.start ?? -1, result?.candidates.map(\.replacement) ?? [])
}

@Test func completesCommandsIncludingFunctions() {
    let shell = Shell()
    shell.execute("# Greets.\nfunc zzgreet() {}")
    let result = shell.completions(for: "zzg", cursor: 3)
    #expect(result?.candidates == [LineEditor.Candidate(replacement: "zzgreet", display: "zzgreet", description: "Greets.")])
    #expect(completion("ech").replacements.contains("echo"))
    #expect(completion("if tru && ls | wher").replacements.contains("where")) // after a pipe: command position
    #expect(completion("^zzg", in: shell).replacements.isEmpty) // ^ is externals only
}

@Test func completesFlagsFromSignatures() {
    let shell = Shell()
    shell.execute(#"func f(@flag("n") times: Int = 1, color: Bool = true) {}"#)
    #expect(completion("f --", in: shell).replacements == ["--color", "--help", "--no-color", "--times"])
    #expect(completion("f -", in: shell).replacements.contains("-n"))
    #expect(completion("sort --r").replacements == ["--reverse"])
}

@Test func completesVariables() {
    let shell = Shell()
    shell.execute("let zzvalue = 1")
    #expect(completion("echo $zzv", in: shell).replacements == ["$zzvalue"])
    #expect(completion("echo $HOM").replacements.contains("$HOME"))
}

@Test func completesPathsEscapingSpaces() throws {
    let shell = Shell()
    let dir = try shell.capturing { shell.execute("mktemp -d") }.trimmingCharacters(in: .newlines)
    shell.execute("mkdir '\(dir)/a dir'; touch \(dir)/afile \(dir)/.hidden")
    let result = shell.completions(for: "cat \(dir)/a", cursor: "cat \(dir)/a".count)
    #expect(result?.start == 4)
    #expect(result?.candidates.map(\.replacement) == ["\(dir)/a\\ dir", "\(dir)/afile"])
    #expect(result?.candidates.map(\.suffix) == ["/", " "])
    #expect(completion("cat \(dir)/.h").replacements == ["\(dir)/.hidden"])
    #expect(completion("cat \"\(dir)/af").replacements == ["\"\(dir)/afile"])
}

// MARK: Highlighting

@Test func highlightSpansFollowTheParse() {
    let source = #"if x > 1 { echo "hi \(x)" --flag } # note"#
    let spans = Parser.highlight(source, bound: ["x": .variable])
    func kinds(_ text: String) -> [SpanKind] {
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
    #expect(kinds("# note") == [.comment])
}

@Test func unfinishedInputStillHighlights() {
    let spans = Parser.highlight(#"echo "unterminated"#, bound: [:])
    #expect(spans.map(\.kind) == [.command, .string])
}

@Test func commandsAreGreenWhenTheyExist() {
    let shell = Shell()
    let styles = shell.highlightStyles("ls; nosuchcommandzz")
    #expect(styles[0] == "\u{1B}[32m")
    #expect(styles[4] == "\u{1B}[31m")
}

@Test func redirectOperatorsHighlight() {
    let source = "sort < in 2>&1 > out"
    let chars = Array(source)
    let marked = Parser.highlight(source, bound: [:]).filter { $0.kind == .punctuation }.map { String(chars[$0.range]) }
    #expect(marked == ["<", "2>&1", ">"])
}
