import Foundation
import SwishKit
import SwishStandardLibrary

/// The columns shown by default for records of a type, and what styles them;
/// the rest are still there for `filter`, `select` and `get`, and `table`
/// shows everything. Each type says so itself (`Tabular`): the standard
/// library module's structs, and the shell's own, beside where they're made.
/// How the standard library's and the shell's own types show in a table.
let standardDisplayRegistry = DisplayRegistry(
    columns: Bridge.standardColumns.merging([
        "Job": Job.columns,
        "Help": Shell.helpColumns,
    ]) { first, _ in first },
    enumStyles: Bridge.standardEnumStyles)

extension DisplayFormatter {
    /// Writes to `fd`, fitting the terminal and styling the header when it
    /// is one. A file gets every character: nothing is cut to fit.
    convenience init(fd: Int32, registry: DisplayRegistry) {
        let isTerminal = isatty(fd) != 0
        self.init(maxWidth: terminalWidth(fd) ?? .max, styled: DisplayStyle.enabled(for: fd),
                  columnCap: isTerminal ? 40 : .max, registry: registry) { writeAll(fd, $0) }
    }

    /// Rows for another program to read, as in `ls | grep x`: the view's
    /// columns, no header, nothing cut short.
    static func forProgram(fd: Int32, registry: DisplayRegistry) -> DisplayFormatter {
        DisplayFormatter(header: false, columnCap: .max, registry: registry) { writeAll(fd, $0) }
    }
}

extension Shell {
    /// How types show in a table: the standard library's and the shell's own,
    /// and the columns of the structs declared in Swish that say so
    /// (`Tabular`).
    var displayRegistry: DisplayRegistry {
        var registry = standardDisplayRegistry
        for scope in scopes {
            for case .object(let type as StructType) in scope.bindings.values.map(\.value)
            where type.conformances.contains("Tabular") && registry.columns[type.name] == nil {
                guard case .list(let items)? = type.statics["columns"]?.value else { continue }
                registry.columns[type.name] = items.compactMap { item in
                    if case .object(let box as SwiftValue) = item { box.value as? DisplayColumn } else { nil }
                }
            }
        }
        return registry
    }
}

extension Shell {
    /// Shows a value to a person: a table for a list of records, a
    /// key/value list for one record, and otherwise its text, or its
    /// `debugDescription` for a bare value (`let r = $(echo hi); r`).
    func show(_ value: Value, debug: Bool = false) {
        switch value {
        case .nothing:
            return
        case .record(let record) where record.count == 0 && record.typeName == nil:
            return // `()`: what a Void call gives as a value.
        case .object where value.displayShape.isEmpty && !debug:
            return
        case .record(let record) where !debug:
            for line in DisplayFormatter.keyValueLines(record, styled: DisplayStyle.enabled(for: stdoutFD), registry: displayRegistry) {
                writeAll(stdoutFD, line + "\n")
            }
        // A command's list reads as a pipeline's output would: records as a
        // table, anything else an item per line. A bare list is a value.
        case .list(let items) where !debug || items.contains(where: { $0.asRecord != nil }):
            let formatter = DisplayFormatter(fd: stdoutFD, registry: displayRegistry)
            for item in items { formatter.add(item) }
            formatter.finish()
        case _ where debug:
            let printer = PrettyPrinter(width: terminalWidth(stdoutFD) ?? 80, styled: DisplayStyle.enabled(for: stdoutFD))
            writeAll(stdoutFD, printer.format(value) + "\n")
        default:
            writeAll(stdoutFD, value.description + "\n")
        }
    }
}

/// The width of the terminal `fd` is, if it is one.
func terminalWidth(_ fd: Int32) -> Int? {
    var size = winsize()
    // TIOCGWINSZ is a UInt on macOS and an Int32 on Linux.
    guard isatty(fd) != 0, ioctl(fd, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else { return nil }
    return Int(size.ws_col)
}

extension Value {
    /// A list's items, or an Output's lines: what sequence methods work on.
    var sequenceItems: [Value]? {
        switch self {
        case .list(let items): items
        default: commandOutput?.lines.map(Value.string)
        }
    }

    /// It has nothing to show, as a command that printed nothing.
    var showsNothing: Bool {
        displayShape.isEmpty
    }
}
