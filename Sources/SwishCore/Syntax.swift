import Foundation
import SwishKit

// MARK: - AST

struct Program: Equatable, Sendable {
    var statements: [Statement]
}

enum Statement: Equatable, Sendable {
    case declare(name: String, mutable: Bool, value: Expr)
    case assign(name: String, value: Expr)
    case function(FunctionDecl)
    case returnStatement(Expr?)
    case breakStatement
    case continueStatement
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
    case forLoop(ForLoop)
    case whileLoop(WhileLoop)
}

struct IfStatement: Equatable, Sendable {
    var condition: Chain
    var then: Program
    var otherwise: Program?
}

struct ForLoop: Equatable, Sendable {
    var variable: String
    var sequence: Expr
    var body: Program
}

struct WhileLoop: Equatable, Sendable {
    var condition: Chain
    var body: Program
}

struct FunctionDecl: Equatable, Sendable {
    var name: String
    var parameters: [Parameter]
    var returnType: TypeAnnotation?
    var body: Program
}

struct ClosureLiteral: Equatable, Sendable {
    /// For `{ $0 * 2 }`, the implicit `$0`, `$1`, … parameters.
    var parameters: [Parameter]
    var returnType: TypeAnnotation?
    var body: Program
}

struct Parameter: Equatable, Sendable {
    /// The argument label; nil for `_` (positional in command mode).
    var label: String?
    var name: String
    var type: TypeAnnotation = .any
    var variadic = false
    var defaultValue: Expr?
}

indirect enum TypeAnnotation: Equatable, Sendable, CustomStringConvertible {
    case any, bool, int, double, string
    case list(TypeAnnotation)
    case function

    var description: String {
        switch self {
        case .any: "Any"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .list(let element): "[\(element)]"
        case .function: "function"
        }
    }
}

struct PipelineNode: Equatable, Sendable {
    var commands: [CommandNode]
    /// The pipeline as typed, for job messages like "Stopped".
    var source: String
}

struct CommandNode: Equatable, Sendable {
    var words: [[StringPart]]
    /// `^name`: skip functions and builtins, and run the external program.
    var external = false
}

enum StringPart: Equatable, Sendable {
    case literal(String)
    case expression(Expr)
}

struct Argument: Equatable, Sendable {
    var label: String?
    var value: Expr
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
    case closure(ClosureLiteral)
    case call(Expr, [Argument])
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
    case closedRange = "...", halfOpenRange = "..<"
    case add = "+", subtract = "-"
    case multiply = "*", divide = "/", remainder = "%"
}

/// What a name refers to, which decides the mode of a statement starting
/// with it: a variable starts an expression, a function starts a command
/// unless it's followed by `(`.
enum NameKind: Equatable, Sendable {
    case variable, function
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
/// Deciding it needs to know which names exist and what they are, so the
/// parser tracks declarations lexically, seeded with the shell's globals.
struct Parser {
    private static let keywords: Set = [
        "let", "var", "if", "else", "true", "false", "nil",
        "for", "in", "while", "func", "return", "break", "continue",
    ]
    private static let statementKeywords: Set = ["let", "var", "func", "return", "break", "continue"]
    private static let precedence: [[BinaryOperator]] = [
        [.or],
        [.and],
        // Two-character operators first, so `<=` isn't read as `<`.
        [.equal, .notEqual, .lessEqual, .greaterEqual, .less, .greater],
        [.closedRange, .halfOpenRange],
        [.add, .subtract],
        [.multiply, .divide, .remainder],
    ]
    private static let comparisonLevel = 2
    /// Levels whose operators can't be chained, like `a < b < c`.
    private static let nonAssociativeLevels: Set = [2, 3]

    private let chars: [Character]
    private var pos = 0
    private var scopes: [[String: NameKind]]
    /// Inside (), [] and \( ), newlines don't end an expression.
    private var bracketDepth = 0
    private var loopDepth = 0
    private var functionDepth = 0
    /// One entry per enclosing function or closure: how many `$n`
    /// parameters a closure without named parameters uses, or nil if its
    /// parameters are named.
    private var anonymousArity: [Int?] = []

    static func parse(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program {
        var parser = Parser(source, bound: bound)
        return try parser.parseProgram(until: nil)
    }

    private init(_ source: String, bound: [String: NameKind]) {
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
        switch identifier() {
        case "let", "var":
            return try parseDeclaration()
        case "func":
            return .function(try parseFunction())
        case "return":
            guard functionDepth > 0 else { throw SyntaxError("'return' outside a function") }
            pos += "return".count
            skipSpaces()
            guard let c = peek(), c != ";" && c != "\n" && c != "}" else { return .returnStatement(nil) }
            return .returnStatement(try parseExpression())
        case let word? where word == "break" || word == "continue":
            guard loopDepth > 0 else { throw SyntaxError("'\(word)' outside a loop") }
            pos += word.count
            return word == "break" ? .breakStatement : .continueStatement
        default:
            break
        }

        if let name = identifier(), kind(of: name) == .variable {
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

    private mutating func parseDeclaration() throws(SyntaxError) -> Statement {
        let keyword = identifier()!
        pos += keyword.count
        skipSpaces()
        let name = try parseName(after: "'\(keyword)'")
        skipSpaces()
        guard peek() == "=" && peek(1) != "=" else { throw expected("'=' after '\(name)'") }
        pos += 1
        let value = try parseExpression()
        scopes[scopes.count - 1][name] = .variable
        return .declare(name: name, mutable: keyword == "var", value: value)
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
        case "for":
            return .forLoop(try parseFor())
        case "while":
            return .whileLoop(try parseWhile())
        case "else":
            throw SyntaxError("'else' without a matching 'if'")
        case "in":
            throw SyntaxError("unexpected 'in'")
        case let word? where Parser.statementKeywords.contains(word):
            throw SyntaxError("'\(word)' must start a statement")
        default:
            break
        }
        if startsExpression(c) {
            return .expression(try parseExpression(logical: false))
        }
        return .pipeline(try parsePipeline())
    }

    /// Whether a unit starting at `c` is an expression rather than a command:
    /// a literal, a bracket, `!` or `-`, a variable, or a call.
    ///
    /// A function name without `(` starts a command (`greet Rak --loud`).
    /// `$` starts a command, as in `$EDITOR notes.txt`, except for a closure's
    /// `$0`; `^` always starts a command.
    private func startsExpression(_ c: Character) -> Bool {
        if Parser.isDigit(c) || "\"'([!-".contains(c) { return true }
        if c == "$", let next = peek(1), Parser.isDigit(next), anonymousArity.last ?? nil != nil { return true }
        guard let word = identifier() else { return false }
        if ["true", "false", "nil"].contains(word) { return true }
        return kind(of: word) == .variable || peek(word.count) == "("
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

    private mutating func parseFor() throws(SyntaxError) -> ForLoop {
        pos += "for".count
        skipSpaces()
        let variable = try parseName(after: "'for'")
        skipSpaces()
        guard identifier() == "in" else { throw expected("'in'") }
        pos += "in".count
        let sequence = try parseExpression()
        skipSpaces()
        loopDepth += 1
        defer { loopDepth -= 1 }
        let body = try parseBlock(declaring: variable == "_" ? [:] : [variable: .variable])
        return ForLoop(variable: variable, sequence: sequence, body: body)
    }

    private mutating func parseWhile() throws(SyntaxError) -> WhileLoop {
        pos += "while".count
        let condition = try parseChain()
        skipSpaces()
        loopDepth += 1
        defer { loopDepth -= 1 }
        return WhileLoop(condition: condition, body: try parseBlock())
    }

    private mutating func parseBlock(declaring names: [String: NameKind] = [:]) throws(SyntaxError) -> Program {
        guard peek() == "{" else { throw expected("'{'") }
        pos += 1
        scopes.append(names)
        defer { scopes.removeLast() }
        let body = try parseProgram(until: "}")
        pos += 1 // parseProgram only returns at the closing brace.
        return body
    }

    // MARK: Functions and closures

    private mutating func parseFunction() throws(SyntaxError) -> FunctionDecl {
        pos += "func".count
        skipSpaces()
        let name = try parseName(after: "'func'")
        guard name != "_" else { throw SyntaxError("a function needs a name") }
        skipSpaces()
        guard peek() == "(" else { throw expected("'(' after '\(name)'") }
        let parameters = try parseParameters(named: true)
        skipSpaces()
        var returnType: TypeAnnotation?
        if consume("->") {
            returnType = try parseType()
            skipSpaces()
        }
        guard consume("{") else { throw expected("'{'") }
        // Bound before the body is parsed, so the function can call itself.
        scopes[scopes.count - 1][name] = .function
        let (body, _) = try parseFunctionBody(parameters: parameters, anonymous: false)
        return FunctionDecl(name: name, parameters: parameters, returnType: returnType, body: body)
    }

    /// A closure, positioned after its opening brace: `{ x, y in … }`,
    /// `{ (x: Int) -> Int in … }`, or `{ $0 * 2 }`.
    private mutating func parseClosure() throws(SyntaxError) -> ClosureLiteral {
        var named: (parameters: [Parameter], returnType: TypeAnnotation?)?
        let beforeHead = self
        do {
            named = try parseClosureHead()
        } catch {
            self = beforeHead
        }
        let (body, arity) = try parseFunctionBody(parameters: named?.parameters ?? [], anonymous: named == nil)
        let parameters = named?.parameters ?? (0..<arity).map { Parameter(label: nil, name: "$\($0)") }
        return ClosureLiteral(parameters: parameters, returnType: named?.returnType, body: body)
    }

    private mutating func parseClosureHead() throws(SyntaxError) -> ([Parameter], TypeAnnotation?) {
        skipSpaces(newlines: true)
        var parameters: [Parameter] = []
        if peek() == "(" {
            parameters = try parseParameters(named: false)
        } else {
            while true {
                parameters.append(Parameter(label: nil, name: try parseName(after: "'{'")))
                skipSpaces()
                guard consume(",") else { break }
                skipSpaces()
            }
            try validate(parameters)
        }
        skipSpaces()
        var returnType: TypeAnnotation?
        if consume("->") {
            returnType = try parseType()
            skipSpaces()
        }
        guard identifier() == "in" else { throw expected("'in'") }
        pos += "in".count
        return (parameters, returnType)
    }

    /// Statements up to the closing brace, whose opening brace is already
    /// consumed, in a new function scope. Returns the `$n` arity for
    /// anonymous closures.
    private mutating func parseFunctionBody(
        parameters: [Parameter], anonymous: Bool
    ) throws(SyntaxError) -> (Program, Int) {
        let saved = (loopDepth, bracketDepth)
        loopDepth = 0
        bracketDepth = 0
        functionDepth += 1
        var names: [String: NameKind] = [:]
        for parameter in parameters where parameter.name != "_" {
            names[parameter.name] = .variable
        }
        scopes.append(names)
        anonymousArity.append(anonymous ? 0 : nil)
        defer {
            (loopDepth, bracketDepth) = saved
            functionDepth -= 1
            scopes.removeLast()
            anonymousArity.removeLast()
        }
        let body = try parseProgram(until: "}")
        pos += 1
        return (body, anonymousArity.last! ?? 0)
    }

    /// `(label name: Type = default, …)` for functions (`named`), or
    /// `(name: Type, …)` for closures, where types are optional.
    private mutating func parseParameters(named: Bool) throws(SyntaxError) -> [Parameter] {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var parameters: [Parameter] = []
        skipSpaces()
        if !consume(")") {
            while true {
                parameters.append(try parseParameter(named: named))
                skipSpaces()
                if consume(")") { break }
                guard consume(",") else { throw expected("',' or ')'") }
                skipSpaces()
            }
        }
        try validate(parameters)
        return parameters
    }

    private mutating func parseParameter(named: Bool) throws(SyntaxError) -> Parameter {
        let first = try parseName(after: "'('")
        skipSpaces()
        var parameter = Parameter(label: first == "_" ? nil : first, name: first)
        if named {
            if let second = identifier() {
                pos += second.count
                skipSpaces()
                guard !Parser.keywords.contains(second) else { throw SyntaxError("'\(second)' is a keyword") }
                parameter.name = second
            } else if first == "_" {
                throw expected("a parameter name after '_'")
            }
        } else {
            parameter.label = nil
        }

        if consume(":") {
            parameter.type = try parseType()
            parameter.variadic = consume("...")
            skipSpaces()
        } else if named {
            throw expected("':' and a type for '\(parameter.name)'")
        }

        if named && peek() == "=" && peek(1) != "=" {
            pos += 1
            parameter.defaultValue = try parseExpression()
        }
        return parameter
    }

    private func validate(_ parameters: [Parameter]) throws(SyntaxError) {
        var seen: Set<String> = []
        for (index, parameter) in parameters.enumerated() {
            if parameter.name != "_" && !seen.insert(parameter.name).inserted {
                throw SyntaxError("duplicate parameter '\(parameter.name)'")
            }
            if parameter.variadic && index != parameters.count - 1 {
                throw SyntaxError("a variadic parameter must come last")
            }
            if parameter.variadic && parameter.defaultValue != nil {
                throw SyntaxError("a variadic parameter can't have a default value")
            }
        }
    }

    private mutating func parseType() throws(SyntaxError) -> TypeAnnotation {
        skipSpaces()
        if consume("[") {
            let element = try parseType()
            skipSpaces()
            guard consume("]") else { throw expected("']'") }
            return .list(element)
        }
        if consume("(") {
            skipSpaces()
            if !consume(")") {
                while true {
                    _ = try parseType()
                    skipSpaces()
                    if consume(")") { break }
                    guard consume(",") else { throw expected("',' or ')'") }
                }
            }
            skipSpaces()
            guard consume("->") else { throw expected("'->' in a function type") }
            _ = try parseType()
            return .function
        }
        guard let name = identifier() else { throw expected("a type") }
        pos += name.count
        let type: TypeAnnotation
        switch name {
        case "Int": type = .int
        case "Double": type = .double
        case "String": type = .string
        case "Bool": type = .bool
        case "Any", "Value": type = .any
        default: throw SyntaxError("unknown type '\(name)'")
        }
        if peek() == "?" { throw SyntaxError("optional types aren't supported yet") }
        return type
    }

    /// An identifier that isn't a keyword; `_` is allowed.
    private mutating func parseName(after context: String) throws(SyntaxError) -> String {
        guard let name = identifier() else { throw expected("a name after \(context)") }
        guard !Parser.keywords.contains(name) else { throw SyntaxError("'\(name)' is a keyword") }
        pos += name.count
        return name
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

    /// `$(…)`, `$?`, `$name`, or `$0` in a closure, positioned at the dollar
    /// sign; nil if the dollar is just a character.
    private mutating func parseDollar() throws(SyntaxError) -> Expr? {
        switch peek(1) {
        case "(":
            pos += 2
            // A substitution is its own little program: newlines separate
            // statements again, and it can't break or return out of its host.
            let saved = (bracketDepth, loopDepth, functionDepth)
            (bracketDepth, loopDepth, functionDepth) = (0, 0, 0)
            scopes.append([:])
            defer {
                (bracketDepth, loopDepth, functionDepth) = saved
                scopes.removeLast()
            }
            let program = try parseProgram(until: ")")
            pos += 1
            return .substitution(program)
        case "?":
            pos += 2
            return .status
        case let c? where Parser.isDigit(c):
            // Only special in a closure without named parameters; elsewhere,
            // as in "costs $5", it's just text.
            guard let arity = anonymousArity.last ?? nil else { return nil }
            pos += 1
            guard let index = Int(readDigits()) else { throw SyntaxError("closure parameter number is too large") }
            anonymousArity[anonymousArity.count - 1] = max(arity, index + 1)
            return .variable("$\(index)")
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
        var chained = false
        while true {
            skipSpaces()
            guard let op = Parser.precedence[level].first(where: { startsWith($0.rawValue) }) else {
                return lhs
            }
            if Parser.nonAssociativeLevels.contains(level) {
                if chained { throw SyntaxError("'\(op.rawValue)' can't be chained; use parentheses or '&&'") }
                chained = true
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
        // Postfix operators bind only without a space: `f(x)`, `xs[0]`.
        while true {
            if peek() == "[" {
                pos += 1
                bracketDepth += 1
                skipSpaces()
                let index = try parseExpression()
                skipSpaces()
                guard consume("]") else { throw expected("']'") }
                bracketDepth -= 1
                expr = .index(expr, index)
            } else if peek() == "(" {
                expr = .call(expr, try parseArguments())
            } else {
                return expr
            }
        }
    }

    private mutating func parseArguments() throws(SyntaxError) -> [Argument] {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var arguments: [Argument] = []
        skipSpaces()
        if consume(")") { return arguments }
        while true {
            var label: String?
            if let name = identifier(), peek(name.count) == ":" {
                label = name
                pos += name.count + 1
            }
            arguments.append(Argument(label: label, value: try parseExpression()))
            skipSpaces()
            if consume(")") { return arguments }
            guard consume(",") else { throw expected("',' or ')'") }
            skipSpaces()
        }
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
        case "{":
            pos += 1
            return .closure(try parseClosure())
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
        guard kind(of: name) != nil else {
            throw SyntaxError(peek() == "(" ? "no function named '\(name)'" : "no variable named '\(name)'")
        }
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

    private func kind(of name: String) -> NameKind? {
        for scope in scopes.reversed() {
            if let kind = scope[name] { return kind }
        }
        return nil
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
