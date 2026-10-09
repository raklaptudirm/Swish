import Foundation
import SwishKit

extension Parser {
    mutating func parseChain() throws(SyntaxError) -> Chain {
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

    mutating func parseUnit() throws(SyntaxError) -> Unit {
        skipSpaces()
        guard peek() != nil else { throw .incomplete("expected a command") }
        switch identifier() {
        case "if":
            return .ifStatement(try parseIf())
        case "for":
            return .forLoop(try parseFor())
        case "while":
            return .whileLoop(try parseWhile())
        case "switch":
            return .switchStatement(try parseSwitch())
        case "case", "default":
            throw SyntaxError("'\(identifier()!)' outside a switch")
        case "else":
            throw SyntaxError("'else' without a matching 'if'")
        case "in":
            throw SyntaxError("unexpected 'in'")
        case let word? where Parser.statementKeywords.contains(word):
            throw SyntaxError("'\(word)' must start a statement")
        default:
            break
        }
        // `try make` or `try! make`: a command whose failure throws.
        if dialect == .shell, identifier() == "try", let command = try parseThrowingCommand() {
            return .pipeline(command)
        }
        if dialect == .shell, case .command(let reason) = commandAhead() {
            var pipeline = try parsePipeline()
            if !pipeline.commands.isEmpty { pipeline.commands[0].notAnExpression = reason }
            return .pipeline(pipeline)
        }
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
            // In Swift, an operand that isn't an expression is just an error.
            guard dialect == .shell else { throw error }
            self = beforeExpression
            expr = try parseExpression(logical: false)
        }
        skipSpaces()
        guard peek() == "|", peek(1) != "|" else { return .expression(expr) }
        guard dialect == .shell else {
            throw SyntaxError("'|' pipes commands, which are shell syntax, and isn't an operator in Swift-only code")
        }
        pos += 1
        skipSpaces(newlines: true)
        return .pipeline(try parsePipeline(from: start, input: expr))
    }

    /// `try cmd …` or `try! cmd …`, or nil (having looked ahead) when what
    /// follows the `try` is an expression, as in `try? $(cmd)`.
    mutating func parseThrowingCommand() throws(SyntaxError) -> PipelineNode? {
        let before = (pos, spans.count)
        guard let kind = try parseTry() else { return nil }
        skipSpaces()
        // `try false` is the command: a Bool value can't throw.
        guard peek() != nil, commandAhead(boolIsCommand: kind != .optional).isCommand else {
            rewind(to: before)
            return nil
        }
        if kind == .optional {
            throw SyntaxError("try? needs a value; capture the command with try? $(…)")
        }
        tryDepth += 1
        defer { tryDepth -= 1 }
        var pipeline = try parsePipeline()
        pipeline.throwing = .some(kind)
        return pipeline
    }

    /// Whether the unit ahead is a command rather than an expression. The
    /// grammar decides, not the first character: it's an expression if one
    /// parses there and the unit ends after it. It's a command if
    ///
    /// - it starts with shell syntax: `^`, or `$name` (`$EDITOR notes`);
    /// - it starts with a function's name that isn't called or read there
    ///   (`greet Rak`, but `greet(…)` and `greet.self` are expressions);
    /// - no expression parses within its first word (`ls -la`, `git-lfs`,
    ///   `2to3`, `./run`, `~/bin/x`), the name and the word being one; or
    /// - a word follows the expression that parses (`"/opt/My App/run" x`).
    ///
    /// A name directly followed by `(` is a call either way. `boolIsCommand`:
    /// after `try` or `async`, where a lone `true` or `false` is the program,
    /// since a Bool value can't throw or run.
    mutating func commandAhead(boolIsCommand: Bool = false) -> UnitStart {
        let saved = self
        defer { self = saved }
        skipSpaces()
        guard let c = peek() else { return .expression }
        if c == "^" || (c == "$" && peek(1).map(Parser.isIdentifierStart) ?? false) { return .command(notAnExpression: nil) }
        if let word = identifier() {
            let after = peek(word.count)
            if boolIsCommand && (word == "true" || word == "false") && after.map(isWordBoundary) ?? true {
                return .command(notAnExpression: nil)
            }
            if after == "(" { return .expression }
            if kind(of: word) == .function { return after != "." && after != "[" ? .command(notAnExpression: nil) : .expression }
        }
        var wordEnd = pos
        while wordEnd < chars.count, !isWordBoundary(chars[wordEnd]) { wordEnd += 1 }
        // Why it isn't an expression is worth saying only of a word that
        // starts like one (`1...2...3`), not of one that starts like a name.
        let startsLikeName = Parser.isIdentifierStart(c)
        do {
            _ = try parseExpression(logical: true)
        } catch {
            // Unfinished input is an unfinished expression, not a command.
            guard !error.incomplete, pos <= wordEnd else { return .expression }
            return .command(notAnExpression: startsLikeName ? nil : error.description)
        }
        skipSpaces()
        guard endsUnit() else {
            var end = pos
            while end < chars.count, !isWordBoundary(chars[end]) { end += 1 }
            return .command(notAnExpression: startsLikeName ? nil : "unexpected '\(String(chars[pos..<end]))'")
        }
        return .expression
    }

    /// Whether the unit ends here: at the end of the input or the statement,
    /// before `|`, `&&` or `||`, a closing bracket, or a condition's body.
    func endsUnit() -> Bool {
        guard let c = peek() else { return true }
        if ";\n|&})".contains(c) { return true }
        if c == "{" && conditionDepth > 0 { return true }
        return guardCondition && identifier() == "else"
    }

    mutating func parseIf() throws(SyntaxError) -> IfStatement {
        keyword("if")
        skipSpaces()
        let (condition, bound) = try parseIfCondition()
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

    /// `guard condition else { … }`, whose bindings last to the block's end.
    mutating func parseGuard() throws(SyntaxError) -> Statement {
        keyword("guard")
        skipSpaces()
        guardCondition = true
        let parsed = Result { () throws(SyntaxError) in try parseIfCondition() }
        guardCondition = false
        let (condition, bound) = try parsed.get()
        skipSpaces()
        guard identifier() == "else" else { throw expected("'else' after guard's condition") }
        keyword("else")
        skipSpaces()
        let otherwise = try parseBlock()
        for (name, kind) in bound { scopes[scopes.count - 1][name] = kind }
        return .guardStatement(condition, otherwise: otherwise)
    }

    /// An `if` or `guard` condition: a Bool (or command), `let x = y`, or
    /// `case pattern = y`; with the names it binds.
    mutating func parseIfCondition() throws(SyntaxError) -> (IfStatement.Condition, [String: NameKind]) {
        let condition: IfStatement.Condition
        var bound: [String: NameKind] = [:]
        if identifier() == "case" {
            keyword("case")
            let pattern = try parsePattern()
            skipSpaces()
            guard peek() == "=" && peek(1) != "=" else { throw expected("'=' after the pattern") }
            pos += 1
            conditionDepth += 1
            defer { conditionDepth -= 1 }
            condition = .pattern(pattern, try parseExpression())
            for name in Parser.names(boundBy: pattern) { bound[name] = .variable }
        } else if let word = identifier(), word == "let" || word == "var" {
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
        return (condition, bound)
    }

    mutating func parseCondition() throws(SyntaxError) -> Chain {
        conditionDepth += 1
        defer { conditionDepth -= 1 }
        return try parseChain()
    }

    mutating func parseFor() throws(SyntaxError) -> ForLoop {
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

    mutating func parseWhile() throws(SyntaxError) -> WhileLoop {
        keyword("while")
        let condition = try parseCondition()
        skipSpaces()
        loopDepth += 1
        defer { loopDepth -= 1 }
        return WhileLoop(condition: condition, body: try parseBlock())
    }
}
