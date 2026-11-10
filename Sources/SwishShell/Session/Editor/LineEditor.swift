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

    enum Key {
        case character(Character)
        case enter, newline, interrupt, eof, tab, backTab, search, cancel, escape
        case backspace, delete, deleteWord, killToEnd, killToStart
        case left, right, wordLeft, wordRight, home, end, up, down
        case clearScreen, ignored
    }

    let input = STDIN_FILENO
    let output = STDOUT_FILENO

    var buffer: [Character] = []
    var cursor = 0
    var prompt = ""
    /// The cursor's row in the last render, counted from the prompt's row,
    /// to get back to the start before drawing again.
    var renderedCursorRow = 0
    var pendingKey: Key?
    /// Bytes read while waiting for something else (the terminal's answer to a question), to be
    /// read as keys after.
    var queuedBytes: [UInt8] = []

    /// The completion menu, while it's open, and the row of the screen the prompt is on, which
    /// says how many rows under the input are free for it.
    var menu: Menu?
    var promptRow: Int?

    /// Browsing history: the entry shown, the text typed before browsing
    /// started, and the prefix entries must match (what was typed).
    var historyIndex = 0
    var draft: [Character] = []
    var historyPrefix = ""

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
}
