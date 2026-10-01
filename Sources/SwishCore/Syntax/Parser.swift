import Foundation
import SwishKit

/// What a name refers to, which decides the mode of a statement starting
/// with it: a variable starts an expression, a function starts a command
/// unless it's followed by `(`.
enum NameKind: Equatable, Sendable {
    /// `type`: an enum's or struct's name, as in `FileType.directory`.
    /// `member`: a property or method of the struct whose body this is,
    /// read through `self`.
    case variable, function, type, member
}

public struct SyntaxError: Error, Equatable, CustomStringConvertible {
    public let description: String
    /// The input ended in the middle of a construct, so more lines could complete it.
    public let incomplete: Bool

    init(_ description: String, incomplete: Bool = false) {
        self.description = description
        self.incomplete = incomplete
    }

    static func incomplete(_ description: String) -> SyntaxError {
        SyntaxError(description, incomplete: true)
    }
}

/// What a stretch of source is, for syntax highlighting. The parser
/// records these as it goes, so the colors always agree with how the line
/// will actually be read.
enum SpanKind: Equatable, Sendable {
    case keyword, command, flag, string, number, constant, variable, comment, type, punctuation
}

struct Span: Equatable, Sendable {
    var range: Range<Int>
    var kind: SpanKind
}

// MARK: - Parser

/// A recursive-descent parser over characters rather than tokens, because
/// command mode and expression mode split text differently: `-la` is a word
/// in one and a negation in the other.
///
/// Mode is decided per unit, by what parses there (see `commandAhead`).
/// Deciding it needs to know which names exist and what they are, so the
/// parser tracks declarations lexically, seeded with the shell's globals.
struct Parser {
    static let keywords: Set = [
        "let", "var", "if", "else", "true", "false", "nil",
        "for", "in", "while", "func", "return", "break", "continue", "try", "do", "catch",
        "async", "await", "enum", "switch", "case", "default", "fallthrough", "import", "struct", "throws",
        "as", "is", "defer", "guard",
    ]
    static let statementKeywords: Set = ["let", "var", "func", "return", "break", "continue", "do", "catch", "enum", "fallthrough", "import", "struct", "defer", "guard"]
    static let precedence: [[BinaryOperator]] = [
        [.or],
        [.and],
        // Two-character operators first, so `<=` isn't read as `<`.
        [.equal, .notEqual, .lessEqual, .greaterEqual, .less, .greater],
        [.coalesce],
        [.closedRange, .halfOpenRange],
        [.add, .subtract],
        [.multiply, .divide, .remainder],
    ]
    static let comparisonLevel = 2
    static let fileSizeUnits: [String: Int64] = [
        "b": 1, "kb": 1_000, "mb": 1_000_000, "gb": 1_000_000_000, "tb": 1_000_000_000_000,
        "kib": 1 << 10, "mib": 1 << 20, "gib": 1 << 30, "tib": 1 << 40,
    ]
    /// Levels whose operators can't be chained, like `a < b < c`.
    static let nonAssociativeLevels: Set = [2, 4]

    let chars: [Character]
    var pos = 0
    var scopes: [[String: NameKind]]
    /// Parsing the prelude: builtins' declarations, which may be generic and
    /// have no bodies (their bodies are in Swift).
    var prelude = false
    /// Type parameters in scope, innermost last: `T`, or `Element`.
    var typeParameters: [Set<String>] = []
    /// The names each body being parsed mentions, innermost last.
    var namesUsed: [Set<String>] = []
    /// What the body just parsed mentioned.
    var lastBodyNames = NamesUsed()

    /// A name the body being parsed refers to.
    mutating func use(_ name: String) {
        guard !namesUsed.isEmpty else { return }
        namesUsed[namesUsed.count - 1].insert(name)
    }
    /// An `import` came earlier: the functions it brings aren't known until
    /// it runs, so calling an unknown name is left for then.
    var sawImport = false
    /// Where each line starts, for `line(at:)`.
    var lineStarts: [Int] = [0]
    /// Inside (), [] and \( ), newlines don't end an expression.
    var bracketDepth = 0
    var loopDepth = 0
    var functionDepth = 0
    /// Inside a switch's cases, where `fallthrough` and `break` make sense.
    var switchDepth = 0
    /// Inside an `if`/`while` condition, `{` after a command starts the body
    /// rather than a closure argument.
    var conditionDepth = 0
    /// In a guard's condition, where a command ends at `else`.
    var guardCondition = false
    /// Inside the operand of `try`, `try?` or `try!`, where `$(…)` throws
    /// when its command fails. Closures and function bodies start afresh:
    /// they decide for themselves whether to throw, as in Swift.
    var tryDepth = 0
    /// One entry per enclosing function or closure: how many `$n`
    /// parameters a closure without named parameters uses, or nil if its
    /// parameters are named.
    var anonymousArity: [Int?] = []

    /// Highlight spans, in the order recorded; inner spans (like an
    /// interpolation inside a string) are shorter than what contains them.
    /// Input that doesn't parse yet, as while typing, still gets the spans
    /// found before the problem.
    private(set) var spans: [Span] = []

    static func parse(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program {
        var parser = Parser(source, bound: bound)
        return try parser.parseProgram(until: nil)
    }

    /// The prelude: builtins' types and signatures (see Prelude.swift).
    static func parsePrelude(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program {
        var parser = Parser(source, bound: bound)
        parser.prelude = true
        return try parser.parseProgram(until: nil)
    }

    static func highlight(_ source: String, bound: [String: NameKind]) -> [Span] {
        var parser = Parser(source, bound: bound)
        _ = try? parser.parseProgram(until: nil)
        return parser.spans
    }

    mutating func mark(_ kind: SpanKind, from start: Int, to end: Int? = nil) {
        let end = min(end ?? pos, chars.count)
        if start < end { spans.append(Span(range: start..<end, kind: kind)) }
    }

    /// Backs up after looking ahead, dropping spans recorded on the way.
    mutating func rewind(to state: (position: Int, spans: Int)) {
        pos = state.position
        spans.removeSubrange(state.spans...)
    }

    /// Consumes a keyword known to be at the current position.
    mutating func keyword(_ word: String) {
        mark(.keyword, from: pos, to: pos + word.count)
        pos += word.count
    }

    init(_ source: String, bound: [String: NameKind]) {
        chars = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        scopes = [bound]
        for (index, c) in chars.enumerated() where c == "\n" { lineStarts.append(index + 1) }
    }

}
