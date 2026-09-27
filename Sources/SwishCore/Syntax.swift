import Foundation
import SwishKit

// MARK: - AST

struct Program: Equatable, Sendable {
    var statements: [Statement]
}

enum Statement: Equatable, Sendable {
    case declare(name: String, mutable: Bool, value: Expr)
    case assign(name: String, value: Expr)
    case chain(Chain)
}

/// Units joined by `&&`/`||`, evaluated left to right on exit status.
struct Chain: Equatable, Sendable {
    var first: Unit
    var links: [Link] = []
}

struct Link: Equatable, Sendable {
    var op: ChainOperator
    var unit: Unit
}

enum ChainOperator: Equatable, Sendable {
    case and, or
}

indirect enum Unit: Equatable, Sendable {
    case pipeline(PipelineNode)
    case expression(Expr)
    case ifStatement(IfStatement)
}

struct IfStatement: Equatable, Sendable {
    var condition: Chain
    var then: Program
    var otherwise: Program?
}

struct PipelineNode: Equatable, Sendable {
    var commands: [CommandNode]
    /// The pipeline as typed, for job messages like "Stopped".
    var source: String
}

struct CommandNode: Equatable, Sendable {
    var words: [[StringPart]]
    /// `^name`: skip builtins and run the external program.
    var external = false
}

enum StringPart: Equatable, Sendable {
    case literal(String)
    case expression(Expr)
}

indirect enum Expr: Equatable, Sendable {
    case literal(Value)
    case string([StringPart])
    case variable(String)
    /// `$name`: a Swish variable, falling back to the environment.
    case dollar(String)
    /// `$?`
    case status
    /// `$(…)`
    case substitution(Program)
    case list([Expr])
    case unary(UnaryOperator, Expr)
    case binary(BinaryOperator, Expr, Expr)
    case index(Expr, Expr)
}

enum UnaryOperator: String, Sendable {
    case not = "!"
    case negate = "-"
}

enum BinaryOperator: String, Sendable {
    case or = "||", and = "&&"
    case equal = "==", notEqual = "!="
    case lessEqual = "<=", greaterEqual = ">=", less = "<", greater = ">"
    case add = "+", subtract = "-"
    case multiply = "*", divide = "/", remainder = "%"
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

// MARK: - Parser

/// A recursive-descent parser over characters rather than tokens, because
/// command mode and expression mode split text differently: `-la` is a word
/// in one and a negation in the other.
///
/// Mode is decided per unit, from its first token (see `startsExpression`).
/// Deciding it needs to know which variables exist, so the parser tracks
/// declarations lexically, seeded with the shell's global variables.
struct Parser {
    private static let keywords: Set = [
        "let", "var", "if", "else", "true", "false", "nil",
        "for", "in", "while", "func", "return", "break", "continue",
    ]
    private static let precedence: [[BinaryOperator]] = [
        [.or],
        [.and],
        // Two-character operators first, so `<=` isn't read as `<`.
        [.equal, .notEqual, .lessEqual, .greaterEqual, .less, .greater],
        [.add, .subtract],
        [.multiply, .divide, .remainder],
    ]
    private static let comparisonLevel = 2

    private let chars: [Character]
    private var pos = 0
    private var scopes: [Set<String>]
    /// Inside (), [] and \( ), newlines don't end an expression.
    private var bracketDepth = 0

    static func parse(_ source: String, bound: Set<String>) throws(SyntaxError) -> Program {
        var parser = Parser(source, bound: bound)
        return try parser.parseProgram(until: nil)
    }

    private init(_ source: String, bound: Set<String>) {
        chars = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        scopes = [bound]
    }

    // MARK: Statements

    private mutating func parseProgram(until terminator: Character?) throws(SyntaxError) -> Program {
        var statements: [Statement] = []
        while true {
            skipSeparators()
            guard let c = peek() else {
                if let terminator { throw .incomplete("expected '\(terminator)'") }
                break
            }
            if c == terminator { break }
            statements.append(try parseStatement())
            skipSpaces()
            guard let next = peek(), next != terminator else { continue }
            guard next == ";" || next == "\n" else { throw unexpected(next) }
        }
        return Program(statements: statements)
    }

    private mutating func parseStatement() throws(SyntaxError) -> Statement {
        if let word = identifier(), word == "let" || word == "var" {
            pos += word.count
            skipSpaces()
            guard let name = identifier() else { throw expected("a name after '\(word)'") }
            guard !Parser.keywords.contains(name) else { throw SyntaxError("'\(name)' is a keyword") }
            pos += name.count
            skipSpaces()
            guard peek() == "=" && peek(1) != "=" else { throw expected("'=' after '\(name)'") }
            pos += 1
            let value = try parseExpression()
            scopes[scopes.count - 1].insert(name)
            return .declare(name: name, mutable: word == "var", value: value)
        }

        if let name = identifier(), isBound(name) {
            let start = pos
            pos += name.count
            skipSpaces()
            if peek() == "=" && peek(1) != "=" {
                pos += 1
                return .assign(name: name, value: try parseExpression())
            }
            pos = start
        }

        return .chain(try parseChain())
    }

    private mutating func parseChain() throws(SyntaxError) -> Chain {
        var chain = Chain(first: try parseUnit())
        while true {
            skipSpaces()
            let op: ChainOperator
            if consume("&&") {
                op = .and
            } else if consume("||") {
                op = .or
            } else {
                return chain
            }
            skipSpaces(newlines: true)
            chain.links.append(Link(op: op, unit: try parseUnit()))
        }
    }

    private mutating func parseUnit() throws(SyntaxError) -> Unit {
        skipSpaces()
        guard let c = peek() else { throw .incomplete("expected a command") }
        switch identifier() {
        case "if":
            return .ifStatement(try parseIf())
        case "else":
            throw SyntaxError("'else' without a matching 'if'")
        case "let", "var":
            throw SyntaxError("a declaration must start a statement")
        case let word? where ["for", "in", "while", "func", "return", "break", "continue"].contains(word):
            throw SyntaxError("'\(word)' isn't supported yet")
        default:
            break
        }
        if startsExpression(c) {
            return .expression(try parseExpression(logical: false))
        }
        return .pipeline(try parsePipeline())
    }

    /// Whether a unit starting at `c` is an expression rather than a command:
    /// a literal, a bracket, `!` or `-`, a bound variable, or a call.
    ///
    /// `$` starts a command, as in `$EDITOR notes.txt`; `^` always does.
    private func startsExpression(_ c: Character) -> Bool {
        if Parser.isDigit(c) || "\"'([!-".contains(c) { return true }
        guard let word = identifier() else { return false }
        return ["true", "false", "nil"].contains(word) || isBound(word) || peek(word.count) == "("
    }

    private mutating func parseIf() throws(SyntaxError) -> IfStatement {
        pos += "if".count
        let condition = try parseChain()
        skipSpaces()
        let then = try parseBlock()

        let afterBlock = pos
        skipSpaces(newlines: true)
        guard identifier() == "else" else {
            pos = afterBlock
            return IfStatement(condition: condition, then: then)
        }
        pos += "else".count
        skipSpaces()
        if identifier() == "if" {
            let elseIf = Statement.chain(Chain(first: .ifStatement(try parseIf())))
            return IfStatement(condition: condition, then: then, otherwise: Program(statements: [elseIf]))
        }
        return IfStatement(condition: condition, then: then, otherwise: try parseBlock())
    }

    private mutating func parseBlock() throws(SyntaxError) -> Program {
        guard peek() == "{" else { throw expected("'{'") }
        pos += 1
        scopes.append([])
        defer { scopes.removeLast() }
        let body = try parseProgram(until: "}")
        pos += 1 // parseProgram only returns at the closing brace.
        return body
    }

    // MARK: Command mode

    private mutating func parsePipeline() throws(SyntaxError) -> PipelineNode {
        let start = pos
        var commands = [try parseCommand()]
        var end = pos
        while true {
            skipSpaces()
            guard peek() == "|", peek(1) != "|" else { break }
            pos += 1
            skipSpaces(newlines: true)
            commands.append(try parseCommand())
            end = pos
        }
        let source = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return PipelineNode(commands: commands, source: source)
    }

    private mutating func parseCommand() throws(SyntaxError) -> CommandNode {
        skipSpaces()
        let external = consume("^")
        var words: [[StringPart]] = []
        while true {
            skipSpaces()
            guard let c = peek(), !endsCommand(c) else { break }
            if c == "(" {
                throw SyntaxError("unexpected '(' in a command; quote it, or use \\(…) to interpolate an expression")
            }
            if c == "&" {
                throw SyntaxError("background jobs ('&') aren't supported yet")
            }
            words.append(try parseWord())
        }
        guard !words.isEmpty else {
            if let c = peek() { throw unexpected(c) }
            throw .incomplete("expected a command")
        }
        return CommandNode(words: words, external: external)
    }

    private func endsCommand(_ c: Character) -> Bool {
        switch c {
        case "|", ";", "\n", ")", "}": true
        case "&": peek(1) == "&"
        case "{": peek(1) != "}"
        default: false
        }
    }

    private func isWordBoundary(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || "|;&(){}".contains(c)
    }

    private mutating func parseWord() throws(SyntaxError) -> [StringPart] {
        var parts: [StringPart] = []
        var literal = ""
        func flush() {
            if !literal.isEmpty { parts.append(.literal(literal)) }
            literal = ""
        }

        if peek() == "~", peek(1).map({ $0 == "/" || isWordBoundary($0) }) ?? true {
            parts.append(.expression(.dollar("HOME")))
            pos += 1
        }

        while let c = peek() {
            // `{}` is a word (as in `find -exec … {} \;`), not a block.
            if c == "{" && peek(1) == "}" {
                literal += "{}"
                pos += 2
                continue
            }
            if isWordBoundary(c) { break }
            switch c {
            case "'":
                flush()
                parts.append(.literal(try parseRawString()))
            case "\"":
                flush()
                parts += try parseInterpolatedString()
            case "\\":
                guard let next = peek(1) else { throw .incomplete("expected a character after '\\'") }
                if next == "(" {
                    flush()
                    parts.append(.expression(try parseInterpolation()))
                } else if next == "\n" {
                    pos += 2
                } else {
                    literal.append(next)
                    pos += 2
                }
            case "$":
                if let expr = try parseDollar() {
                    flush()
                    parts.append(.expression(expr))
                } else {
                    literal.append(c)
                    pos += 1
                }
            default:
                literal.append(c)
                pos += 1
            }
        }
        flush()
        return parts
    }

    // MARK: Strings and interpolation

    private mutating func parseRawString() throws(SyntaxError) -> String {
        guard let end = chars[(pos + 1)...].firstIndex(of: "'") else {
            throw .incomplete("unterminated string")
        }
        let text = String(chars[(pos + 1)..<end])
        pos = end + 1
        return text
    }

    /// A double-quoted string, the same in both modes: Swift escapes and
    /// `\(…)`, plus `$name`, `$?` and `$(…)`.
    private mutating func parseInterpolatedString() throws(SyntaxError) -> [StringPart] {
        pos += 1
        var parts: [StringPart] = []
        var literal = ""
        while true {
            guard let c = peek() else { throw .incomplete("unterminated string") }
            switch c {
            case "\"":
                pos += 1
                if !literal.isEmpty || parts.isEmpty { parts.append(.literal(literal)) }
                return parts
            case "\\":
                guard let next = peek(1) else { throw .incomplete("unterminated string") }
                if next == "(" {
                    if !literal.isEmpty { parts.append(.literal(literal)) }
                    literal = ""
                    parts.append(.expression(try parseInterpolation()))
                    continue
                }
                pos += 2
                switch next {
                case "n": literal.append("\n")
                case "t": literal.append("\t")
                case "r": literal.append("\r")
                case "0": literal.append("\0")
                case "\\", "\"", "'", "$": literal.append(next)
                case "u": literal.append(try parseUnicodeEscape())
                default: throw SyntaxError("invalid escape '\\\(next)' in string")
                }
            case "$":
                if let expr = try parseDollar() {
                    if !literal.isEmpty { parts.append(.literal(literal)) }
                    literal = ""
                    parts.append(.expression(expr))
                } else {
                    literal.append(c)
                    pos += 1
                }
            default:
                literal.append(c)
                pos += 1
            }
        }
    }

    /// `\u{1F600}`, positioned after the `u`.
    private mutating func parseUnicodeEscape() throws(SyntaxError) -> Character {
        guard consume("{") else { throw SyntaxError("expected '{' after '\\u'") }
        var hex = ""
        while let c = peek(), c.isHexDigit {
            hex.append(c)
            pos += 1
        }
        guard consume("}"), let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw SyntaxError("invalid unicode escape '\\u{\(hex)'")
        }
        return Character(scalar)
    }

    /// `\(expression)`, positioned at the backslash.
    private mutating func parseInterpolation() throws(SyntaxError) -> Expr {
        pos += 2
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        skipSpaces()
        let expr = try parseExpression()
        skipSpaces()
        guard consume(")") else { throw expected("')'") }
        return expr
    }

    /// `$(…)`, `$?` or `$name`, positioned at the dollar sign; nil if the
    /// dollar is just a character.
    private mutating func parseDollar() throws(SyntaxError) -> Expr? {
        switch peek(1) {
        case "(":
            pos += 2
            // Newlines separate statements again inside a substitution.
            let savedDepth = bracketDepth
            bracketDepth = 0
            scopes.append([])
            defer {
                bracketDepth = savedDepth
                scopes.removeLast()
            }
            let program = try parseProgram(until: ")")
            pos += 1
            return .substitution(program)
        case "?":
            pos += 2
            return .status
        case let c? where Parser.isIdentifierStart(c):
            pos += 1
            let name = identifier()!
            pos += name.count
            return .dollar(name)
        default:
            return nil
        }
    }

    // MARK: Expression mode

    /// `logical` is false for an expression that is a whole unit, so that
    /// `&&` and `||` are left to join it with commands in a chain.
    private mutating func parseExpression(logical: Bool = true) throws(SyntaxError) -> Expr {
        try parseBinary(level: logical ? 0 : Parser.comparisonLevel)
    }

    private mutating func parseBinary(level: Int) throws(SyntaxError) -> Expr {
        guard level < Parser.precedence.count else { return try parseUnary() }
        var lhs = try parseBinary(level: level + 1)
        var compared = false
        while true {
            skipSpaces()
            guard let op = Parser.precedence[level].first(where: { startsWith($0.rawValue) }) else {
                return lhs
            }
            if level == Parser.comparisonLevel {
                if compared { throw SyntaxError("comparisons can't be chained; use '&&'") }
                compared = true
            }
            pos += op.rawValue.count
            skipSpaces(newlines: true)
            lhs = .binary(op, lhs, try parseBinary(level: level + 1))
        }
    }

    private mutating func parseUnary() throws(SyntaxError) -> Expr {
        skipSpaces()
        if consume("!") { return .unary(.not, try parseUnary()) }
        if consume("-") { return .unary(.negate, try parseUnary()) }
        var expr = try parsePrimary()
        while peek() == "[" {
            pos += 1
            bracketDepth += 1
            skipSpaces()
            let index = try parseExpression()
            skipSpaces()
            guard consume("]") else { throw expected("']'") }
            bracketDepth -= 1
            expr = .index(expr, index)
        }
        return expr
    }

    private mutating func parsePrimary() throws(SyntaxError) -> Expr {
        skipSpaces()
        guard let c = peek() else { throw .incomplete("expected an expression") }
        if Parser.isDigit(c) { return try parseNumber() }

        switch c {
        case "\"":
            let parts = try parseInterpolatedString()
            if parts.count == 1, case .literal(let text) = parts[0] { return .literal(.string(text)) }
            return .string(parts)
        case "'":
            return .literal(.string(try parseRawString()))
        case "(":
            pos += 1
            bracketDepth += 1
            defer { bracketDepth -= 1 }
            skipSpaces()
            let expr = try parseExpression()
            skipSpaces()
            guard consume(")") else { throw expected("')'") }
            return expr
        case "[":
            return try parseList()
        case "$":
            if let expr = try parseDollar() { return expr }
            throw unexpected(c)
        default:
            break
        }

        guard let name = identifier() else { throw unexpected(c) }
        pos += name.count
        switch name {
        case "true": return .literal(.bool(true))
        case "false": return .literal(.bool(false))
        case "nil": return .literal(.nothing)
        default: break
        }
        if Parser.keywords.contains(name) {
            throw SyntaxError("expected an expression, found '\(name)'")
        }
        if peek() == "(" {
            throw SyntaxError("calling functions isn't supported yet")
        }
        guard isBound(name) else { throw SyntaxError("no variable named '\(name)'") }
        return .variable(name)
    }

    private mutating func parseList() throws(SyntaxError) -> Expr {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var elements: [Expr] = []
        skipSpaces()
        while peek() != "]" {
            elements.append(try parseExpression())
            skipSpaces()
            guard consume(",") else { break }
            skipSpaces()
        }
        guard consume("]") else { throw expected("']'") }
        return .list(elements)
    }

    private mutating func parseNumber() throws(SyntaxError) -> Expr {
        var text = readDigits()
        var isDouble = false
        if peek() == ".", let next = peek(1), Parser.isDigit(next) {
            isDouble = true
            pos += 1
            text += "." + readDigits()
        }
        if let c = peek(), Parser.isIdentifierPart(c) {
            throw SyntaxError("unexpected '\(c)' after a number (use ^ to run a command whose name starts with a digit)")
        }
        if isDouble { return .literal(.double(Double(text)!)) }
        guard let value = Int(text) else { throw SyntaxError("integer literal \(text) is too large") }
        return .literal(.int(value))
    }

    // MARK: Scanning

    /// Digits with optional `_` separators, which are dropped.
    private mutating func readDigits() -> String {
        var digits = ""
        while let c = peek(), Parser.isDigit(c) || c == "_" {
            if c != "_" { digits.append(c) }
            pos += 1
        }
        return digits
    }

    private func peek(_ offset: Int = 0) -> Character? {
        let index = pos + offset
        return index < chars.count ? chars[index] : nil
    }

    private func startsWith(_ text: String) -> Bool {
        var index = pos
        for c in text {
            guard index < chars.count, chars[index] == c else { return false }
            index += 1
        }
        return true
    }

    private mutating func consume(_ text: String) -> Bool {
        guard startsWith(text) else { return false }
        pos += text.count
        return true
    }

    /// The identifier starting at the current position, without consuming it.
    private func identifier() -> String? {
        guard let first = peek(), Parser.isIdentifierStart(first) else { return nil }
        var name = String(first)
        while let c = peek(name.count), Parser.isIdentifierPart(c) {
            name.append(c)
        }
        return name
    }

    private func isBound(_ name: String) -> Bool {
        scopes.contains { $0.contains(name) }
    }

    /// Skips blanks, line continuations and comments; newlines too when
    /// asked or inside brackets.
    private mutating func skipSpaces(newlines: Bool = false) {
        while let c = peek() {
            if c == " " || c == "\t" {
                pos += 1
            } else if c == "\\" && peek(1) == "\n" {
                pos += 2
            } else if c == "\n" && (newlines || bracketDepth > 0) {
                pos += 1
            } else if c == "#" {
                while let d = peek(), d != "\n" { pos += 1 }
            } else {
                return
            }
        }
    }

    private mutating func skipSeparators() {
        while true {
            skipSpaces()
            guard peek() == ";" || peek() == "\n" else { return }
            pos += 1
        }
    }

    private func unexpected(_ c: Character) -> SyntaxError {
        SyntaxError(c == "\n" ? "unexpected newline" : "unexpected '\(c)'")
    }

    private func expected(_ what: String) -> SyntaxError {
        guard let c = peek() else { return .incomplete("expected \(what)") }
        return SyntaxError("expected \(what), found \(c == "\n" ? "newline" : "'\(c)'")")
    }

    private static func isDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }

    private static func isIdentifierStart(_ c: Character) -> Bool {
        c == "_" || c.isLetter
    }

    private static func isIdentifierPart(_ c: Character) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }
}
