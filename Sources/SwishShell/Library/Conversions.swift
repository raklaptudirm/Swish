/// What text `from` can parse.
enum InputFormat: CaseIterable {
    case json
}

/// What `to` can make of values.
enum OutputFormat: CaseIterable {
    case json
    /// As they would be displayed.
    case text
}
