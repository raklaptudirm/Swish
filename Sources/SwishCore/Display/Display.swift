import Foundation
import SwishKit
import SwishStandardLibrary

/// How the standard library's and the shell's own types show in a table:
/// the columns shown by default for records of a type, and what styles them.
/// The rest are still there for `filter`, `select` and `get`, and `table`
/// shows everything. Each type says so itself (`Tabular`), beside where it's
/// made.
let standardDisplayRegistry = DisplayRegistry(columns: Bridge.standardColumns, enumStyles: Bridge.standardEnumStyles)

extension DisplayFormatter {
    /// Writes with `write`, fitting what the stream is: a terminal's width
    /// and a styled header, or every character for a file.
    convenience init(traits: StreamTraits, registry: DisplayRegistry, write: @escaping (String) -> Bool) {
        self.init(maxWidth: traits.width ?? .max, styled: traits.styled,
                  columnCap: traits.isTerminal ? 40 : .max, registry: registry, write: write)
    }
}

extension Interpreter {
    /// How types show in a table: the standard library's and the shell's own,
    /// and the columns of the structs declared in Swish that say so
    /// (`Tabular`).
    var displayRegistry: DisplayRegistry {
        var registry = standardDisplayRegistry
        registry.columns.merge(shellLayer?.columns ?? [:]) { first, _ in first }
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

extension Interpreter {
    /// Shows a value to a person: a table for a list of records, a
    /// key/value list for one record, and otherwise its text, or its
    /// `debugDescription` for a bare value (`let r = $(echo hi); r`).
    func show(_ value: Value, debug: Bool = false) {
        let output = host.output
        let traits = output.traits()
        switch value {
        case .nothing:
            return
        case .record(let record) where record.count == 0 && record.typeName == nil:
            return // `()`: what a Void call gives as a value.
        case .object where value.displayShape.isEmpty && !debug:
            return
        case .record(let record) where !debug:
            for line in DisplayFormatter.keyValueLines(record, styled: traits.styled, registry: displayRegistry) {
                output.write(line + "\n")
            }
        // A command's list reads as a pipeline's output would: records as a
        // table, anything else an item per line. A bare list is a value.
        case .list(let items) where !debug || items.contains(where: { $0.asRecord != nil }):
            let formatter = DisplayFormatter(traits: traits, registry: displayRegistry) { output.write($0) }
            for item in items { formatter.add(item) }
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
