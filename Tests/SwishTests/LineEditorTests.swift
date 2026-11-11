import Testing

@testable import Swish

// The line editor: where text lands on a terminal, and the menu of completions.

private func menu(_ names: [String], descriptions: Bool = false) -> LineEditor.Menu {
    LineEditor.Menu(
        start: 0,
        original: "",
        candidates: names.map {
            LineEditor.Candidate(
                replacement: $0,
                display: $0,
                description: descriptions ? "d" : nil
            )
        }
    )
}

private func plain(_ lines: [String]) -> [String] {
    lines.map(LineEditor.strippingEscapes)
}

@Test func layoutWrapsAtTheWidth() {
    var layout = LineEditor.Layout(width: 10)
    layout.advance(over: "\u{1B}[32m❯\u{1B}[0m ")  // escapes take no room
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

@Test func theMenuFillsColumnsTopToBottom() {
    let names = ["aa", "bb", "cc", "dd", "ee"]
    // Columns of 4 cells on a terminal 13 wide: three of them.
    #expect(plain(menu(names).lines(width: 13, height: 10)) == ["aa  cc  ee", "bb  dd"])
}

@Test func theMenuTakesOnlyTheRowsItIsGiven() {
    var choices = menu((1...10).map { "item\($0)" }, descriptions: true)
    #expect(choices.lines(width: 40, height: 0).isEmpty)
    #expect(
        plain(choices.lines(width: 40, height: 3)) == ["item1   d", "item2   d", "rows 1–2 of 10"]
    )
    // The rows shown follow the choice.
    choices.selected = 7
    #expect(plain(choices.lines(width: 40, height: 3)).first == "item7   d")
    #expect(choices.lines(width: 40, height: 3)[1].contains("\u{1B}[7m"))
    // One row has no room to say which rows it shows.
    #expect(choices.lines(width: 40, height: 1).count == 1)
}

@Test func theMenusLinesFitTheWidth() {
    let lines = menu(["a-very-long-candidate-name"]).lines(width: 10, height: 5)
    #expect(lines.allSatisfy { LineEditor.displayWidth(of: $0) < 10 })
    #expect(plain(lines) == ["a-very-l…"])
}

@Test func theMenuIsChosenFromInOrderAndByArrow() {
    // On 13 columns: aa cc ee / bb dd.
    var choices = menu(["aa", "bb", "cc", "dd", "ee"])
    choices.move(by: -1)
    #expect(choices.selected == 4)
    choices.move(by: 1)
    #expect(choices.selected == 0)
    choices.move(columns: 1, width: 13)
    #expect(choices.selected == 2)  // cc
    choices.move(columns: 1, width: 13)
    choices.move(columns: 1, width: 13)
    #expect(choices.selected == 1)  // past ee, on to the next row: bb
    choices.move(columns: -1, width: 13)
    #expect(choices.selected == 4)  // back past bb, to the row before's end: ee
    choices.move(rows: 1, width: 13)
    #expect(choices.selected == 0)
}
