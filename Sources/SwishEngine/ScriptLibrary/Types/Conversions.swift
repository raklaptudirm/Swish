import Swiit

/// What text `from` can parse.
enum InputFormat: CaseIterable, BridgedValue {
    case json
}

/// What `to` can make of values.
enum OutputFormat: CaseIterable, BridgedValue {
    case json
    /// As they would be displayed.
    case text
}
