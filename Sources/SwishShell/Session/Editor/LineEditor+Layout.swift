import Foundation
import Swiit

// Where text lands on a terminal of a given width: wrapping, escape sequences and the
// widths of characters.

extension LineEditor {
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
}
