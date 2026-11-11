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

extension Sequence where Element == HighlightSpan {
    /// The style of each of `count` characters: the span that covers it, and for a span inside
    /// another (an interpolation in a string) the inner one. Characters no span covers have none.
    public func paintedStyles(count: Int) -> [DisplayStyle?] {
        var styles = [DisplayStyle?](repeating: nil, count: count)
        // Longer spans first, so what is inside them is painted over them.
        for span in sorted(by: { $0.range.count > $1.range.count }) {
            for index in span.range.clamped(to: 0..<count) {
                styles[index] = span.kind.displayStyle
            }
        }
        return styles
    }
}
