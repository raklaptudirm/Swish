import Foundation
import Swiit

/// Lays out a stream of items as it arrives. Records become table rows:
/// the first 100, or whatever arrives in the first 200ms, decide the
/// columns and widths, and later rows are truncated to fit. Other items
/// are written one per line.
final class DisplayFormatter {
    private let write: (String) -> Bool
    private let useViews: Bool
    private let maxWidth: Int
    private let styled: Bool
    private let header: Bool
    private let columnCap: Int
    private let registry: DisplayRegistry
    private var pending: [Fields] = []
    private var firstArrival: Date?
    private var columns: [Column]?
    /// Some columns didn't fit and aren't shown.
    private var droppedColumns = false

    private struct Column {
        let key: String
        let width: Int
        let rightAligned: Bool
    }

    /// `useViews: false` shows every column, as `table` does.
    init(
        maxWidth: Int = .max, styled: Bool = false, useViews: Bool = true, header: Bool = true,
        columnCap: Int = 40, registry: DisplayRegistry = DisplayRegistry(), write: @escaping (String) -> Bool
    ) {
        self.registry = registry
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
        if item.kind == .nothing { return true }
        if item.kind == .list { return (item.cast(to: [Value].self) ?? []).allSatisfy { add($0) } }
        if let record = item.fields {
            if columns != nil { return emit(row(record)) }
            pending.append(record)
            if firstArrival == nil { firstArrival = Date() }
            if pending.count >= 100 || Date().timeIntervalSince(firstArrival!) > 0.2 {
                return flush()
            }
            return true
        }
        guard flush() else { return false }
        // A Swift value with colors to show (help), on a terminal.
        if styled, let colored = (try? item.unboxed((any Presentable).self))?.styledText {
            return emit(colored)
        }
        return emit(item.description)
    }

    @discardableResult
    func finish() -> Bool {
        flush()
    }

    private func flush() -> Bool {
        guard !pending.isEmpty else { return true }
        columns = layout(for: pending)
        if header {
            var line = trimmingTrailingSpaces(columns!.map { pad($0.key, $0, DisplayStyle.label) }.joined(separator: "  "))
            if droppedColumns { line += "  " + "…".styled(DisplayStyle.dim, styled) }
            guard emit(line) else { return false }
        }
        let rows = pending
        pending = []
        return rows.allSatisfy { emit(row($0)) }
    }

    private func layout(for sample: [Fields]) -> [Column] {
        var keys: [String]
        if useViews, let typeName = sample.first?.typeName, let view = registry.columns(for: typeName),
           sample.allSatisfy({ $0.typeName == typeName }) {
            keys = view.map(\.name)
        } else {
            keys = []
            var seen: Set<String> = []
            for record in sample {
                for key in record.keys where seen.insert(key).inserted { keys.append(key) }
            }
        }

        var widths = keys.map { key in
            min(columnCap, max(header ? key.count : 0, sample.map { DisplayFormatter.cell($0[key] ?? .null).count }.max() ?? 0))
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
            let values = sample.compactMap { $0[keys[index]] }.filter { $0 != .null }
            let numeric = !values.isEmpty && values.allSatisfy {
                switch $0.kind {
                case .int, .double: true
                default: $0.displayShape.isNumeric
                }
            }
            return Column(key: keys[index], width: widths[index], rightAligned: numeric)
        }
    }

    private func row(_ record: Fields) -> String {
        trimmingTrailingSpaces(columns!.map { column in
            let value = record[column.key] ?? .null
            return pad(DisplayFormatter.cell(value), column, DisplayFormatter.style(of: value, key: column.key, in: record, registry: registry))
        }.joined(separator: "  "))
    }

    /// What stands out in a table: a column the type gives a style, or says
    /// is styled by a field whose value is an enum that says how its cases
    /// are shown (a file's name by its type, a job's state by itself). Else
    /// it's plain.
    static func style(of value: Value, key: String, in record: Fields, registry: DisplayRegistry) -> DisplayStyle? {
        guard let typeName = record.typeName, let column = registry.columns(for: typeName)?.first(where: { $0.name == key }) else { return nil }
        if let fixed = column.style { return fixed }
        guard let source = column.styledBy,
              let found = record[source]?.enumCase,
              let style = registry.enumStyles[found.type]?(found.name) else { return nil }
        return style
    }

    /// Leading spaces are a right-aligned column's padding, so only the end
    /// is trimmed.
    private func trimmingTrailingSpaces(_ line: String) -> String {
        String(line.reversed().drop { $0 == " " }.reversed())
    }

    /// Styles only the text, so trailing padding can still be trimmed.
    private func pad(_ text: String, _ column: Column, _ style: DisplayStyle? = nil) -> String {
        let fitted = text.count > column.width ? text.prefix(column.width - 1) + "…" : text
        let padding = String(repeating: " ", count: column.width - fitted.count)
        let shown = String(fitted).styled(style, styled)
        return column.rightAligned ? padding + shown : shown + padding
    }

    private func emit(_ line: String) -> Bool {
        write(line + "\n")
    }

    /// `name  value` lines, with keys aligned.
    static func keyValueLines(_ record: Fields, styled: Bool = false, registry: DisplayRegistry = DisplayRegistry()) -> [String] {
        let width = record.keys.map(\.count).max() ?? 0
        return record.map { key, value in
            key.styled(DisplayStyle.label, styled) + String(repeating: " ", count: width - key.count + 2)
                + cell(value).styled(style(of: value, key: key, in: record, registry: registry), styled)
        }
    }

    /// A value as one table cell: one line, nested values summarized.
    static func cell(_ value: Value) -> String {
        switch value.kind {
        case .string:
            return value.description.replacingOccurrences(of: "\n", with: "↵")
        case .list:
            let count = value.cast(to: [Value].self)?.count ?? 0
            return "[\(count) item\(count == 1 ? "" : "s")]"
        case .structure, .tuple:
            let count = value.fields?.count ?? 0
            return "{\(count) field\(count == 1 ? "" : "s")}"
        default:
            // What a Swift value's type says a table shows: a date to the minute.
            if let displayed = try? value.unboxed((any Presentable).self) { return displayed.cell }
            return value.description
        }
    }
}
