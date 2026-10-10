@_spi(Shell) import Swiit
import Foundation
import SwishKit

/// The shell's syntax, plugged into the parser: commands, pipelines, redirects,
/// `$(…)`, `$name`, `async …`, `env.NAME = value` and `import Name from path`.
/// Everything here is the shell's; the parser in Parser*.swift is Swift's and
/// calls this where its grammar has no meaning for what is there.
struct ShellSyntax: SyntaxPlugin {
    func chain(_ parser: inout Parser, condition: Bool) throws(SyntaxError) -> Expr? {
        try parser.parseCommandChain(condition: condition).map(Expr.commands)
    }

    func continuing(_ expression: Expr, from start: Int, _ parser: inout Parser) throws(SyntaxError) -> Expr? {
        guard parser.peek() == "|", parser.peek(1) != "|" else { return nil }
        parser.pos += 1
        parser.skipSpaces(newlines: true)
        return .commands(CommandChainExpr(first: .command(try parser.parsePipeline(from: start, input: expression))))
    }

    func expression(_ parser: inout Parser) throws(SyntaxError) -> Expr? {
        if parser.identifier() == "async" { return try parser.parseAsync() }
        guard parser.peek() == "$" else { return nil }
        return try parser.parseShellDollar()
    }

    func statement(_ parser: inout Parser) throws(SyntaxError) -> Statement? {
        switch parser.identifier() {
        case "import": return try parser.parseImport()
        default: return nil
        }
    }
}

extension Parser {
    /// Commands joined by `&&` and `||`, with Swift between them or not, as a
    /// statement or a condition; nil (having looked ahead) when there is no
    /// command in it, which is Swift's. `a < 1 || b > 2` is one expression,
    /// with Swift's precedence, so `{ $0.a < 1 || $0.b > 2 }` returns it; only
    /// when an operand isn't an expression, as in `x > 1 && echo big`, do
    /// `&&` and `||` join operands by exit status instead.
    mutating func parseCommandChain(condition: Bool) throws(SyntaxError) -> CommandChainExpr? {
        let start = self
        var operands: [CommandChainExpr.Operand] = []
        var joins: [Bool] = []
        var sawCommand = false
        do {
            operands.append(try parseChainOperand(&sawCommand))
            while true {
                skipSpaces()
                if consume("&&") {
                    joins.append(true)
                } else if consume("||") {
                    joins.append(false)
                } else {
                    break
                }
                skipSpaces(newlines: true)
                operands.append(try parseChainOperand(&sawCommand))
            }
        } catch {
            // What doesn't read before a command is read as Swift, which says
            // what's wrong with it; input cut short asks for more either way.
            guard sawCommand || error.incomplete else {
                self = start
                return nil
            }
            throw error
        }
        var chain = CommandChainExpr(first: operands[0], isCondition: condition)
        chain.links = zip(joins, operands.dropFirst()).map { CommandChainExpr.Link(isAnd: $0, operand: $1) }
        // A command makes it the shell's; so does a condition that asks
        // whether a `try?` caught an error (`if try? build()`), which a Bool
        // doesn't say.
        let isShells = chain.operands.contains { operand in
            switch operand {
            case .command: true
            case .expression(.attempt(_, .optional)): condition
            case .expression: false
            }
        }
        guard isShells else {
            self = start
            return nil
        }
        return chain
    }

    /// A command, or the Swift expression between commands.
    /// `sawCommand`: set once it is reading a command, whose errors are the shell's.
    private mutating func parseChainOperand(_ sawCommand: inout Bool) throws(SyntaxError) -> CommandChainExpr.Operand {
        skipSpaces()
        guard peek() != nil else { throw .incomplete("expected a command") }
        if let word = identifier(), Parser.statementKeywords.union(["if", "for", "while", "switch", "else", "case", "default", "in"]).contains(word) {
            throw SyntaxError("'\(word)' must start a statement")
        }
        // `try make` or `try! make`: a command whose failure throws.
        if identifier() == "try" {
            let before = sawCommand
            sawCommand = true
            if let command = try parseThrowingCommand() { return .command(command) }
            sawCommand = before
        }
        if case .command(let reason) = commandAhead() {
            sawCommand = true
            var pipeline = try parsePipeline()
            if !pipeline.commands.isEmpty { pipeline.commands[0].notAnExpression = reason }
            return .command(pipeline)
        }
        let start = pos
        let beforeExpression = self
        var expr: Expr
        do {
            expr = try parseExpression(logical: true)
        } catch {
            self = beforeExpression
            expr = try parseExpression(logical: false)
        }
        skipSpaces()
        // `xs | sorted`: a value fed to commands.
        guard peek() == "|", peek(1) != "|" else { return .expression(expr) }
        pos += 1
        skipSpaces(newlines: true)
        sawCommand = true
        return .command(try parsePipeline(from: start, input: expr))
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

    /// `async cmd …` or `async $(cmd …)`: a pipeline of programs to start in
    /// the background.
    mutating func parseAsync() throws(SyntaxError) -> Expr {
        keyword("async")
        skipSpaces()
        if peek() == "$" && peek(1) == "(" {
            guard let substitution = try parseDollar()?.substitutionParts,
                  substitution.program.statements.count == 1, case .expression(let commands) = substitution.program.statements[0],
                  let pipeline = commands.pipelineNode else {
                throw SyntaxError("async $(…) runs one pipeline of commands")
            }
            return .async(.capture(pipeline))
        }
        guard peek() != nil else { throw .incomplete("expected a command after 'async'") }
        // `async false` is the command: a Bool value can't run.
        guard commandAhead(boolIsCommand: true).isCommand else {
            throw SyntaxError("async runs a command, as in `async swift build` or `async $(curl …)`")
        }
        return .async(.command(try parsePipeline()))
    }

    /// `import Name from "path"`. The functions it brings aren't known until
    /// it runs; the module's name is, for `Tools.greet(…)`.
    mutating func parseImport() throws(SyntaxError) -> Statement {
        keyword("import")
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'import'")
        mark(.type, from: nameStart)
        skipSpaces()
        guard identifier() == "from" else {
            throw SyntaxError("import needs where the package is: import \(name) from \"path/to/\(name)\"")
        }
        keyword("from")
        skipSpaces()
        let path = try parsePrimary()
        scopes[scopes.count - 1][name] = .variable
        sawImport = true
        return .importPlugin(name: name, path: path)
    }

    /// `$(…)`, `$?` or `$name`, positioned at the dollar sign; nil if the dollar
    /// is just a character.
    mutating func parseShellDollar() throws(SyntaxError) -> Expr? {
        switch peek(1) {
        case "(":
            mark(.punctuation, from: pos, to: pos + 2)
            pos += 2
            // A substitution is its own little program: newlines separate
            // statements again, and it can't break or return out of its host.
            // Whether this one throws is decided out here; the commands
            // inside are a program of their own.
            let throwing = tryDepth > 0
            let saved = (bracketDepth, loopDepth, functionDepth, conditionDepth, tryDepth, switchDepth)
            (bracketDepth, loopDepth, functionDepth, conditionDepth, tryDepth, switchDepth) = (0, 0, 0, 0, 0, 0)
            scopes.append([:])
            defer {
                (bracketDepth, loopDepth, functionDepth, conditionDepth, tryDepth, switchDepth) = saved
                scopes.removeLast()
            }
            let program = try parseProgram(until: ")")
            mark(.punctuation, from: pos, to: pos + 1)
            pos += 1
            return .substitution(program, throwing: throwing)
        case "?":
            throw SyntaxError("$? isn't Swish: a captured command has its own .status, and `try` makes a failure throw")
        case let c? where Parser.isIdentifierStart(c):
            let start = pos
            pos += 1
            let name = identifier()!
            pos += name.count
            mark(.variable, from: start)
            use(name)
            return .dollar(name)
        default:
            return nil
        }
    }

    /// What a unit is, as `commandAhead` decides.
    enum UnitStart {
        case expression
        /// `notAnExpression`: why, when that's what decided it.
        case command(notAnExpression: String?)

        var isCommand: Bool {
            if case .command = self { true } else { false }
        }
    }
}
