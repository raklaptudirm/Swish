import SwiitStandardLibrary
@_spi(Layer) import Swiit

/// What text `from` can parse.
@_spi(Layer) public enum InputFormat: CaseIterable {
    case json
}

/// Parses text into values.
/// - Parameter format: json
@_spi(Layer) public func from(_ format: InputFormat, @Input _ text: [String]) throws -> JSON {
    switch format {
    case .json: JSON(try JSON.parse(text.joined(separator: "\n")))
    }
}

/// What `to` can make of values.
@_spi(Layer) public enum OutputFormat: CaseIterable {
    case json
    /// As they would be displayed.
    case text
}

/// Converts the input to text: json, or text for how it would be displayed.
/// - Parameter format: json or text
@_spi(Layer) public func to(_ format: OutputFormat, @Input _ items: [SwiitValue], in shell: HostContext) throws -> String {
    switch format {
    case .json: try JSON.text(items.count == 1 ? items[0] : .list(items))
    case .text: laidOut(items, useViews: true, shell).joined(separator: "\n")
    }
}

/// Lays records out as a table with every field.
@_spi(Layer) public func table(@Input _ items: [SwiitValue], in shell: HostContext) -> [String] {
    laidOut(items, useViews: false, shell)
}

/// Shows each record as a list of fields.
@_spi(Layer) public func list(@Input _ items: [SwiitValue], in shell: HostContext) -> [String] {
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
private func laidOut(_ items: [SwiitValue], useViews: Bool, _ shell: HostContext) -> [String] {
    var lines: [String] = []
    let formatter = DisplayFormatter(useViews: useViews, registry: shell.display) { text in
        lines.append(String(text.dropLast()))
        return true
    }
    for item in items { formatter.add(item) }
    formatter.finish()
    return lines
}
