import Foundation
import Swiit

// Tab completion: completing a word, and the menu of candidates shown under the input.

extension LineEditor {
    /// Completes the word before the cursor: the whole of it when there's one candidate, and
    /// otherwise as much as the candidates share, with a menu of them under the input.
    func completeWord() {
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
    func menuTook(_ key: Key) -> Bool {
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
    func refineMenu(from start: Int) {
        guard let completion = complete(String(buffer), cursor), completion.start == start,
            !completion.candidates.isEmpty
        else { return }
        openMenu(start: start, candidates: completion.candidates)
    }

    func closeMenu() {
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
}
