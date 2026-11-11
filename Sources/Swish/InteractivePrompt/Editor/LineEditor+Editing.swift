import Foundation
import Swiit

// The editing loop and what the keys do to the text: insert, delete, move and indent.

extension LineEditor {
    func edit() -> Input {
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

    func accept() -> Input {
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

    func replace(_ range: Range<Int>, with text: String) {
        buffer.replaceSubrange(range, with: Array(text))
        cursor = range.lowerBound + text.count
        startedEditing()
    }

    /// Editing ends any history browsing; the next ↑ searches from the
    /// newest entry with what's now typed as the prefix.
    func startedEditing() {
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
}
