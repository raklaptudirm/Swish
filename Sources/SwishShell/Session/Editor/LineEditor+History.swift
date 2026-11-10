import Foundation
import Swiit

// Browsing history with ↑ and ↓, and searching it incrementally.

extension LineEditor {
    /// Steps to the next older or newer entry starting with what was typed
    /// before browsing began, skipping ones equal to what's shown.
    func browseHistory(by direction: Int) {
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
    func search() -> Input? {
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
}
