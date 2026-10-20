import Foundation
import Swiit
import SwiitStandardLibrary

/// How the standard library's and the shell's own types show in a table:
/// the columns shown by default for records of a type, and what styles them.
/// The rest are still there for `filter`, `select` and `get`, and `table`
/// shows everything. Each type says so itself (`Tabular`), beside where it's
/// made.
extension DisplayFormatter {
    /// Writes with `write`, fitting what the stream is: a terminal's width
    /// and a styled header, or every character for a file.
    convenience init(traits: OutputSink.Traits, registry: DisplayRegistry, write: @escaping (String) -> Bool) {
        self.init(maxWidth: traits.width ?? .max, styled: traits.styled,
                  columnCap: traits.isTerminal ? 40 : .max, registry: registry, write: write)
    }
}

extension Shell {
    /// How types show in a table: the shell's own (`Job`, `Help`, `FileEntry`), and the columns of the structs declared in
    /// Swish that say so (`Tabular`), found when a table of one is laid out.
    var displayRegistry: DisplayRegistry { tableRegistry() }

    func tableRegistry() -> DisplayRegistry {
        var registry = DisplayRegistry()
        registry.columns = [
            "FileEntry": FileEntry.columns, "ProcessEntry": ProcessEntry.columns,
            "Job": Job.columns, "Help": Shell.helpColumns,
        ]
        registry.enumStyles = [
            "FileType": { name in FileType.allCases.first { "\($0)" == name }?.displayStyle },
            "JobState": { name in JobState.allCases.first { "\($0)" == name }?.displayStyle },
        ]
        // Called holding the interpreter lock, as every table is laid out.
        nonisolated(unsafe) let shell = self
        registry.declared = { typeName in shell.declaredColumns(of: typeName) }
        return registry
    }

    /// The `columns` a struct of the program's declares by being `Tabular`.
    private func declaredColumns(of typeName: String) -> [DisplayColumn]? {
        guard let type = interpreter[typeName], let list = try? interpreter.value(of: "columns", in: type),
              let items = list.cast(to: [Value].self) else { return nil }
        let columns = items.compactMap { try? $0.unboxed(DisplayColumn.self) }
        return columns.isEmpty ? nil : columns
    }

    /// Shows a value to a person: a table for a list of records, a
    /// key/value list for one record, and otherwise its text, or its
    /// `debugDescription` for a bare value (`let r = $(echo hi); r`).
    func show(_ value: Value, debug: Bool = false) {
        let output = interpreter.host.output
        let traits = output.traits()
        let fields = value.fields
        switch value.kind {
        case .nothing:
            return
        case .tuple where fields?.count == 0:
            return // `()`: what a Void call gives as a value.
        case .object where value.displayShape.isEmpty && !debug:
            return
        case .structure where !debug, .tuple where !debug:
            for line in DisplayFormatter.keyValueLines(fields!, styled: traits.styled, registry: displayRegistry) {
                output.write(line + "\n")
            }
        // A command's list reads as a pipeline's output would: records as a
        // table, anything else an item per line. A bare list is a value.
        case .list where !debug || (value.cast(to: [Value].self) ?? []).contains(where: { $0.fields != nil }):
            let formatter = DisplayFormatter(traits: traits, registry: displayRegistry) { output.write($0) }
            for item in value.cast(to: [Value].self) ?? [] { formatter.add(item) }
            formatter.finish()
        case _ where debug:
            let printer = PrettyPrinter(width: traits.width ?? 80, styled: traits.styled)
            output.write(printer.format(value) + "\n")
        default:
            output.write(value.description + "\n")
        }
    }
}

extension Value {
    /// It has nothing to show, as a command that printed nothing.
    var showsNothing: Bool {
        displayShape.isEmpty
    }
}
