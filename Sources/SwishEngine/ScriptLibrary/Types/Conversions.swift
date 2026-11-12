import Swiit

/// What text `from` can parse.
enum InputFormat: CaseIterable, BridgedType {
    case json
}

/// What `to` can make of values.
enum OutputFormat: CaseIterable, BridgedType {
    case json
    /// As they would be displayed.
    case text
}
