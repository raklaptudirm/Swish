import Foundation
import Swiit

// Drawing the prompt and the input in place, and finding the terminal's size.

extension LineEditor {
    /// Redraws the prompt and input in place: back up to where the last
    /// render started, clear to the end of the screen, draw, and put the
    /// cursor back where it belongs.
    func refresh(prompt override: String? = nil) {
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

    func moveToEnd() {
        cursor = buffer.count
        refresh()
    }

    func terminalWidth() -> Int {
        SwishShell.terminalWidth(output) ?? 80
    }

    func writeOut(_ text: String) {
        writeAll(output, text)
    }
}
