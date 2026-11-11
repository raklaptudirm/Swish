import Swiit

/// What a stretch of source is, for coloring it as it is typed.
public enum HighlightKind: Equatable, Sendable {
    case keyword, command, flag, string, number, constant, variable, comment, type, punctuation
    /// A command word that would run nothing: no function, builtin or program has the name.
    /// `Shell.highlighting(of:)` says it; the front end's own spans only say `command`.
    case unknownCommand
}

extension HighlightKind {
    /// The style the shell gives it by default.
    public var displayStyle: DisplayStyle {
        switch self {
        case .keyword, .punctuation: .keyword
        case .command: .green
        case .unknownCommand: .red
        case .flag: .flag
        case .string: .string
        case .number, .constant: .constant
        case .variable: .variable
        case .comment: .comment
        case .type: .type
        }
    }
}

/// A stretch of source, in characters, and what it is.
public struct HighlightSpan: Equatable, Sendable {
    public var range: Range<Int>
    public var kind: HighlightKind

    public init(range: Range<Int>, kind: HighlightKind) {
        self.range = range
        self.kind = kind
    }
}
