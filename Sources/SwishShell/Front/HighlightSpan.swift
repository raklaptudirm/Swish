/// What a stretch of source is, for coloring it as it is typed.
enum HighlightKind: Equatable, Sendable {
    case keyword, command, flag, string, number, constant, variable, comment, type, punctuation
}

struct HighlightSpan: Equatable, Sendable {
    var range: Range<Int>
    var kind: HighlightKind
}
