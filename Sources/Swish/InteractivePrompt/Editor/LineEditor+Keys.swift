import Foundation
import Swiit

// Reading keys from the terminal: bytes, escape sequences and UTF-8 characters.

extension LineEditor {
    func nextKey() -> Key? {
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
    func readByte(timeout: Int32? = nil, queued: Bool = true) -> UInt8? {
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
