import Foundation
import SwishKit

/// The columns shown by default for records of a type; the rest are still
/// there for `where`, `select` and `get`, and `table` shows everything.
let views: [String: [String]] = [
    "FileEntry": ["name", "type", "size", "modified"],
    "ProcessEntry": ["pid", "name", "user", "memory", "cpuTime"],
]

extension Shell {
    /// Shows a value to a person: a table for a list of records, a
    /// key/value list for one record, plain text otherwise.
    func show(_ value: Value) {
        switch value {
        case .nothing:
            return
        case .record(let record):
            for line in keyValueLines(record) { writeAll(stdoutFD, line + "\n") }
        case .list(let items) where items.contains(where: { if case .record = $0 { true } else { false } }):
            let formatter = Formatter(fd: stdoutFD)
            for item in items { formatter.add(item) }
            formatter.finish()
        default:
            writeAll(stdoutFD, value.description + "\n")
        }
    }

    /// `name  value` lines, with keys aligned.
    func keyValueLines(_ record: Record) -> [String] {
        let width = record.keys.map(\.count).max() ?? 0
        return record.map { key, value in
            key.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + Formatter.cell(value)
        }
    }
}

/// Lays out a stream of items as it arrives. Records become table rows:
/// the first 100, or whatever arrives in the first 200ms, decide the
/// columns and widths, and later rows are truncated to fit. Other items
/// are written one per line.
final class Formatter {
    private let write: (String) -> Bool
    private let useViews: Bool
    private let maxWidth: Int
    private let styled: Bool
    private var pending: [Record] = []
    private var firstArrival: Date?
    private var columns: [Column]?
    /// Some columns didn't fit and aren't shown.
    private var droppedColumns = false

    private struct Column {
        let key: String
        let width: Int
        let rightAligned: Bool
    }

    /// Writes to `fd`, fitting the terminal and styling the header when it
    /// is one.
    convenience init(fd: Int32) {
        var size = winsize()
        let isTerminal = isatty(fd) != 0
        let width = isTerminal && ioctl(fd, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : Int.max
        self.init(maxWidth: width, styled: isTerminal) { writeAll(fd, $0) }
    }

    /// `useViews: false` shows every column, as `table` does.
    init(maxWidth: Int = .max, styled: Bool = false, useViews: Bool = true, write: @escaping (String) -> Bool) {
        self.maxWidth = maxWidth
        self.styled = styled
        self.useViews = useViews
        self.write = write
    }

    /// False once the reader is gone.
    @discardableResult
    func add(_ item: Value) -> Bool {
        switch item {
        case .nothing:
            return true
        case .list(let elements):
            return elements.allSatisfy { add($0) }
        case .record(let record):
            if columns != nil { return emit(row(record)) }
            pending.append(record)
            if firstArrival == nil { firstArrival = Date() }
            if pending.count >= 100 || Date().timeIntervalSince(firstArrival!) > 0.2 {
                return flush()
            }
            return true
        default:
            guard flush() else { return false }
            return emit(item.description)
        }
    }

    @discardableResult
    func finish() -> Bool {
        flush()
    }

    private func flush() -> Bool {
        guard !pending.isEmpty else { return true }
        columns = layout(for: pending)
        var header = trimmingTrailingSpaces(columns!.map { pad($0.key, $0) }.joined(separator: "  "))
        if droppedColumns { header += "  …" }
        guard emit(styled ? "\u{1B}[1m\(header)\u{1B}[0m" : header) else { return false }
        let rows = pending
        pending = []
        return rows.allSatisfy { emit(row($0)) }
    }

    private func layout(for sample: [Record]) -> [Column] {
        var keys: [String]
        if useViews, let typeName = sample.first?.typeName, let view = views[typeName],
           sample.allSatisfy({ $0.typeName == typeName }) {
            keys = view
        } else {
            keys = []
            var seen: Set<String> = []
            for record in sample {
                for key in record.keys where seen.insert(key).inserted { keys.append(key) }
            }
        }

        var widths = keys.map { key in
            min(40, max(key.count, sample.map { Formatter.cell($0[key] ?? .nothing).count }.max() ?? 0))
        }
        // Shrink the widest columns until the table fits, down to 6 each;
        // if that isn't enough, leave off columns from the right, keeping
        // room for the `…` that says so.
        func tableWidth() -> Int { widths.reduce(0, +) + 2 * (widths.count - 1) + (droppedColumns ? 3 : 0) }
        while tableWidth() > maxWidth,
              let widest = widths.indices.max(by: { widths[$0] < widths[$1] }), widths[widest] > 6 {
            widths[widest] -= 1
        }
        while tableWidth() > maxWidth && keys.count > 1 {
            keys.removeLast()
            widths.removeLast()
            droppedColumns = true
        }
        return keys.indices.map { index in
            let values = sample.compactMap { $0[keys[index]] }.filter { $0 != .nothing }
            let numeric = !values.isEmpty && values.allSatisfy {
                switch $0 {
                case .int, .double, .filesize: true
                default: false
                }
            }
            return Column(key: keys[index], width: widths[index], rightAligned: numeric)
        }
    }

    private func row(_ record: Record) -> String {
        trimmingTrailingSpaces(columns!.map { pad(Formatter.cell(record[$0.key] ?? .nothing), $0) }.joined(separator: "  "))
    }

    /// Leading spaces are a right-aligned column's padding, so only the end
    /// is trimmed.
    private func trimmingTrailingSpaces(_ line: String) -> String {
        String(line.reversed().drop { $0 == " " }.reversed())
    }

    private func pad(_ text: String, _ column: Column) -> String {
        let fitted = text.count > column.width ? text.prefix(column.width - 1) + "…" : text
        let padding = String(repeating: " ", count: column.width - fitted.count)
        return column.rightAligned ? padding + fitted : fitted + padding
    }

    private func emit(_ line: String) -> Bool {
        write(line + "\n")
    }

    /// A value as one table cell: one line, nested values summarized.
    static func cell(_ value: Value) -> String {
        switch value {
        case .string(let text):
            text.replacingOccurrences(of: "\n", with: "↵")
        case .list(let items):
            "[\(items.count) item\(items.count == 1 ? "" : "s")]"
        case .record(let record):
            "{\(record.count) field\(record.count == 1 ? "" : "s")}"
        case .date:
            // To the minute: `2026-09-27 14:03`.
            String(value.description.prefix(16))
        default:
            value.description
        }
    }
}
