import Foundation
import SwishKit

/// The columns shown by default for records of a type; the rest are still
/// there for `where`, `select` and `get`, and `table` shows everything.
let views: [String: [String]] = [
    "FileEntry": ["name", "type", "size", "modified"],
    "ProcessEntry": ["pid", "name", "user", "memory", "cpuTime"],
    "Job": ["id", "state", "command"],
    "Help": ["name", "source", "summary"],
]

extension Shell {
    /// Shows a value to a person: a table for a list of records, a
    /// key/value list for one record, and otherwise its text, or its
    /// `debugDescription` for a bare value (`let r = $(echo hi); r`).
    func show(_ value: Value, debug: Bool = false) {
        switch value {
        case .nothing:
            return
        case .output(let output) where output.text.isEmpty && !debug:
            return
        case .record(let record) where !debug:
            for line in keyValueLines(record, styled: Style.enabled(for: stdoutFD)) { writeAll(stdoutFD, line + "\n") }
        // A command's list reads as a pipeline's output would: records as a
        // table, anything else an item per line. A bare list is a value.
        case .list(let items) where !debug || items.contains(where: { $0.asRecord != nil }):
            let formatter = Formatter(fd: stdoutFD)
            for item in items { formatter.add(item) }
            formatter.finish()
        case _ where debug:
            let printer = PrettyPrinter(width: terminalWidth(stdoutFD) ?? 80, styled: Style.enabled(for: stdoutFD))
            writeAll(stdoutFD, printer.format(value) + "\n")
        default:
            writeAll(stdoutFD, value.description + "\n")
        }
    }

    /// `name  value` lines, with keys aligned.
    func keyValueLines(_ record: Record, styled: Bool = false) -> [String] {
        let width = record.keys.map(\.count).max() ?? 0
        return record.map { key, value in
            key.styled(Style.label, styled) + String(repeating: " ", count: width - key.count + 2)
                + Formatter.cell(value).styled(Formatter.style(of: value, key: key, in: record), styled)
        }
    }
}

/// The width of the terminal `fd` is, if it is one.
func terminalWidth(_ fd: Int32) -> Int? {
    var size = winsize()
    guard isatty(fd) != 0, ioctl(fd, TIOCGWINSZ, &size) == 0, size.ws_col > 0 else { return nil }
    return Int(size.ws_col)
}

extension Value {
    /// A list's items, or an Output's lines: what sequence methods work on.
    var sequenceItems: [Value]? {
        switch self {
        case .list(let items): items
        case .output(let output): output.lines.map(Value.string)
        default: nil
        }
    }

    var isEmptyOutput: Bool {
        if case .output(let output) = self { output.text.isEmpty } else { false }
    }

    /// A record, or an object's fields: what a table row is made from.
    var asRecord: Record? {
        switch self {
        case .record(let record): record
        case .object(let object): object.fields
        default: nil
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
    private let header: Bool
    private let columnCap: Int
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
    /// is one. A file gets every character: nothing is cut to fit.
    convenience init(fd: Int32) {
        let isTerminal = isatty(fd) != 0
        self.init(maxWidth: terminalWidth(fd) ?? .max, styled: Style.enabled(for: fd),
                  columnCap: isTerminal ? 40 : .max) { writeAll(fd, $0) }
    }

    /// Rows for another program to read, as in `ls | grep x`: the view's
    /// columns, no header, nothing cut short.
    static func forProgram(fd: Int32) -> Formatter {
        Formatter(header: false, columnCap: .max) { writeAll(fd, $0) }
    }

    /// `useViews: false` shows every column, as `table` does.
    init(
        maxWidth: Int = .max, styled: Bool = false, useViews: Bool = true, header: Bool = true,
        columnCap: Int = 40, write: @escaping (String) -> Bool
    ) {
        self.maxWidth = maxWidth
        self.styled = styled
        self.useViews = useViews
        self.header = header
        self.columnCap = columnCap
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
        case .object(let object) where object.fields != nil:
            return add(.record(object.fields!))
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
        if header {
            var line = trimmingTrailingSpaces(columns!.map { pad($0.key, $0, Style.label) }.joined(separator: "  "))
            if droppedColumns { line += "  " + "…".styled(Style.dim, styled) }
            guard emit(line) else { return false }
        }
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
            min(columnCap, max(header ? key.count : 0, sample.map { Formatter.cell($0[key] ?? .nothing).count }.max() ?? 0))
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
        trimmingTrailingSpaces(columns!.map { column in
            let value = record[column.key] ?? .nothing
            return pad(Formatter.cell(value), column, Formatter.style(of: value, key: column.key, in: record))
        }.joined(separator: "  "))
    }

    /// What stands out in a table: directories and links in `ls`, and how
    /// jobs are going. Everything else is plain.
    static func style(of value: Value, key: String, in record: Record) -> Style? {
        if key == "name", case .enumValue(let type)? = record["type"], type.type === Shell.fileType {
            switch type.name {
            case "directory": return .boldBlue
            case "symlink": return .cyan
            default: return nil
            }
        }
        if case .enumValue(let state) = value, state.type === Shell.jobState {
            switch state.name {
            case "running": return .green
            case "stopped": return .yellow
            case "cancelled": return .dim
            default: return nil
            }
        }
        return nil
    }

    /// Leading spaces are a right-aligned column's padding, so only the end
    /// is trimmed.
    private func trimmingTrailingSpaces(_ line: String) -> String {
        String(line.reversed().drop { $0 == " " }.reversed())
    }

    /// Styles only the text, so trailing padding can still be trimmed.
    private func pad(_ text: String, _ column: Column, _ style: Style? = nil) -> String {
        let fitted = text.count > column.width ? text.prefix(column.width - 1) + "…" : text
        let padding = String(repeating: " ", count: column.width - fitted.count)
        let shown = String(fitted).styled(style, styled)
        return column.rightAligned ? padding + shown : shown + padding
    }

    private func emit(_ line: String) -> Bool {
        write(line + "\n")
    }

    /// A value as one table cell: one line, nested values summarized.
    static func cell(_ value: Value) -> String {
        switch value {
        case .string(let text):
            text.replacingOccurrences(of: "\n", with: "↵")
        case .output(let output):
            output.text.replacingOccurrences(of: "\n", with: "↵")
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
