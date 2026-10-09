import SwishStandardLibrary
import SwishKit

/// What text `from` can parse.
public enum InputFormat: CaseIterable {
    case json
}

/// Parses text into values.
/// - Parameter format: json
public func from(_ format: InputFormat, @Input _ text: [String]) throws -> JSON {
    switch format {
    case .json: JSON(try JSON.parse(text.joined(separator: "\n")))
    }
}

/// What `to` can make of values.
public enum OutputFormat: CaseIterable {
    case json
    /// As they would be displayed.
    case text
}

/// Converts the input to text: json, or text for how it would be displayed.
/// - Parameter format: json or text
public func to(_ format: OutputFormat, @Input _ items: [SwishValue], in shell: ShellContext) throws -> String {
    switch format {
    case .json: try JSON.text(items.count == 1 ? items[0] : .list(items))
    case .text: laidOut(items, useViews: true, shell).joined(separator: "\n")
    }
}

/// Lays records out as a table with every field.
public func table(@Input _ items: [SwishValue], in shell: ShellContext) -> [String] {
    laidOut(items, useViews: false, shell)
}

/// Shows each record as a list of fields.
public func list(@Input _ items: [SwishValue], in shell: ShellContext) -> [String] {
    var lines: [String] = []
    for item in items {
        if !lines.isEmpty { lines.append("") }
        if let record = item.asRecord {
            lines += DisplayFormatter.keyValueLines(record, registry: shell.display)
        } else {
            lines.append(item.description)
        }
    }
    return lines
}

/// The lines the display step would show for `items`.
private func laidOut(_ items: [SwishValue], useViews: Bool, _ shell: ShellContext) -> [String] {
    var lines: [String] = []
    let formatter = DisplayFormatter(useViews: useViews, registry: shell.display) { text in
        lines.append(String(text.dropLast()))
        return true
    }
    for item in items { formatter.add(item) }
    formatter.finish()
    return lines
}
