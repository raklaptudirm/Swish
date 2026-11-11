import Swiit

/// What text `from` can parse.
enum InputFormat: CaseIterable, ScriptConvertible {
    case json
}

/// What `to` can make of values.
enum OutputFormat: CaseIterable, ScriptConvertible {
    case json
    /// As they would be displayed.
    case text
}
