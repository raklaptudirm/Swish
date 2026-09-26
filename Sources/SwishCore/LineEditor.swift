import Foundation

/// A minimal single-line editor: raw-mode input, cursor movement, and
/// in-memory history. Falls back to plain `readLine` when stdin isn't a TTY.
final class LineEditor {
    private enum Key {
        case character(Character)
        case enter, interrupt, eof
        case backspace, delete, deleteWord, killToEnd, killToStart
        case left, right, home, end, up, down
        case clearScreen, ignored
    }

    private let input = STDIN_FILENO
    private var history: [String] = []

    func readLine(prompt: String) -> String? {
        guard isatty(input) != 0 else { return Swift.readLine() }

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

        return edit(prompt: prompt)
    }

    private func edit(prompt: String) -> String? {
        var buffer: [Character] = []
        var cursor = 0
        var historyIndex = history.count
        // The line being typed, kept while browsing history.
        var draft: [Character] = []

        func refresh() {
            var output = "\r" + prompt + String(buffer) + "\u{1B}[K"
            let trailing = buffer.count - cursor
            if trailing > 0 { output += "\u{1B}[\(trailing)D" }
            writeAll(STDOUT_FILENO, output)
        }

        func recall(_ index: Int) {
            guard index >= 0 && index <= history.count && index != historyIndex else { return }
            if historyIndex == history.count { draft = buffer }
            historyIndex = index
            buffer = index == history.count ? draft : Array(history[index])
            cursor = buffer.count
        }

        refresh()
        while let key = readKey() {
            switch key {
            case .character(let character):
                buffer.insert(character, at: cursor)
                cursor += 1
            case .enter:
                writeAll(STDOUT_FILENO, "\n")
                let line = String(buffer)
                if !line.allSatisfy(\.isWhitespace) && line != history.last {
                    history.append(line)
                }
                return line
            case .interrupt:
                writeAll(STDOUT_FILENO, "^C\n")
                return ""
            case .eof:
                if buffer.isEmpty {
                    writeAll(STDOUT_FILENO, "\n")
                    return nil
                }
                if cursor < buffer.count { buffer.remove(at: cursor) }
            case .backspace:
                if cursor > 0 {
                    cursor -= 1
                    buffer.remove(at: cursor)
                }
            case .delete:
                if cursor < buffer.count { buffer.remove(at: cursor) }
            case .deleteWord:
                var start = cursor
                while start > 0 && buffer[start - 1].isWhitespace { start -= 1 }
                while start > 0 && !buffer[start - 1].isWhitespace { start -= 1 }
                buffer.removeSubrange(start..<cursor)
                cursor = start
            case .killToEnd:
                buffer.removeSubrange(cursor...)
            case .killToStart:
                buffer.removeSubrange(..<cursor)
                cursor = 0
            case .left:
                cursor = max(cursor - 1, 0)
            case .right:
                cursor = min(cursor + 1, buffer.count)
            case .home:
                cursor = 0
            case .end:
                cursor = buffer.count
            case .up:
                recall(historyIndex - 1)
            case .down:
                recall(historyIndex + 1)
            case .clearScreen:
                writeAll(STDOUT_FILENO, "\u{1B}[H\u{1B}[2J")
            case .ignored:
                break
            }
            refresh()
        }
        return nil
    }

    private func readKey() -> Key? {
        guard let byte = readByte() else { return nil }
        switch byte {
        case 1: return .home          // ^A
        case 2: return .left          // ^B
        case 3: return .interrupt     // ^C
        case 4: return .eof           // ^D
        case 5: return .end           // ^E
        case 6: return .right         // ^F
        case 8, 127: return .backspace
        case 10, 13: return .enter
        case 11: return .killToEnd    // ^K
        case 12: return .clearScreen  // ^L
        case 14: return .down         // ^N
        case 16: return .up           // ^P
        case 21: return .killToStart  // ^U
        case 23: return .deleteWord   // ^W
        case 27: return readEscapeSequence()
        case 0..<32: return .ignored
        default: return readCharacter(startingWith: byte)
        }
    }

    private func readEscapeSequence() -> Key {
        guard let introducer = readByte(),
              introducer == UInt8(ascii: "[") || introducer == UInt8(ascii: "O"),
              let first = readByte() else { return .ignored }

        switch first {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            // Parameterized sequences like ESC [ 3 ~ end with a byte in 0x40...0x7E.
            var parameters = [first]
            while let next = readByte() {
                if (0x40...0x7E).contains(next) {
                    guard next == UInt8(ascii: "~") else { return .ignored }
                    break
                }
                parameters.append(next)
            }
            switch String(decoding: parameters, as: UTF8.self) {
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

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        while true {
            let count = read(input, &byte, 1)
            if count == 1 { return byte }
            if count == -1 && errno == EINTR { continue }
            return nil
        }
    }
}
