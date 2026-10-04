import Foundation
import SwishKit

extension Parser {
    // MARK: Statements

    mutating func parseProgram(until terminator: Character?) throws(SyntaxError) -> Program {
        // Functions and types can be used before their declarations, as in
        // Swift, so the names this block declares are bound from its start.
        for (keyword, name) in declaredNames(["func", "struct", "enum"], statementsOnly: true)
            where scopes[scopes.count - 1][name] == nil {
            scopes[scopes.count - 1][name] = keyword == "func" ? .function : .type
        }
        var statements: [Statement] = []
        var lines: [Int] = []
        while true {
            skipSeparators()
            guard let c = peek() else {
                if let terminator { throw .incomplete("expected '\(terminator)'") }
                break
            }
            if c == terminator { break }
            lines.append(line(at: pos))
            statements.append(try parseStatement())
            skipSpaces()
            guard let next = peek(), next != terminator else { continue }
            guard next == ";" || next == "\n" else { throw unexpected(next) }
        }
        return Program(statements: statements, lines: lines)
    }

    /// The 1-based line `index` is on.
    func line(at index: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= index { low = middle } else { high = middle }
        }
        return low + 1
    }

    mutating func parseStatement() throws(SyntaxError) -> Statement {
        switch identifier() {
        case "let", "var":
            return try parseDeclaration()
        case "func":
            return .function(try parseFunction())
        case "guard":
            return try parseGuard()
        case "return":
            guard functionDepth > 0 else { throw SyntaxError("'return' outside a function") }
            keyword("return")
            skipSpaces()
            guard let c = peek(), c != ";" && c != "\n" && c != "}" else { return .returnStatement(nil) }
            return .returnStatement(try parseExpression())
        case "do":
            return try parseDoCatch()
        case "break":
            guard loopDepth > 0 || switchDepth > 0 else { throw SyntaxError("'break' outside a loop or switch") }
            keyword("break")
            return .breakStatement
        case "continue":
            guard loopDepth > 0 else { throw SyntaxError("'continue' outside a loop") }
            keyword("continue")
            return .continueStatement
        case "enum":
            return .enumDecl(try parseEnum())
        case "import":
            return try parseImport()
        case "struct":
            return .structDecl(try parseStruct())
        case "defer":
            keyword("defer")
            skipSpaces()
            // Nothing leaves a `defer`: it can't return, break or continue.
            let saved = (functionDepth, loopDepth, switchDepth)
            (functionDepth, loopDepth, switchDepth) = (0, 0, 0)
            defer { (functionDepth, loopDepth, switchDepth) = saved }
            return .deferBlock(try parseBlock())
        // Only the prelude extends, and only Sequence: its methods are
        // looked up by name for any sequence. Extensions of your own need
        // members found by type, which comes with step 4 of the foundations.
        case "extension" where prelude:
            return try parseExtension()
        case "fallthrough":
            guard switchDepth > 0 else { throw SyntaxError("'fallthrough' outside a switch") }
            keyword("fallthrough")
            return .fallthroughStatement
        default:
            break
        }

        if identifier() == "env", let assignment = try parseEnvironmentAssignment() {
            return assignment
        }

        // A type's name starts an assignment too, to a static var: `Point.count += 1`.
        if let name = identifier(), canStartAssignment(kind(of: name)), let assignment = try parseAssignment(name) {
            return .assign(assignment)
        }

        return .chain(try parseChain())
    }

    private func canStartAssignment(_ kind: NameKind?) -> Bool {
        switch kind {
        case .variable?, .member?, .type?, .staticMember?: true
        case .function?, nil: false
        }
    }

    /// `name = v`, `name.a[i] += v`, …, or nil (having looked ahead) if the
    /// statement isn't an assignment. In a struct's body, a member's name
    /// assigns through `self`.
    mutating func parseAssignment(_ name: String) throws(SyntaxError) -> Assignment? {
        let start = (pos, spans.count)
        mark(.variable, from: pos, to: pos + name.count)
        pos += name.count
        var assignment = Assignment(root: name, value: .literal(.nothing))
        if kind(of: name) == .member {
            assignment.root = "self"
            assignment.path = [.member(name)]
        } else if case .staticMember(let type)? = kind(of: name) {
            assignment.root = type
            assignment.path = [.member(name)]
        }
        use(assignment.root)
        while true {
            if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
                pos += 1
                let member = identifier()!
                pos += member.count
                assignment.path.append(.member(member))
            } else if peek() == "[" {
                pos += 1
                bracketDepth += 1
                skipSpaces()
                let index = try parseExpression()
                skipSpaces()
                bracketDepth -= 1
                guard consume("]") else { throw expected("']'") }
                assignment.path.append(.index(index))
            } else {
                break
            }
        }
        skipSpaces()
        let compound: [(String, BinaryOperator)] = [("+=", .add), ("-=", .subtract), ("*=", .multiply), ("/=", .divide)]
        if let (text, op) = compound.first(where: { matches($0.0) }) {
            mark(.punctuation, from: pos, to: pos + text.count)
            pos += text.count
            assignment.op = op
        } else if peek() == "=" && peek(1) != "=" {
            pos += 1
        } else {
            rewind(to: start)
            return nil
        }
        assignment.value = try parseExpression()
        return assignment
    }

    func matches(_ text: String) -> Bool {
        text.enumerated().allSatisfy { peek($0.offset) == $0.element }
    }

    /// `env.NAME = value` or `env[name] = value`, or nil (having looked
    /// ahead) if this is some other statement starting with `env`.
    mutating func parseEnvironmentAssignment() throws(SyntaxError) -> Statement? {
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

    /// `do { … }`, optionally `catch { … }` or `catch let name { … }`.
    mutating func parseDoCatch() throws(SyntaxError) -> Statement {
        keyword("do")
        skipSpaces()
        let body = try parseBlock()
        let afterBody = (pos, spans.count)
        skipSpaces(newlines: true)
        guard identifier() == "catch" else {
            rewind(to: afterBody)
            return .doCatch(body: body, errorName: "error", handler: nil)
        }
        keyword("catch")
        skipSpaces()
        var name = "error"
        if identifier() == "let" {
            keyword("let")
            skipSpaces()
            let nameStart = pos
            name = try parseName(after: "'let'")
            mark(.variable, from: nameStart)
            skipSpaces()
        }
        let handler = try parseBlock(declaring: [name: .variable])
        return .doCatch(body: body, errorName: name, handler: handler)
    }

    /// Whether a statement can start at `index`: only blanks since the
    /// start, a newline, `;` or a brace.
    func startsStatement(_ index: Int) -> Bool {
        var before = index - 1
        while before >= 0, chars[before] == " " || chars[before] == "\t" { before -= 1 }
        return before < 0 || "\n;{}".contains(chars[before])
    }

    /// The protocols a type can conform to, for now all builtin.
    static let protocols: Set = ["Equatable", "Hashable", "Comparable", "CustomStringConvertible", "Encodable", "Sequence", "Tabular"]

    /// The names a pattern binds.
    static func names(boundBy pattern: Pattern) -> [String] {
        switch pattern {
        case .binding(let name, _): [name]
        case .enumCase(_, _, let arguments): (arguments ?? []).flatMap { names(boundBy: $0.pattern) }
        case .wildcard, .expression: []
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

    mutating func parseBlock(declaring names: [String: NameKind] = [:]) throws(SyntaxError) -> Program {
        guard peek() == "{" else { throw expected("'{'") }
        pos += 1
        let savedCondition = conditionDepth
        let savedGuard = guardCondition
        conditionDepth = 0
        guardCondition = false
        scopes.append(names)
        defer {
            scopes.removeLast()
            conditionDepth = savedCondition
            guardCondition = savedGuard
        }
        let body = try parseProgram(until: "}")
        pos += 1 // parseProgram only returns at the closing brace.
        return body
    }
}
