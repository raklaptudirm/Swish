extension LineEditor {
    /// The candidates of a completion, laid out under the input to choose from: in columns, filled
    /// top to bottom like `ls`, or one to a row when they have descriptions. It takes only the
    /// rows it is given, which are the ones free below the input, so the screen never scrolls for
    /// it; when the candidates need more, it shows the rows around the one chosen.
    struct Menu {
        /// Where the word being completed starts, and the text it had before the menu opened.
        let start: Int
        let original: String
        let candidates: [Candidate]
        /// The candidate chosen, and shown in the input; none until Tab or an arrow chooses one.
        var selected: Int?

        /// How the candidates fit a terminal `width` columns wide.
        struct Grid {
            let columns: Int
            let rows: Int
            let columnWidth: Int
            let described: Bool
        }

        func grid(width: Int) -> Grid {
            let widest = candidates.map { LineEditor.displayWidth(of: $0.display) }.max() ?? 0
            if candidates.contains(where: { $0.description != nil }) {
                return Grid(
                    columns: 1,
                    rows: candidates.count,
                    columnWidth: min(widest, 30),
                    described: true
                )
            }
            let columnWidth = min(widest + 2, max(width - 1, 1))
            let columns = max(1, (width - 1) / columnWidth)
            let rows = (candidates.count + columns - 1) / columns
            return Grid(columns: columns, rows: rows, columnWidth: columnWidth, described: false)
        }

        /// Moves the choice by `step` places in order: Tab and Shift-Tab. The first move from no
        /// choice lands on the first candidate, or the last going back.
        mutating func move(by step: Int) {
            let count = candidates.count
            guard let current = selected else {
                selected = step > 0 ? 0 : count - 1
                return
            }
            selected = ((current + step) % count + count) % count
        }

        /// Moves the choice a row (`rows`) or a column (`columns`) on a terminal `width` wide: the
        /// arrow keys. Filled by column, a row away is the next place in order; a column move
        /// that runs off a row's end goes on at the other end of the row after (or before) it.
        mutating func move(rows: Int = 0, columns: Int = 0, width: Int) {
            guard let current = selected, columns != 0 else {
                return move(by: rows + columns < 0 ? -1 : 1)
            }
            let grid = grid(width: width)
            var row = current % grid.rows
            var column = current / grid.rows + columns
            if column * grid.rows + row >= candidates.count {
                row = (row + 1) % grid.rows
                column = 0
            } else if column < 0 {
                row = (row - 1 + grid.rows) % grid.rows
                column = (candidates.count - 1 - row) / grid.rows
            }
            selected = column * grid.rows + row
        }

        /// The lines to draw, at most `height` of them, each narrower than `width`: the rows around
        /// the choice, and a line saying which rows those are when they aren't all of them.
        func lines(width: Int, height: Int) -> [String] {
            guard height > 0, !candidates.isEmpty else { return [] }
            let grid = grid(width: width)
            var shown = 0..<grid.rows
            if grid.rows > height {
                let room = height > 1 ? height - 1 : 1
                let row = selected.map { $0 % grid.rows } ?? 0
                let first = min(max(row - room / 2, 0), grid.rows - room)
                shown = first..<first + room
            }
            var lines = shown.map { row in line(row, in: grid, width: width) }
            if shown.count < grid.rows, height > 1 {
                let status = "rows \(shown.lowerBound + 1)–\(shown.upperBound) of \(grid.rows)"
                lines.append(
                    "\u{1B}[90m" + LineEditor.truncated(status, to: width - 1) + "\u{1B}[0m"
                )
            }
            return lines
        }

        private func line(_ row: Int, in grid: Grid, width: Int) -> String {
            var line = ""
            for column in 0..<grid.columns {
                let index = column * grid.rows + row
                guard index < candidates.count else { break }
                let candidate = candidates[index]
                // One column has the whole width; more have their own, less the gap between them.
                let room = grid.described || grid.columns == 1 ? width - 1 : grid.columnWidth - 2
                var name = LineEditor.truncated(candidate.display, to: min(room, width - 1))
                let padding = grid.columnWidth - LineEditor.displayWidth(of: name)
                if grid.described { name += String(repeating: " ", count: max(padding, 0)) }
                line += index == selected ? "\u{1B}[7m\(name)\u{1B}[0m" : name

                if grid.described, let description = candidate.description {
                    let room = width - 1 - LineEditor.displayWidth(of: name) - 2
                    if room > 1 {
                        let text = LineEditor.truncated(description, to: room)
                        line += "  \u{1B}[90m\(text)\u{1B}[0m"
                    }
                } else if column < grid.columns - 1, index + grid.rows < candidates.count {
                    line += String(repeating: " ", count: max(padding, 0))
                }
            }
            return line
        }
    }

    /// `text` cut to `cells` columns, ending in "…" when it was cut.
    static func truncated(_ text: String, to cells: Int) -> String {
        guard displayWidth(of: text) > cells else { return text }
        guard cells > 1 else { return cells == 1 ? "…" : "" }
        var result = ""
        var used = 0
        for character in strippingEscapes(text) {
            let width = displayWidth(of: character)
            if used + width > cells - 1 { break }
            result.append(character)
            used += width
        }
        return result + "…"
    }
}
