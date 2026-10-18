@_spi(Layer) import Swiit
import Foundation

// Spike: where a layer reads its own text. The interpreter hands the layer a reader positioned in the source at a place its
// grammar has no meaning for; the layer scans characters (`-la` is a word in a command and a negation in an expression), and
// asks the reader for the Swift inside its forms.

/// What went wrong reading, in the words a person reads; `incomplete` when more input could finish it.
struct ParseFailure: Error {
    var message: String
    var incomplete: Bool

    init(_ message: String, incomplete: Bool = false) {
        self.message = message
        self.incomplete = incomplete
    }

    static func incomplete(_ message: String) -> ParseFailure { ParseFailure(message, incomplete: true) }

    init(_ raw: SyntaxError) {
        message = raw.description
        incomplete = raw.incomplete
    }

    var raw: SyntaxError { SyntaxError(message, incomplete: incomplete) }
}

/// What a stretch of source is, for coloring it as it is typed.
enum HighlightRole: Equatable, Sendable {
    case keyword, command, flag, string, number, constant, variable, comment, type, punctuation

    var raw: SpanKind {
        switch self {
        case .keyword: .keyword
        case .command: .command
        case .flag: .flag
        case .string: .string
        case .number: .number
        case .constant: .constant
        case .variable: .variable
        case .comment: .comment
        case .type: .type
        case .punctuation: .punctuation
        }
    }
}

/// What a name refers to where the reader is, which decides the mode of a statement starting with it.
enum NameRole: Equatable {
    case variable, function, type, member, staticMember

    init?(_ raw: NameKind?) {
        switch raw {
        case .variable?: self = .variable
        case .function?: self = .function
        case .type?: self = .type
        case .member?: self = .member
        case .staticMember?: self = .staticMember
        case .operatorDeclaration?, nil: return nil
        }
    }
}

struct SourceReader {
    var cursor: SourceCursor
    init(_ cursor: SourceCursor) { self.cursor = cursor }

    // MARK: Where it is

    /// The index of the next character.
    var position: Int {
        get { cursor.pos }
        set { cursor.pos = newValue }
    }
    var characters: [Character] { cursor.chars }

    func peek(_ offset: Int = 0) -> Character? { cursor.peek(offset) }
    func startsWith(_ text: String) -> Bool { cursor.startsWith(text) }
    mutating func consume(_ text: String) -> Bool { cursor.consume(text) }
    func identifier() -> String? { cursor.identifier() }
    mutating func skipSpaces(newlines: Bool = false) { cursor.skipSpaces(newlines: newlines) }
    func text(from start: Int, to end: Int) -> String { String(cursor.chars[start..<end]) }

    // MARK: What it knows of where it is

    func role(of name: String) -> NameRole? { NameRole(cursor.kind(of: name)) }
    /// A name the layer's forms mention, which a closure or function around them keeps.
    mutating func use(_ name: String) { cursor.use(name) }
    /// Names declared inside a form of the layer's are its own.
    mutating func enterScope() { cursor.scopes.append([:]) }
    mutating func leaveScope() { cursor.scopes.removeLast() }

    var bracketDepth: Int { get { cursor.bracketDepth } set { cursor.bracketDepth = newValue } }
    var loopDepth: Int { get { cursor.loopDepth } set { cursor.loopDepth = newValue } }
    var functionDepth: Int { get { cursor.functionDepth } set { cursor.functionDepth = newValue } }
    var switchDepth: Int { get { cursor.switchDepth } set { cursor.switchDepth = newValue } }
    var conditionDepth: Int { get { cursor.conditionDepth } set { cursor.conditionDepth = newValue } }
    var tryDepth: Int { get { cursor.tryDepth } set { cursor.tryDepth = newValue } }
    var guardCondition: Bool { get { cursor.guardCondition } set { cursor.guardCondition = newValue } }
    var inAnonymousClosure: Bool { cursor.inAnonymousClosure }

    // MARK: What it records

    mutating func mark(_ role: HighlightRole, from start: Int, to end: Int? = nil) { cursor.mark(role.raw, from: start, to: end) }
    mutating func keyword(_ word: String) { cursor.keyword(word) }

    func expected(_ what: String) -> ParseFailure { ParseFailure(cursor.expected(what)) }
    func unexpected(_ character: Character) -> ParseFailure { ParseFailure(cursor.unexpected(character)) }

    // MARK: The Swift inside the layer's forms

    mutating func parseExpression(logical: Bool = true) throws(ParseFailure) -> SwiftExpression {
        do { return SwiftExpression(try cursor.parseExpression(logical: logical)) } catch { throw ParseFailure(error) }
    }

    mutating func parseClosure() throws(ParseFailure) -> SwiftClosure {
        do { return SwiftClosure(try cursor.parseClosure()) } catch { throw ParseFailure(error) }
    }

    mutating func parseArguments() throws(ParseFailure) -> [SwiftArgument] {
        do { return try cursor.parseArguments().map(SwiftArgument.init) } catch { throw ParseFailure(error) }
    }

    mutating func parseProgram(until terminator: Character) throws(ParseFailure) -> SwiftBlock {
        do { return SwiftBlock(try cursor.parseProgram(until: terminator)) } catch { throw ParseFailure(error) }
    }

    /// `try`, `try?` or `try!` at the current position, or nil if there is none.
    mutating func parseTry() throws(ParseFailure) -> TryStyle?? {
        do { return try cursor.parseTry().map { $0.map(TryStyle.init) } } catch { throw ParseFailure(error) }
    }

    // MARK: Characters

    static let statementKeywords = SourceCursor.statementKeywords
    static func isDigit(_ c: Character) -> Bool { SourceCursor.isDigit(c) }
    static func isIdentifierStart(_ c: Character) -> Bool { SourceCursor.isIdentifierStart(c) }
    static func isIdentifierPart(_ c: Character) -> Bool { SourceCursor.isIdentifierPart(c) }
}

/// A syntax a layer adds to Swift's: asked at the places where Swift's grammar has no meaning for what is there.
protocol SyntaxLayer: Sendable {
    /// Where an expression statement or a condition starts: the layer's own, or nil to read Swift.
    func chain(_ reader: inout SourceReader, condition: Bool) throws(ParseFailure) -> SwiftExpression?
    /// After a Swift expression statement, with the reader at what follows it: what the layer continues it into, or nil.
    func continuing(_ expression: SwiftExpression, from start: Int, _ reader: inout SourceReader) throws(ParseFailure) -> SwiftExpression?
    /// Where an expression starts that Swift's grammar doesn't have: the layer's, or nil.
    func expression(_ reader: inout SourceReader) throws(ParseFailure) -> SwiftExpression?
}

/// The interpreter's plug-in for a layer.
struct LayerPlugin<Layer: SyntaxLayer>: SyntaxPlugin {
    let layer: Layer
    init(_ layer: Layer) { self.layer = layer }

    func chain(_ cursor: inout SourceCursor, condition: Bool) throws(SyntaxError) -> Expr? {
        var reader = SourceReader(cursor)
        defer { cursor = reader.cursor }
        do { return try layer.chain(&reader, condition: condition)?.raw } catch { throw error.raw }
    }

    func continuing(_ expression: Expr, from start: Int, _ cursor: inout SourceCursor) throws(SyntaxError) -> Expr? {
        var reader = SourceReader(cursor)
        defer { cursor = reader.cursor }
        do { return try layer.continuing(SwiftExpression(expression), from: start, &reader)?.raw } catch { throw error.raw }
    }

    func expression(_ cursor: inout SourceCursor) throws(SyntaxError) -> Expr? {
        var reader = SourceReader(cursor)
        defer { cursor = reader.cursor }
        do { return try layer.expression(&reader)?.raw } catch { throw error.raw }
    }
}
