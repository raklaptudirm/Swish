import Foundation
import Swiit

/// An interactive line editor: syntax highlighting, completion, history
/// with prefix and incremental search, and multi-line input that wraps.
/// Falls back to plain `readLine` when stdin isn't a terminal.
final class LineEditor {
    enum Input {
        case line(String)
        /// ^C: abandon the input.
        case interrupted
        case eof
    }

    struct Candidate: Equatable {
        /// What replaces the word being completed, escaped as needed.
        var replacement: String
        /// Added after a unique completion: a space, or nothing after a directory.
        var suffix = " "
        /// Shown in the list of candidates.
        var display: String
        var description: String?
    }

    struct Completion {
        /// Where the word being completed starts, in characters.
        var start: Int
        var candidates: [Candidate]
    }

    var history = History(path: nil)
    /// Whether Enter should run the input, or it's unfinished (an open
    /// block, say) and Enter starts a new line.
    var isComplete: (String) -> Bool = { _ in true }
    /// An ANSI style for each character of the input, or nil for none.
    var highlight: (String) -> [String?] = { _ in [] }
    var complete: (String, Int) -> Completion? = { _, _ in nil }
    var continuationPrompt = "… "

    private enum Key {
        case character(Character)
        case enter, newline, interrupt, eof, tab, backTab, search, cancel, escape
        case backspace, delete, deleteWord, killToEnd, killToStart
        case left, right, wordLeft, wordRight, home, end, up, down
        case clearScreen, ignored
    }

    private let input = STDIN_FILENO
    private let output = STDOUT_FILENO

    private var buffer: [Character] = []
    private var cursor = 0
    private var prompt = ""
    /// The cursor's row in the last render, counted from the prompt's row,
    /// to get back to the start before drawing again.
    private var renderedCursorRow = 0
    private var pendingKey: Key?
    /// Bytes read while waiting for something else (the terminal's answer to a question), to be
    /// read as keys after.
    private var queuedBytes: [UInt8] = []

    /// The completion menu, while it's open, and the row of the screen the prompt is on, which
    /// says how many rows under the input are free for it.
    private var menu: Menu?
    private var promptRow: Int?

    /// Browsing history: the entry shown, the text typed before browsing
    /// started, and the prefix entries must match (what was typed).
    private var historyIndex = 0
    private var draft: [Character] = []
    private var historyPrefix = ""

    func readLine(prompt: String) -> Input {
        guard isatty(input) != 0 else { return Swift.readLine().map(Input.line) ?? .eof }

        var original = termios()
        tcgetattr(input, &original)
        var raw = original
        raw.c_iflag &= ~tcflag_t(BRKINT | ICRNL | INPCK | ISTRIP | IXON)
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON | IEXTEN | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        // TCSANOW: TCSAFLUSH would discard typeahead, and TCSADRAIN can block
        // indefinitely on macOS ptys. Output processing is untouched, so
        // there's nothing to drain anyway.
        tcsetattr(input, TCSANOW, &raw)
        defer { tcsetattr(input, TCSANOW, &original) }

        self.prompt = prompt
        buffer = []
        cursor = 0
        renderedCursorRow = 0
        closeMenu()
        startedEditing()
        refresh()
        return edit()
    }

    // MARK: Editing

    private func edit() -> Input {
        while let key = nextKey() {
            let menuStart = menu?.start
            if menuTook(key) {
                if !inputPending() { refresh() }
                continue
            }
            switch key {
            case .character(let character):
                if !inputPending(),
                    "}])".contains(character) && cursorIsInIndentation
                        || startsCase(typing: character)
                {
                    dedentLine()
                }
                insert([character])
            case .enter:
                let text = String(buffer)
                if isComplete(text) { return accept() }
                insertNewline()
            case .newline:
                insertNewline()
            case .interrupt:
                moveToEnd()
                writeOut("^C\n")
                return .interrupted
            case .eof:
                if buffer.isEmpty {
                    writeOut("\n")
                    return .eof
                }
                if cursor < buffer.count { remove(cursor..<cursor + 1) }
            case .backspace:
                if cursor > 0 { remove(cursor - 1..<cursor) }
            case .delete:
                if cursor < buffer.count { remove(cursor..<cursor + 1) }
            case .deleteWord:
                remove(wordStart(before: cursor)..<cursor)
            case .killToEnd:
                remove(cursor..<lineEnd(from: cursor))
            case .killToStart:
                remove(lineStart(from: cursor)..<cursor)
            case .left:
                cursor = max(cursor - 1, 0)
            case .right:
                cursor = min(cursor + 1, buffer.count)
            case .wordLeft:
                cursor = wordStart(before: cursor)
            case .wordRight:
                cursor = wordEnd(after: cursor)
            case .home:
                cursor = lineStart(from: cursor)
            case .end:
                cursor = lineEnd(from: cursor)
            case .up:
                if !moveVertically(by: -1) { browseHistory(by: -1) }
            case .down:
                if !moveVertically(by: 1) { browseHistory(by: 1) }
            case .tab:
                completeWord()
            case .backTab:
                break
            case .search:
                if let result = search() { return result }
            case .clearScreen:
                writeOut("\u{1B}[H\u{1B}[2J")
                renderedCursorRow = 0
            case .cancel, .escape, .ignored:
                break
            }
            switch (key, menuStart) {
            case (.character, let start?), (.backspace, let start?), (.deleteWord, let start?):
                refineMenu(from: start)
            default:
                break
            }
            if menu == nil { promptRow = nil }
            // Typeahead and pastes arrive many keys at once; drawing once
            // they've all been handled keeps the output from growing with
            // every key, which a slow terminal or an SSH link would feel.
            if !inputPending() { refresh() }
        }
        return .eof
    }

    private func inputPending() -> Bool {
        if pendingKey != nil || !queuedBytes.isEmpty { return true }
        var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 0) > 0
    }

    private func accept() -> Input {
        let text = String(buffer)
        moveToEnd()
        writeOut("\n")
        history.add(text)
        return .line(text)
    }

    private func insert(_ characters: [Character]) {
        buffer.insert(contentsOf: characters, at: cursor)
        cursor += characters.count
        startedEditing()
    }

    /// One level of indentation.
    private static let indentation = "    "

    /// A new line after the cursor, indented as the line it follows is, and a level deeper if that
    /// one opens a block (`{`, `(`, `[`, or a `case …:`). Text pasted arrives with its own
    /// indentation, so with more input waiting there is none.
    private func insertNewline() {
        guard !inputPending() else { return insert(["\n"]) }
        let line = buffer[lineStart(from: cursor)..<cursor]
        var indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        if let last = trimmed.last(where: { $0 != " " && $0 != "\t" }) {
            let words =
                String(trimmed).split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            if "{([".contains(last)
                || last == ":" && (words == "case" || words == "default:" || words == "default")
            {
                indent += LineEditor.indentation
            }
        }
        insert(["\n"] + Array(indent))
    }

    /// Whether only indentation lies between the start of the line and the cursor.
    private var cursorIsInIndentation: Bool {
        let before = buffer[lineStart(from: cursor)..<cursor]
        return !before.isEmpty && before.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Takes the cursor's line back a level, wherever on the line the cursor is.
    private func dedentLine() {
        let start = lineStart(from: cursor)
        let indent = buffer[start...].prefix { $0 == " " || $0 == "\t" }
        guard let last = indent.last else { return }

        let removed = last == "\t" ? 1 : min(indent.count, LineEditor.indentation.count)
        let end = start + indent.count
        buffer.removeSubrange(end - removed..<end)
        cursor -= removed
        startedEditing()
    }

    /// Whether the character being typed finishes a `case ` or `default:` that is first on its line,
    /// under the body of an earlier case. That body is a level deeper than its `case`, and a new
    /// `case` belongs back with the old one.
    private func startsCase(typing character: Character) -> Bool {
        let start = lineStart(from: cursor)
        let line = buffer[start..<cursor]
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let word = String(line.dropFirst(indent.count))
        guard (character == " " && word == "case") || (character == ":" && word == "default")
        else { return false }

        // The nearest line above that is indented less is the one this line's block belongs to.
        var end = start
        while end > 0 {
            let previousStart = lineStart(from: end - 1)
            let previous = String(buffer[previousStart..<(end - 1)])
            end = previousStart
            let text = previous.drop { $0 == " " || $0 == "\t" }
            let previousIndent = String(previous.prefix { $0 == " " || $0 == "\t" })
            guard !text.isEmpty, previousIndent.count < indent.count else { continue }

            let isCase = text.hasPrefix("case ") || text.hasPrefix("default")
            return isCase
                && (indent == previousIndent + "\t"
                    || indent == previousIndent + LineEditor.indentation)
        }
        return false
    }

    private func remove(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        buffer.removeSubrange(range)
        cursor = range.lowerBound
        startedEditing()
    }

    private func replace(_ range: Range<Int>, with text: String) {
        buffer.replaceSubrange(range, with: Array(text))
        cursor = range.lowerBound + text.count
        startedEditing()
    }

    /// Editing ends any history browsing; the next ↑ searches from the
    /// newest entry with what's now typed as the prefix.
    private func startedEditing() {
        historyIndex = history.entries.count
    }

    private func lineStart(from index: Int) -> Int {
        buffer[..<index].lastIndex(of: "\n").map { $0 + 1 } ?? 0
    }

    private func lineEnd(from index: Int) -> Int {
        buffer[index...].firstIndex(of: "\n") ?? buffer.count
    }

    private func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private func wordStart(before index: Int) -> Int {
        var start = index
        while start > 0 && !isWordCharacter(buffer[start - 1]) { start -= 1 }
        while start > 0 && isWordCharacter(buffer[start - 1]) { start -= 1 }
        return start
    }

    private func wordEnd(after index: Int) -> Int {
        var end = index
        while end < buffer.count && !isWordCharacter(buffer[end]) { end += 1 }
        while end < buffer.count && isWordCharacter(buffer[end]) { end += 1 }
        return end
    }

    /// Moves between the lines of multi-line input; false at the first or
    /// last line, where ↑ and ↓ browse history instead.
    private func moveVertically(by direction: Int) -> Bool {
        let start = lineStart(from: cursor)
        let column = cursor - start
        if direction < 0 {
            guard start > 0 else { return false }
            let previousStart = lineStart(from: start - 1)
            cursor = min(previousStart + column, start - 1)
        } else {
            let end = lineEnd(from: cursor)
            guard end < buffer.count else { return false }
            cursor = min(end + 1 + column, lineEnd(from: end + 1))
        }
        return true
    }

    // MARK: History

    /// Steps to the next older or newer entry starting with what was typed
    /// before browsing began, skipping ones equal to what's shown.
    private func browseHistory(by direction: Int) {
        let entries = history.entries
        if historyIndex == entries.count {
            draft = buffer
            historyPrefix = String(buffer)
        }
        var index = historyIndex + direction
        while entries.indices.contains(index) {
            let entry = entries[index]
            if entry.hasPrefix(historyPrefix) && entry != String(buffer) { break }
            index += direction
        }
        if index < 0 { return }
        if index >= entries.count {
            buffer = draft
            historyIndex = entries.count
        } else {
            buffer = Array(entries[index])
            historyIndex = index
        }
        cursor = buffer.count
    }

    /// ^R: an incremental search back through history. Enter runs the
    /// match, ^R again finds an older one, ^G or Esc cancels, and any other
    /// key leaves the match for editing.
    private func search() -> Input? {
        let originalBuffer = buffer
        let originalCursor = cursor
        let entries = history.entries
        var query = ""
        var match: Int?
        var failing = false

        func find(from start: Int) -> Int? {
            guard !query.isEmpty else { return nil }
            return stride(from: min(start, entries.count - 1), through: 0, by: -1)
                .first { entries[$0].contains(query) }
        }
        func show() {
            if let match {
                buffer = Array(entries[match])
                let offset = entries[match].range(of: query)
                    .map {
                        entries[match].distance(from: entries[match].startIndex, to: $0.lowerBound)
                    }
                cursor = offset ?? buffer.count
            }
            let label = failing ? "failing search" : "search"
            refresh(prompt: "\u{1B}[90m\(label):\u{1B}[0m \(query)\u{1B}[90m ›\u{1B}[0m ")
        }

        show()
        while let key = nextKey() {
            switch key {
            case .character(let character):
                query.append(character)
                if let found = find(from: match ?? entries.count - 1) {
                    match = found
                    failing = false
                } else {
                    failing = true
                }
            case .backspace:
                guard !query.isEmpty else { break }
                query.removeLast()
                match = find(from: entries.count - 1)
                failing = !query.isEmpty && match == nil
            case .search:
                if let current = match, let older = find(from: current - 1) {
                    match = older
                } else if match != nil {
                    failing = true
                }
            case .interrupt, .cancel, .escape:
                buffer = originalBuffer
                cursor = originalCursor
                return nil
            case .enter:
                if isComplete(String(buffer)) { return accept() }
                return nil
            default:
                // Leave the match to be edited, and handle the key there.
                pendingKey = key
                cursor = buffer.count
                startedEditing()
                return nil
            }
            show()
        }
        return .eof
    }

    // MARK: Completion

    /// Completes the word before the cursor: the whole of it when there's one candidate, and
    /// otherwise as much as the candidates share, with a menu of them under the input.
    private func completeWord() {
        guard let completion = complete(String(buffer), cursor), !completion.candidates.isEmpty
        else {
            writeOut("\u{07}")
            return
        }
        let candidates = completion.candidates
        let range = completion.start..<cursor
        if candidates.count == 1 {
            replace(range, with: candidates[0].replacement + candidates[0].suffix)
            return
        }
        let shared = candidates.dropFirst()
            .reduce(candidates[0].replacement) { common, candidate in
                String(zip(common, candidate.replacement).prefix { $0 == $1 }.map(\.0))
            }
        if shared.count > range.count { replace(range, with: shared) }
        openMenu(start: completion.start, candidates: candidates)
    }

    private func openMenu(start: Int, candidates: [Candidate]) {
        if promptRow == nil { promptRow = screenRow().map { $0 - renderedCursorRow } }
        let original = String(buffer[start..<cursor])
        menu = Menu(start: start, original: original, candidates: candidates)
    }

    /// A key while the menu is open: Tab, Shift-Tab and the arrows choose, Enter takes the choice,
    /// and Esc or ^G puts back what was typed. Any other key leaves the choice in the input and is
    /// handled as usual; `true` when the menu took the key.
    private func menuTook(_ key: Key) -> Bool {
        guard var menu else { return false }
        let width = terminalWidth()
        switch key {
        case .tab: menu.move(by: 1)
        case .backTab: menu.move(by: -1)
        case .down: menu.move(rows: 1, width: width)
        case .up: menu.move(rows: -1, width: width)
        case .right where menu.selected != nil: menu.move(columns: 1, width: width)
        case .left where menu.selected != nil: menu.move(columns: -1, width: width)
        case .enter where menu.selected != nil:
            let candidate = menu.candidates[menu.selected!]
            replace(menu.start..<cursor, with: candidate.replacement + candidate.suffix)
            closeMenu()
            return true
        case .cancel, .escape, .interrupt:
            replace(menu.start..<cursor, with: menu.original)
            closeMenu()
            return true
        default:
            // Kept for the menu the key may open again (`refineMenu`), so the terminal isn't asked
            // with every key typed.
            self.menu = nil
            return false
        }
        self.menu = menu
        let chosen = menu.selected.map { menu.candidates[$0].replacement } ?? menu.original
        replace(menu.start..<cursor, with: chosen)
        return true
    }

    /// After typing or deleting in the word the menu was for, the menu shows the candidates for
    /// what the word is now.
    private func refineMenu(from start: Int) {
        guard let completion = complete(String(buffer), cursor), completion.start == start,
            !completion.candidates.isEmpty
        else { return }
        openMenu(start: start, candidates: completion.candidates)
    }

    private func closeMenu() {
        menu = nil
        promptRow = nil
    }

    /// The row of the screen the cursor is on, counted from 0 at the top, as the terminal says.
    /// Keys that come before its answer are kept for later.
    private func screenRow() -> Int? {
        writeOut("\u{1B}[6n")
        var received: [UInt8] = []
        while let byte = readByte(timeout: 200, queued: false) {
            received.append(byte)
            guard byte == UInt8(ascii: "R"), let escape = received.lastIndex(of: 27) else {
                continue
            }
            let answer = String(decoding: received[(escape + 1)...], as: UTF8.self)
            guard answer.hasPrefix("["), let separator = answer.firstIndex(of: ";"),
                let row = Int(answer[answer.index(after: answer.startIndex)..<separator])
            else { continue }
            queuedBytes += received[..<escape]
            return row - 1
        }
        queuedBytes += received
        return nil
    }

    // MARK: Rendering

    /// Redraws the prompt and input in place: back up to where the last
    /// render started, clear to the end of the screen, draw, and put the
    /// cursor back where it belongs.
    private func refresh(prompt override: String? = nil) {
        let prompt = override ?? self.prompt
        let width = terminalWidth()
        let styles = highlight(String(buffer))
        var out = renderedCursorRow > 0 ? "\u{1B}[\(renderedCursorRow)A" : ""
        out += "\r\u{1B}[J" + prompt

        var layout = Layout(width: width)
        layout.advance(over: prompt)
        var cursorPosition = layout.position
        var currentStyle: String?
        for (index, character) in buffer.enumerated() {
            if index == cursor { cursorPosition = layout.position }
            if character == "\n" {
                if currentStyle != nil { out += "\u{1B}[0m" }
                currentStyle = nil
                out += "\n" + continuationPrompt
                layout.newline()
                layout.advance(over: continuationPrompt)
                continue
            }
            let style = index < styles.count ? styles[index] : nil
            if style != currentStyle {
                out += "\u{1B}[0m" + (style ?? "")
                currentStyle = style
            }
            out.append(character)
            layout.advance(by: LineEditor.displayWidth(of: character))
        }
        if currentStyle != nil { out += "\u{1B}[0m" }
        if cursor == buffer.count { cursorPosition = layout.position }

        // A line that exactly fills the width leaves the terminal waiting to
        // wrap; a newline settles it so the cursor moves are unambiguous.
        var end = layout.rawPosition
        if end.column >= width {
            out += "\n"
            end = (end.row + 1, 0)
        }

        // The menu goes in the rows free under the input, and no further, so nothing scrolls.
        var menuRows = 0
        if let menu, let row = promptRow {
            let height = terminalHeight(output) ?? 24
            // Input that grew past the bottom has pushed the prompt up.
            let top = max(min(row, height - 1 - end.row), 0)
            promptRow = top
            let lines = menu.lines(width: width, height: height - 1 - top - end.row)
            for line in lines { out += "\n\r" + line }
            menuRows = lines.count
        }
        let up = end.row - cursorPosition.row + menuRows
        if up > 0 { out += "\u{1B}[\(up)A" }
        out += "\r"
        if cursorPosition.column > 0 { out += "\u{1B}[\(cursorPosition.column)C" }
        renderedCursorRow = cursorPosition.row
        writeOut(out)
    }

    private func moveToEnd() {
        cursor = buffer.count
        refresh()
    }

    /// Where text lands on a terminal `width` columns wide, wrapping as the
    /// terminal does.
    struct Layout {
        let width: Int
        private(set) var row = 0
        private(set) var column = 0

        init(width: Int) {
            self.width = max(width, 1)
        }

        /// The position as the terminal reports it: a full line's column
        /// is the start of the next row.
        var position: (row: Int, column: Int) {
            column >= width ? (row + 1, 0) : (row, column)
        }

        var rawPosition: (row: Int, column: Int) {
            (row, column)
        }

        mutating func advance(by cells: Int) {
            if column + cells > width {
                row += 1
                column = 0
            }
            column += cells
        }

        /// Advances over text that may contain ANSI escapes, which take no room.
        mutating func advance(over text: String) {
            for character in LineEditor.strippingEscapes(text) {
                advance(by: LineEditor.displayWidth(of: character))
            }
        }

        mutating func newline() {
            row += 1
            column = 0
        }
    }

    static func strippingEscapes(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\u{1B}\\[[0-9;?]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
    }

    /// Terminal cells a character takes: 2 for wide East Asian characters
    /// and emoji, 0 for controls, 1 otherwise.
    static func displayWidth(of character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        if scalar.value < 0x20 || (0x7F..<0xA0).contains(scalar.value) { return 0 }
        if character.unicodeScalars.contains(where: {
            $0.properties.isEmojiPresentation || $0 == "\u{FE0F}"
        }) {
            return 2
        }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
            0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
            0xFFE0...0xFFE6, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }

    static func displayWidth(of text: String) -> Int {
        strippingEscapes(text).reduce(0) { $0 + displayWidth(of: $1) }
    }

    private func terminalWidth() -> Int {
        SwishShell.terminalWidth(output) ?? 80
    }

    private func writeOut(_ text: String) {
        writeAll(output, text)
    }

    // MARK: Keys

    private func nextKey() -> Key? {
        if let key = pendingKey {
            pendingKey = nil
            return key
        }
        guard let byte = readByte() else { return nil }
        switch byte {
        case 1: return .home  // ^A
        case 2: return .left  // ^B
        case 3: return .interrupt  // ^C
        case 4: return .eof  // ^D
        case 5: return .end  // ^E
        case 6: return .right  // ^F
        case 7: return .cancel  // ^G
        case 8, 127: return .backspace
        case 9: return .tab
        case 10, 13: return .enter
        case 11: return .killToEnd  // ^K
        case 12: return .clearScreen  // ^L
        case 14: return .down  // ^N
        case 16: return .up  // ^P
        case 18: return .search  // ^R
        case 21: return .killToStart  // ^U
        case 23: return .deleteWord  // ^W
        case 27: return readEscapeSequence()
        case 0..<32: return .ignored
        default: return readCharacter(startingWith: byte)
        }
    }

    /// Esc on its own, Alt+key (Esc then the key), or a CSI sequence. A
    /// lone Esc is told apart by nothing following within 50ms.
    private func readEscapeSequence() -> Key {
        guard let next = readByte(timeout: 50) else { return .escape }
        switch next {
        case UInt8(ascii: "b"): return .wordLeft
        case UInt8(ascii: "f"): return .wordRight
        case 127, 8: return .deleteWord
        case 13, 10: return .newline  // Alt+Enter: a new line even in complete input.
        case UInt8(ascii: "["), UInt8(ascii: "O"): break
        default: return .ignored
        }

        var parameters: [UInt8] = []
        var final: UInt8 = 0
        while let byte = readByte(timeout: 50) {
            if (0x40...0x7E).contains(byte) {
                final = byte
                break
            }
            parameters.append(byte)
        }
        let parameterText = String(decoding: parameters, as: UTF8.self)
        // `1;5` and `1;3` mean Ctrl and Alt: word moves.
        let modified = parameterText.hasSuffix(";5") || parameterText.hasSuffix(";3")
        switch final {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return modified ? .wordRight : .right
        case UInt8(ascii: "D"): return modified ? .wordLeft : .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "Z"): return .backTab
        case UInt8(ascii: "~"):
            switch parameterText {
            case "3": return .delete
            case "1", "7": return .home
            case "4", "8": return .end
            default: return .ignored
            }
        default:
            return .ignored
        }
    }

    private func readCharacter(startingWith byte: UInt8) -> Key {
        let length = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
        var bytes = [byte]
        for _ in 1..<length {
            guard let next = readByte() else { break }
            bytes.append(next)
        }
        return .character(Character(String(decoding: bytes, as: UTF8.self)))
    }

    /// One byte of input, those queued first; with a timeout in milliseconds, nil if none comes.
    private func readByte(timeout: Int32? = nil, queued: Bool = true) -> UInt8? {
        if queued, !queuedBytes.isEmpty { return queuedBytes.removeFirst() }
        if let timeout {
            var descriptor = pollfd(fd: input, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, timeout) > 0 else { return nil }
        }
        var byte: UInt8 = 0
        while true {
            let count = read(input, &byte, 1)
            if count == 1 { return byte }
            if count == -1 && errno == EINTR { continue }
            return nil
        }
    }
}
