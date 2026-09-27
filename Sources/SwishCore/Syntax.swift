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
    /// `env.NAME = value` or `env["NAME"] = value`; nil unsets it.
    case setEnvironment(name: Expr, value: Expr)
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
    enum Condition: Equatable, Sendable {
        case chain(Chain)
        /// `if let name = value`: runs the body with `name` bound when the
        /// value isn't nil.
        case binding(name: String, mutable: Bool, value: Expr)
    }

    var condition: Condition
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
    var documentation: Documentation?
}

/// The `#` comment block directly above a `func`, for `--help`.
struct Documentation: Equatable, Sendable {
    var summary: String
    /// From `- Parameter name: description` lines.
    var parameters: [String: String]
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
    /// `@input`: receives pipeline input; per item, or the whole stream
    /// if its type is a list.
    var isInput = false
    /// `@flag("n")`: a short flag in command mode.
    var shortFlag: Character?
}

indirect enum TypeAnnotation: Equatable, Sendable, CustomStringConvertible {
    case any, bool, int, double, string
    case record, filesize, date
    case list(TypeAnnotation)
    case function
    /// `T?`: a T, or nil.
    case optional(TypeAnnotation)

    var description: String {
        switch self {
        case .any: "Any"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .record: "Record"
        case .filesize: "FileSize"
        case .date: "Date"
        case .list(let element): "[\(element)]"
        case .function: "function"
        case .optional(let wrapped): "\(wrapped)?"
        }
    }
}

struct PipelineNode: Equatable, Sendable {
    var commands: [CommandNode]
    /// The pipeline as typed, for job messages like "Stopped".
    var source: String
    /// A value feeding the pipeline, as in `[3, 1, 2] | sort`.
    var input: Expr?
}

struct CommandNode: Equatable, Sendable {
    var words: [Word]
    /// `^name`: skip functions and builtins, and run the external program.
    var external = false
    /// In the order written, which matters: `> out e>o` sends both to
    /// `out`, `e>o > out` only standard output.
    var redirects: [Redirect] = []
    /// `EDITOR=vim git commit`: environment variables for this command only.
    var environment: [EnvironmentAssignment] = []
}

struct EnvironmentAssignment: Equatable, Sendable {
    var name: String
    var value: [StringPart]
}

/// `> file`, `e>> file`, `< file`, `e>o` and the like.
struct Redirect: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case file([StringPart], Mode)
        /// Another of the command's descriptors, as in `e>o`.
        case descriptor(Int32)
    }

    enum Mode: Equatable, Sendable {
        case read, write, append
    }

    var fd: Int32
    var target: Target
}

enum Word: Equatable, Sendable {
    case text([StringPart])
    /// `where { $0.size > 1.mb }`: a closure passed as an argument.
    case closure(ClosureLiteral)
}

enum StringPart: Equatable, Sendable {
    case literal(String)
    case expression(Expr)
    /// Unquoted text with a wildcard, like `*.swift`; only unquoted
    /// wildcards expand to file names.
    case glob(String)
}

struct RecordEntry: Equatable, Sendable {
    var key: Expr
    var value: Expr
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
    /// `$(…)`: throws if the command fails, like a call to a throwing
    /// function whose `try` is implicit.
    case substitution(Program)
    /// `try? expr` or `try! expr`; a plain `try` leaves no trace.
    case attempt(Expr, TryKind)
    case list([Expr])
    case record([RecordEntry])
    case closure(ClosureLiteral)
    case call(Expr, [Argument])
    /// `value.name`: a record field, or a member like `count`.
    case member(Expr, String)
    case unary(UnaryOperator, Expr)
    case binary(BinaryOperator, Expr, Expr)
    case index(Expr, Expr)
}

enum TryKind: Equatable, Sendable {
    /// `try?`: nil instead of a runtime error.
    case optional
    /// `try!`: a runtime error stops the whole script, not just the line.
    case forced
}

enum UnaryOperator: String, Sendable {
    case not = "!"
    case negate = "-"
}

enum BinaryOperator: String, Sendable {
    case or = "||", and = "&&"
    case coalesce = "??"
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
/// Mode is decided per unit, from its first token (see `startsExpression`).
/// Deciding it needs to know which names exist and what they are, so the
/// parser tracks declarations lexically, seeded with the shell's globals.
struct Parser {
    private static let keywords: Set = [
        "let", "var", "if", "else", "true", "false", "nil",
        "for", "in", "while", "func", "return", "break", "continue", "try",
    ]
    private static let statementKeywords: Set = ["let", "var", "func", "return", "break", "continue"]
    private static let precedence: [[BinaryOperator]] = [
        [.or],
        [.and],
        // Two-character operators first, so `<=` isn't read as `<`.
        [.equal, .notEqual, .lessEqual, .greaterEqual, .less, .greater],
        [.coalesce],
        [.closedRange, .halfOpenRange],
        [.add, .subtract],
        [.multiply, .divide, .remainder],
    ]
    private static let comparisonLevel = 2
    static let fileSizeUnits: [String: Int64] = [
        "b": 1, "kb": 1_000, "mb": 1_000_000, "gb": 1_000_000_000, "tb": 1_000_000_000_000,
        "kib": 1 << 10, "mib": 1 << 20, "gib": 1 << 30, "tib": 1 << 40,
    ]
    /// Levels whose operators can't be chained, like `a < b < c`.
    private static let nonAssociativeLevels: Set = [2, 4]

    private let chars: [Character]
    private var pos = 0
    private var scopes: [[String: NameKind]]
    /// Inside (), [] and \( ), newlines don't end an expression.
    private var bracketDepth = 0
    private var loopDepth = 0
    private var functionDepth = 0
    /// Inside an `if`/`while` condition, `{` after a command starts the body
    /// rather than a closure argument.
    private var conditionDepth = 0
    /// One entry per enclosing function or closure: how many `$n`
    /// parameters a closure without named parameters uses, or nil if its
    /// parameters are named.
    private var anonymousArity: [Int?] = []

    /// Highlight spans, in the order recorded; inner spans (like an
    /// interpolation inside a string) are shorter than what contains them.
    /// Input that doesn't parse yet, as while typing, still gets the spans
    /// found before the problem.
    private(set) var spans: [Span] = []

    static func parse(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program {
        var parser = Parser(source, bound: bound)
        return try parser.parseProgram(until: nil)
    }

    static func highlight(_ source: String, bound: [String: NameKind]) -> [Span] {
        var parser = Parser(source, bound: bound)
        _ = try? parser.parseProgram(until: nil)
        return parser.spans
    }

    private mutating func mark(_ kind: SpanKind, from start: Int, to end: Int? = nil) {
        let end = min(end ?? pos, chars.count)
        if start < end { spans.append(Span(range: start..<end, kind: kind)) }
    }

    /// Backs up after looking ahead, dropping spans recorded on the way.
    private mutating func rewind(to state: (position: Int, spans: Int)) {
        pos = state.position
        spans.removeSubrange(state.spans...)
    }

    /// Consumes a keyword known to be at the current position.
    private mutating func keyword(_ word: String) {
        mark(.keyword, from: pos, to: pos + word.count)
        pos += word.count
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
            keyword("return")
            skipSpaces()
            guard let c = peek(), c != ";" && c != "\n" && c != "}" else { return .returnStatement(nil) }
            return .returnStatement(try parseExpression())
        case let word? where word == "break" || word == "continue":
            guard loopDepth > 0 else { throw SyntaxError("'\(word)' outside a loop") }
            keyword(word)
            return word == "break" ? .breakStatement : .continueStatement
        default:
            break
        }

        if identifier() == "env", let assignment = try parseEnvironmentAssignment() {
            return assignment
        }

        if let name = identifier(), kind(of: name) == .variable {
            let start = pos
            let spansBefore = spans.count
            pos += name.count
            skipSpaces()
            if peek() == "=" && peek(1) != "=" {
                mark(.variable, from: start, to: start + name.count)
                pos += 1
                return .assign(name: name, value: try parseExpression())
            }
            rewind(to: (start, spansBefore))
        }

        return .chain(try parseChain())
    }

    /// `env.NAME = value` or `env[name] = value`, or nil (having looked
    /// ahead) if this is some other statement starting with `env`.
    private mutating func parseEnvironmentAssignment() throws(SyntaxError) -> Statement? {
        let start = (pos, spans.count)
        mark(.variable, from: pos, to: pos + 3)
        pos += 3
        let name: Expr
        if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
            pos += 1
            let key = identifier()!
            pos += key.count
            name = .literal(.string(key))
        } else if consume("[") {
            bracketDepth += 1
            skipSpaces()
            name = try parseExpression()
            skipSpaces()
            bracketDepth -= 1
            guard consume("]") else { throw expected("']'") }
        } else {
            rewind(to: start)
            return nil
        }
        skipSpaces()
        guard peek() == "=" && peek(1) != "=" else {
            rewind(to: start)
            return nil
        }
        pos += 1
        return .setEnvironment(name: name, value: try parseExpression())
    }

    private mutating func parseDeclaration() throws(SyntaxError) -> Statement {
        let keyword = identifier()!
        self.keyword(keyword)
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'\(keyword)'")
        mark(.variable, from: nameStart)
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
            let start = pos
            // `a < 1 || b > 2` is one expression, with Swift's precedence, so
            // `{ $0.a < 1 || $0.b > 2 }` returns it. Only when an operand
            // isn't an expression, as in `x > 1 && echo big`, do `&&`/`||`
            // chain units by exit status instead.
            let beforeExpression = self
            var expr: Expr
            do {
                expr = try parseExpression(logical: true)
            } catch {
                self = beforeExpression
                expr = try parseExpression(logical: false)
            }
            skipSpaces()
            guard peek() == "|", peek(1) != "|" else { return .expression(expr) }
            pos += 1
            skipSpaces(newlines: true)
            return .pipeline(try parsePipeline(from: start, input: expr))
        }
        return .pipeline(try parsePipeline())
    }

    /// Whether a unit starting at `c` is an expression rather than a command:
    /// a literal, a bracket, `!` or `-`, a variable, or a call.
    ///
    /// A function name without `(` starts a command (`greet Rak --loud`).
    /// `$name` starts a command, as in `$EDITOR notes.txt`, but `$(…)` an
    /// expression, as in `$(cmd)? ?? "default"`, and so does a closure's `$0`;
    /// `^` always starts a command.
    private func startsExpression(_ c: Character) -> Bool {
        if Parser.isDigit(c) || "\"'([!-".contains(c) { return true }
        if c == "$" && peek(1) == "(" { return true }
        if c == "$", let next = peek(1), Parser.isDigit(next), anonymousArity.last ?? nil != nil { return true }
        guard let word = identifier() else { return false }
        if ["true", "false", "nil", "try"].contains(word) { return true }
        return kind(of: word) == .variable || peek(word.count) == "("
    }

    private mutating func parseIf() throws(SyntaxError) -> IfStatement {
        keyword("if")
        skipSpaces()
        let condition: IfStatement.Condition
        var bound: [String: NameKind] = [:]
        if let word = identifier(), word == "let" || word == "var" {
            keyword(word)
            skipSpaces()
            let nameStart = pos
            let name = try parseName(after: "'\(word)'")
            mark(.variable, from: nameStart)
            skipSpaces()
            guard peek() == "=" && peek(1) != "=" else { throw expected("'=' after '\(name)'") }
            pos += 1
            conditionDepth += 1
            defer { conditionDepth -= 1 }
            condition = .binding(name: name, mutable: word == "var", value: try parseExpression())
            bound[name] = .variable
        } else {
            condition = .chain(try parseCondition())
        }
        skipSpaces()
        let then = try parseBlock(declaring: bound)

        let afterBlock = (pos, spans.count)
        skipSpaces(newlines: true)
        guard identifier() == "else" else {
            rewind(to: afterBlock)
            return IfStatement(condition: condition, then: then)
        }
        keyword("else")
        skipSpaces()
        if identifier() == "if" {
            let elseIf = Statement.chain(Chain(first: .ifStatement(try parseIf())))
            return IfStatement(condition: condition, then: then, otherwise: Program(statements: [elseIf]))
        }
        return IfStatement(condition: condition, then: then, otherwise: try parseBlock())
    }

    private mutating func parseCondition() throws(SyntaxError) -> Chain {
        conditionDepth += 1
        defer { conditionDepth -= 1 }
        return try parseChain()
    }

    private mutating func parseFor() throws(SyntaxError) -> ForLoop {
        keyword("for")
        skipSpaces()
        let variableStart = pos
        let variable = try parseName(after: "'for'")
        mark(.variable, from: variableStart)
        skipSpaces()
        guard identifier() == "in" else { throw expected("'in'") }
        keyword("in")
        conditionDepth += 1
        let sequence = try parseExpression()
        conditionDepth -= 1
        skipSpaces()
        loopDepth += 1
        defer { loopDepth -= 1 }
        let body = try parseBlock(declaring: variable == "_" ? [:] : [variable: .variable])
        return ForLoop(variable: variable, sequence: sequence, body: body)
    }

    private mutating func parseWhile() throws(SyntaxError) -> WhileLoop {
        keyword("while")
        let condition = try parseCondition()
        skipSpaces()
        loopDepth += 1
        defer { loopDepth -= 1 }
        return WhileLoop(condition: condition, body: try parseBlock())
    }

    private mutating func parseBlock(declaring names: [String: NameKind] = [:]) throws(SyntaxError) -> Program {
        guard peek() == "{" else { throw expected("'{'") }
        pos += 1
        let savedCondition = conditionDepth
        conditionDepth = 0
        scopes.append(names)
        defer {
            scopes.removeLast()
            conditionDepth = savedCondition
        }
        let body = try parseProgram(until: "}")
        pos += 1 // parseProgram only returns at the closing brace.
        return body
    }

    // MARK: Functions and closures

    private mutating func parseFunction() throws(SyntaxError) -> FunctionDecl {
        let documentation = documentation(before: pos)
        keyword("func")
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'func'")
        mark(.command, from: nameStart)
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
        return FunctionDecl(
            name: name, parameters: parameters, returnType: returnType, body: body, documentation: documentation
        )
    }

    /// The `///` comment lines directly above the line starting at `index`.
    private func documentation(before index: Int) -> Documentation? {
        var lineStart = index
        while lineStart > 0 && (chars[lineStart - 1] == " " || chars[lineStart - 1] == "\t") { lineStart -= 1 }
        guard lineStart > 0 && chars[lineStart - 1] == "\n" else { return nil }

        var lines: [String] = []
        var end = lineStart - 1 // The newline ending the line above.
        while end >= 0 {
            var start = end
            while start > 0 && chars[start - 1] != "\n" { start -= 1 }
            let line = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("///") else { break }
            var text = line.dropFirst(3)
            if text.first == " " { text = text.dropFirst() }
            lines.insert(String(text), at: 0)
            end = start - 1
        }
        guard !lines.isEmpty else { return nil }

        var summary: [String] = []
        var parameters: [String: String] = [:]
        for line in lines {
            if line.hasPrefix("- Parameter "), let colon = line.firstIndex(of: ":") {
                let name = line[line.index(line.startIndex, offsetBy: 12)..<colon].trimmingCharacters(in: .whitespaces)
                parameters[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                summary.append(line)
            }
        }
        return Documentation(
            summary: summary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            parameters: parameters
        )
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
        keyword("in")
        return (parameters, returnType)
    }

    /// Statements up to the closing brace, whose opening brace is already
    /// consumed, in a new function scope. Returns the `$n` arity for
    /// anonymous closures.
    private mutating func parseFunctionBody(
        parameters: [Parameter], anonymous: Bool
    ) throws(SyntaxError) -> (Program, Int) {
        let saved = (loopDepth, bracketDepth, conditionDepth)
        loopDepth = 0
        bracketDepth = 0
        conditionDepth = 0
        functionDepth += 1
        var names: [String: NameKind] = [:]
        for parameter in parameters where parameter.name != "_" {
            names[parameter.name] = .variable
        }
        scopes.append(names)
        anonymousArity.append(anonymous ? 0 : nil)
        defer {
            (loopDepth, bracketDepth, conditionDepth) = saved
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
        var isInput = false
        var shortFlag: Character?
        while named && peek() == "@" {
            let attributeStart = pos
            pos += 1
            guard let attribute = identifier() else { throw expected("an attribute name after '@'") }
            pos += attribute.count
            mark(.keyword, from: attributeStart)
            switch attribute {
            case "input":
                isInput = true
            case "flag":
                skipSpaces()
                guard consume("(") else { throw expected("'(' after '@flag'") }
                skipSpaces()
                guard peek() == "\"", let letter = peek(1), letter.isLetter || Parser.isDigit(letter), peek(2) == "\"" else {
                    throw SyntaxError("@flag needs a single letter or digit, like @flag(\"n\")")
                }
                mark(.string, from: pos, to: pos + 3)
                pos += 3
                skipSpaces()
                guard consume(")") else { throw expected("')'") }
                shortFlag = letter
            default:
                throw SyntaxError("unknown attribute '@\(attribute)'")
            }
            skipSpaces()
        }

        let first = try parseName(after: "'('")
        skipSpaces()
        var parameter = Parameter(label: first == "_" ? nil : first, name: first, isInput: isInput, shortFlag: shortFlag)
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
        var shortFlags: Set<Character> = []
        if parameters.filter(\.isInput).count > 1 {
            throw SyntaxError("only one parameter can be @input")
        }
        for (index, parameter) in parameters.enumerated() {
            if parameter.isInput && parameter.variadic {
                throw SyntaxError("an @input parameter can't be variadic; use a list type for the whole stream")
            }
            if let flag = parameter.shortFlag {
                guard parameter.label != nil else { throw SyntaxError("@flag needs a labeled parameter") }
                guard shortFlags.insert(flag).inserted else { throw SyntaxError("duplicate short flag -\(flag)") }
            }
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
        let type = try parseNonOptionalType()
        return consume("?") ? .optional(type) : type
    }

    private mutating func parseNonOptionalType() throws(SyntaxError) -> TypeAnnotation {
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
        mark(.type, from: pos, to: pos + name.count)
        pos += name.count
        let type: TypeAnnotation
        switch name {
        case "Int": type = .int
        case "Double": type = .double
        case "String": type = .string
        case "Bool": type = .bool
        case "Record": type = .record
        case "FileSize": type = .filesize
        case "Date": type = .date
        case "Any", "Value": type = .any
        default: throw SyntaxError("unknown type '\(name)'")
        }
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

    private mutating func parsePipeline(from start: Int? = nil, input: Expr? = nil) throws(SyntaxError) -> PipelineNode {
        let start = start ?? pos
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
        return PipelineNode(commands: commands, source: source, input: input)
    }

    private mutating func parseCommand() throws(SyntaxError) -> CommandNode {
        skipSpaces()
        let nameStart = pos
        // `foreign ls` (or `^ls`): the program, never a function or builtin.
        var external = consume("^")
        // Where the command name's highlight starts: at a `^` touching it.
        let caretStart: Int? = external ? nameStart : nil
        if !external, identifier() == "foreign", peek(7) == " " || peek(7) == "\t" {
            keyword("foreign")
            skipSpaces()
            external = true
        }
        var words: [Word] = []
        var redirects: [Redirect] = []
        var environment: [EnvironmentAssignment] = []
        while true {
            skipSpaces()
            guard let c = peek(), !endsCommand(c) else { break }
            if let redirect = try parseRedirect() {
                redirects += redirect
                continue
            }
            if c == "{" && peek(1) != "}" {
                pos += 1
                words.append(.closure(try parseClosure()))
                continue
            }
            if c == "(" {
                throw SyntaxError("unexpected '(' in a command; quote it, or use \\(…) to interpolate an expression")
            }
            if c == "&" {
                throw SyntaxError("'&' isn't Swish; background jobs will be `async command`")
            }
            // `NAME=value` before the command sets it for the command.
            if words.isEmpty, let name = identifier(), peek(name.count) == "=", peek(name.count + 1) != "=" {
                mark(.variable, from: pos, to: pos + name.count)
                pos += name.count + 1
                let value = peek().map(isWordBoundary) ?? true ? [.literal("")] : try parseWord()
                environment.append(EnvironmentAssignment(name: name, value: value))
                continue
            }
            let wordStart = pos
            let word = try parseWord()
            if words.isEmpty {
                mark(.command, from: redirects.isEmpty && environment.isEmpty ? caretStart ?? wordStart : wordStart)
            } else if chars[wordStart] == "-" {
                mark(.flag, from: wordStart)
            }
            words.append(.text(word))
        }
        guard !words.isEmpty else {
            if let assignment = environment.first {
                throw SyntaxError("\(assignment.name)=… sets a variable for one command; use env.\(assignment.name) = … to set it for the session")
            }
            if let c = peek() { throw unexpected(c) }
            throw .incomplete("expected a command")
        }
        return CommandNode(words: words, external: external, redirects: redirects, environment: environment)
    }

    /// A redirect at the current position, or nil if there isn't one:
    /// `> file`, `>> file` and `< file` for standard output and input;
    /// `e>` and `e>>` for standard error; `o+e>` and `o+e>>` for both; `e>o`
    /// sends standard error wherever standard output goes, and `o>e` the
    /// other way. POSIX forms like `2>&1` are an error naming the new one.
    private mutating func parseRedirect() throws(SyntaxError) -> [Redirect]? {
        let start = pos
        try rejectPosixRedirect()

        func touchesBoundary(after count: Int) -> Bool {
            peek(count).map(isWordBoundary) ?? true
        }
        if startsWith("e>o") && touchesBoundary(after: 3) {
            pos += 3
            mark(.punctuation, from: start)
            return [Redirect(fd: 2, target: .descriptor(1))]
        }
        if startsWith("o>e") && touchesBoundary(after: 3) {
            pos += 3
            mark(.punctuation, from: start)
            return [Redirect(fd: 1, target: .descriptor(2))]
        }

        let fds: [Int32]
        if consume("o+e>") {
            fds = [1, 2]
        } else if consume("e>") {
            fds = [2]
        } else if consume(">") {
            fds = [1]
        } else if consume("<") {
            fds = [0]
        } else {
            return nil
        }
        let append = fds != [0] && consume(">")
        mark(.punctuation, from: start)

        skipSpaces()
        guard let c = peek(), !isWordBoundary(c) else {
            if peek() == nil { throw .incomplete("expected a file to redirect to") }
            throw expected("a file to redirect to")
        }
        let file = try parseWord()
        let mode: Redirect.Mode = fds == [0] ? .read : append ? .append : .write
        if fds == [1, 2] {
            return [Redirect(fd: 1, target: .file(file, mode)), Redirect(fd: 2, target: .descriptor(1))]
        }
        return [Redirect(fd: fds[0], target: .file(file, mode))]
    }

    /// POSIX redirects, which would otherwise read as a word and a redirect,
    /// with the Swish spelling in the error.
    private func rejectPosixRedirect() throws(SyntaxError) {
        var digits = ""
        while let c = peek(digits.count), Parser.isDigit(c) { digits.append(c) }
        let rest = String(chars[(pos + digits.count)...].prefix(4))
        let swish: String?
        switch (digits, rest) {
        case (_, _) where startsWith("&>>"): swish = "o+e>>"
        case (_, _) where startsWith("&>"): swish = "o+e>"
        case ("", _) where rest.hasPrefix(">&2"): swish = "o>e"
        case ("2", _) where rest.hasPrefix(">&1"): swish = "e>o"
        case ("2", _) where rest.hasPrefix(">>"): swish = "e>>"
        case ("2", _) where rest.hasPrefix(">"): swish = "e>"
        case ("1", _) where rest.hasPrefix(">"): swish = rest.hasPrefix(">>") ? ">>" : ">"
        case ("0", _) where rest.hasPrefix("<"): swish = "<"
        case let (number, _) where !number.isEmpty && (rest.hasPrefix(">") || rest.hasPrefix("<")):
            throw SyntaxError("numbered descriptors like \(number)\(rest.prefix(1)) aren't part of Swish; redirect with >, e>, e>o, o>e or o+e>")
        default: swish = nil
        }
        if let swish {
            throw SyntaxError("that's a POSIX redirect; in Swish it's \(swish)")
        }
    }

    private func endsCommand(_ c: Character) -> Bool {
        switch c {
        case "|", ";", "\n", ")", "}": true
        case "&": peek(1) == "&"
        case "{": peek(1) != "}" && conditionDepth > 0
        default: false
        }
    }

    private func isWordBoundary(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || "|;&(){}<>".contains(c)
    }

    private mutating func parseWord() throws(SyntaxError) -> [StringPart] {
        var parts: [StringPart] = []
        var literal = ""
        // Whether the unquoted text in `literal` has a wildcard in it.
        var wildcard = false
        func flush() {
            if !literal.isEmpty { parts.append(wildcard ? .glob(literal) : .literal(literal)) }
            literal = ""
            wildcard = false
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
                parts += try parseInterpolatedString(dollar: true)
            case "\\":
                guard let next = peek(1) else { throw .incomplete("expected a character after '\\'") }
                if next == "(" {
                    flush()
                    parts.append(.expression(try parseInterpolation()))
                } else if next == "\n" {
                    pos += 2
                } else if "*[".contains(next) {
                    // An escaped wildcard is literal, even next to real ones.
                    flush()
                    parts.append(.literal(String(next)))
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
                if "*[".contains(c) { wildcard = true }
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
            mark(.string, from: pos, to: chars.count)
            throw .incomplete("unterminated string")
        }
        let text = String(chars[(pos + 1)..<end])
        mark(.string, from: pos, to: end + 1)
        pos = end + 1
        return text
    }

    /// A double-quoted string: Swift escapes and `\(…)`, and in commands
    /// (`dollar`) also `$name` and `$(…)`. In expressions it's pure Swift,
    /// so `"costs $5"` and `"$HOME"` are literal there.
    private mutating func parseInterpolatedString(dollar: Bool) throws(SyntaxError) -> [StringPart] {
        let start = pos
        pos += 1
        var parts: [StringPart] = []
        var literal = ""
        while true {
            guard let c = peek() else {
                mark(.string, from: start, to: chars.count)
                throw .incomplete("unterminated string")
            }
            switch c {
            case "\"":
                pos += 1
                mark(.string, from: start)
                if !literal.isEmpty || parts.isEmpty { parts.append(.literal(literal)) }
                return parts
            case "\\":
                guard let next = peek(1) else {
                    mark(.string, from: start, to: chars.count)
                    throw .incomplete("unterminated string")
                }
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
            case "$" where dollar:
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
        mark(.punctuation, from: pos, to: pos + 2)
        pos += 2
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        skipSpaces()
        let expr = try parseExpression()
        skipSpaces()
        guard consume(")") else { throw expected("')'") }
        mark(.punctuation, from: pos - 1)
        return expr
    }

    /// `$(…)`, `$?`, `$name`, or `$0` in a closure, positioned at the dollar
    /// sign; nil if the dollar is just a character.
    private mutating func parseDollar() throws(SyntaxError) -> Expr? {
        switch peek(1) {
        case "(":
            mark(.punctuation, from: pos, to: pos + 2)
            pos += 2
            // A substitution is its own little program: newlines separate
            // statements again, and it can't break or return out of its host.
            let saved = (bracketDepth, loopDepth, functionDepth, conditionDepth)
            (bracketDepth, loopDepth, functionDepth, conditionDepth) = (0, 0, 0, 0)
            scopes.append([:])
            defer {
                (bracketDepth, loopDepth, functionDepth, conditionDepth) = saved
                scopes.removeLast()
            }
            let program = try parseProgram(until: ")")
            mark(.punctuation, from: pos, to: pos + 1)
            pos += 1
            return .substitution(program)
        case "?":
            throw SyntaxError("$? is status.code in Swish")
        case let c? where Parser.isDigit(c):
            // Only special in a closure without named parameters; elsewhere,
            // as in "costs $5", it's just text.
            guard let arity = anonymousArity.last ?? nil else { return nil }
            let start = pos
            pos += 1
            guard let index = Int(readDigits()) else { throw SyntaxError("closure parameter number is too large") }
            mark(.variable, from: start)
            anonymousArity[anonymousArity.count - 1] = max(arity, index + 1)
            return .variable("$\(index)")
        case let c? where Parser.isIdentifierStart(c):
            let start = pos
            pos += 1
            let name = identifier()!
            pos += name.count
            mark(.variable, from: start)
            return .dollar(name)
        default:
            return nil
        }
    }

    // MARK: Expression mode

    /// `logical` is false for an expression that is a whole unit, so that
    /// `&&` and `||` are left to join it with commands in a chain.
    /// `try`, `try?` and `try!` cover everything to their right, as in
    /// Swift: `(try? $(cmd)) ?? "default"` needs its parentheses.
    private mutating func parseExpression(logical: Bool = true) throws(SyntaxError) -> Expr {
        skipSpaces()
        if let kind = try parseTry() {
            let operand = try parseExpression(logical: logical)
            return kind.map { .attempt(operand, $0) } ?? operand
        }
        return try parseBinary(level: logical ? 0 : Parser.comparisonLevel)
    }

    /// `try` (.some(nil)), `try?` or `try!` at the current position; nil if none.
    private mutating func parseTry() throws(SyntaxError) -> TryKind?? {
        guard identifier() == "try" else { return nil }
        let start = pos
        pos += "try".count
        var kind: TryKind?
        if consume("?") {
            kind = .optional
        } else if consume("!") {
            kind = .forced
        }
        mark(.keyword, from: start)
        return .some(kind)
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
        // After an operator, as in `x + try? f()`, it covers the rest.
        if identifier() == "try" {
            return try parseExpression()
        }
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
                var arguments = try parseArguments()
                // A trailing closure, as in `with(env: e) { … }`; not where
                // `{` starts a body, as after `if` or `for … in`.
                let beforeClosure = (pos, spans.count)
                skipSpaces()
                if peek() == "{" && conditionDepth == 0 {
                    pos += 1
                    arguments.append(Argument(label: nil, value: .closure(try parseClosure())))
                } else {
                    rewind(to: beforeClosure)
                }
                expr = .call(expr, arguments)
            } else if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
                pos += 1
                let name = identifier()!
                pos += name.count
                expr = .member(expr, name)
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
            let parts = try parseInterpolatedString(dollar: false)
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
            guard let expr = try parseDollar() else { throw unexpected(c) }
            return expr
        default:
            break
        }

        guard let name = identifier() else { throw unexpected(c) }
        let nameStart = pos
        pos += name.count
        switch name {
        case "true", "false", "nil": mark(.constant, from: nameStart)
        default: mark(.variable, from: nameStart)
        }
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

    /// `[1, 2]`, or a record like `["name": "x", "size": 1.kb]` or `[:]`.
    private mutating func parseList() throws(SyntaxError) -> Expr {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        skipSpaces()
        if consume(":") {
            skipSpaces()
            guard consume("]") else { throw expected("']'") }
            return .record([])
        }
        var elements: [Expr] = []
        var entries: [RecordEntry] = []
        // Decided by the first element: a colon after it makes a record.
        var isRecord: Bool?
        while peek() != "]" {
            let element = try parseExpression()
            skipSpaces()
            if isRecord == nil {
                isRecord = consume(":")
            } else if isRecord == true {
                guard consume(":") else { throw expected("':' in a record literal") }
            }
            if isRecord == true {
                entries.append(RecordEntry(key: element, value: try parseExpression()))
            } else {
                elements.append(element)
            }
            skipSpaces()
            guard consume(",") else { break }
            skipSpaces()
        }
        guard consume("]") else { throw expected("']'") }
        return isRecord == true ? .record(entries) : .list(elements)
    }

    private mutating func parseNumber() throws(SyntaxError) -> Expr {
        let start = pos
        defer { mark(.number, from: start) }
        var text = readDigits()
        var isDouble = false
        if peek() == ".", let next = peek(1), Parser.isDigit(next) {
            isDouble = true
            pos += 1
            text += "." + readDigits()
        }
        if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
            pos += 1
            let unit = identifier()!
            guard let multiplier = Parser.fileSizeUnits[unit] else {
                throw SyntaxError("unknown unit '\(unit)'; file sizes use b, kb, mb, gb, tb, or kib, mib, gib, tib")
            }
            pos += unit.count
            let bytes = Double(text)! * Double(multiplier)
            guard bytes.magnitude < Double(Int64.max) else { throw SyntaxError("file size \(text).\(unit) is too large") }
            return .literal(.filesize(Int64(bytes)))
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
            } else if (c == "/" && peek(1) == "/") || (c == "#" && pos == 0 && peek(1) == "!") {
                // `//` and `///` comments, as in Swift; `#!` only as a shebang.
                let start = pos
                while let d = peek(), d != "\n" { pos += 1 }
                mark(.comment, from: start)
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
