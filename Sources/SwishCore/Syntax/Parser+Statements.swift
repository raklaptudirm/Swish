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

        if let name = identifier(), kind(of: name) == .variable || kind(of: name) == .member,
           let assignment = try parseAssignment(name) {
            return .assign(assignment)
        }

        return .chain(try parseChain())
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

    /// `enum Name[: RawType] { case a, b = raw; case c(label: Type, Type) }`
    mutating func parseEnum() throws(SyntaxError) -> EnumDecl {
        keyword("enum")
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'enum'")
        mark(.type, from: nameStart)
        skipSpaces()
        var rawType: TypeAnnotation?
        var conformances: [String] = []
        if consume(":") {
            // A raw type first, if any, then protocols.
            skipSpaces()
            if let word = identifier(), !Parser.protocols.contains(word) {
                rawType = try parseType()
                guard [.int, .string, .double].contains(rawType!) else {
                    throw SyntaxError("an enum's raw values can be Int, String or Double, not \(rawType!)")
                }
                skipSpaces()
                if consume(",") { conformances = try parseConformances() }
            } else {
                conformances = try parseConformances()
            }
            skipSpaces()
        }
        guard consume("{") else { throw expected("'{'") }

        var cases: [EnumCaseDecl] = []
        while true {
            skipSeparators()
            skipSpaces(newlines: true)
            guard peek() != nil else { throw .incomplete("expected '}'") }
            if consume("}") { break }
            guard identifier() == "case" else { throw expected("'case'") }
            keyword("case")
            repeat {
                skipSpaces()
                let caseStart = pos
                let caseName = try parseName(after: "'case'")
                mark(.constant, from: caseStart)
                var associated: [AssociatedValue] = []
                if consume("(") {
                    bracketDepth += 1
                    defer { bracketDepth -= 1 }
                    skipSpaces()
                    while !consume(")") {
                        // `code: Int` has a label; a bare `Int` doesn't.
                        var label: String?
                        if let word = identifier() {
                            var after = pos + word.count
                            while after < chars.count && chars[after] == " " { after += 1 }
                            if after < chars.count && chars[after] == ":" {
                                label = word
                                pos = after + 1
                                skipSpaces()
                            }
                        }
                        associated.append(AssociatedValue(label: label, type: try parseType()))
                        skipSpaces()
                        if consume(",") { skipSpaces() } else if peek() != ")" { throw expected("',' or ')'") }
                    }
                }
                skipSpaces()
                var rawValue: Expr?
                if peek() == "=" && peek(1) != "=" {
                    pos += 1
                    skipSpaces()
                    rawValue = try parseUnary()
                }
                cases.append(EnumCaseDecl(name: caseName, rawValue: rawValue, associated: associated))
                skipSpaces()
            } while consume(",")
        }
        var seen: Set<String> = []
        for enumCase in cases where !seen.insert(enumCase.name).inserted {
            throw SyntaxError("duplicate case '\(enumCase.name)' in enum \(name)")
        }
        scopes[scopes.count - 1][name] = .type
        return EnumDecl(name: name, rawType: rawType, cases: cases, conformances: conformances)
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

    /// `struct Name { … }`: properties, methods and initializers. In their
    /// bodies, members are in scope and go through `self`, as in Swift.
    mutating func parseStruct() throws(SyntaxError) -> StructDecl {
        keyword("struct")
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'struct'")
        mark(.type, from: nameStart)
        skipSpaces()
        var conformances: [String] = []
        if consume(":") {
            conformances = try parseConformances()
            skipSpaces()
        }
        guard consume("{") else { throw expected("'{'") }
        // Bound first, so members can use the type.
        scopes[scopes.count - 1][name] = .type
        var members: [String: NameKind] = ["self": .variable]
        for member in memberNames() { members[member] = .member }
        scopes.append(members)
        defer { scopes.removeLast() }

        var decl = StructDecl(name: name, properties: [], methods: [], initializers: [], conformances: conformances)
        while true {
            skipSeparators()
            skipSpaces(newlines: true)
            guard peek() != nil else { throw .incomplete("expected '}'") }
            if consume("}") { break }
            switch identifier() {
            case "var", "let":
                decl.properties.append(try parseProperty())
            case "func":
                decl.methods.append(try parseFunction(method: true))
            case "mutating":
                keyword("mutating")
                skipSpaces()
                guard identifier() == "func" else { throw expected("'func' after 'mutating'") }
                var method = try parseFunction(method: true)
                method.isMutating = true
                decl.methods.append(method)
            case "init":
                decl.initializers.append(try parseInitializer())
            default:
                throw SyntaxError("a struct holds properties (var, let), methods (func) and initializers (init)")
            }
        }
        var seen: Set<String> = []
        for member in decl.properties.map(\.name) + Set(decl.methods.map(\.name)) where !seen.insert(member).inserted {
            throw SyntaxError("\(name) declares '\(member)' twice")
        }
        return decl
    }

    /// `var x: Int`, `let y = 2`, or a computed `var z: Int { … }`.
    mutating func parseProperty() throws(SyntaxError) -> PropertyDecl {
        let word = identifier()!
        keyword(word)
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'\(word)'")
        mark(.variable, from: nameStart)
        skipSpaces()
        var property = PropertyDecl(name: name, mutable: word == "var")
        if consume(":") {
            property.type = try parseType()
            skipSpaces()
        }
        if consume("{") {
            guard property.mutable else { throw SyntaxError("computed property '\(name)' must be declared with 'var'") }
            guard property.type != nil else { throw SyntaxError("computed property '\(name)' needs a type") }
            property.getter = try parseFunctionBody(parameters: [], anonymous: false).0
            property.getterNames = lastBodyNames
        } else if peek() == "=" && peek(1) != "=" {
            pos += 1
            property.defaultValue = try parseExpression()
        } else if property.type == nil {
            throw SyntaxError("property '\(name)' needs a type or a value")
        }
        return property
    }

    /// `init(x: Int) { self.x = x }`.
    mutating func parseInitializer() throws(SyntaxError) -> FunctionDecl {
        let documentation = documentation(before: pos)
        keyword("init")
        skipSpaces()
        guard peek() == "(" else { throw expected("'(' after 'init'") }
        let parameters = try parseParameters(named: true)
        skipSpaces()
        let throwing = parseThrows()
        guard consume("{") else { throw expected("'{'") }
        let (body, _) = try parseFunctionBody(parameters: parameters, anonymous: false)
        return FunctionDecl(name: "init", parameters: parameters, returnType: nil, body: body,
                            documentation: documentation, isMutating: true, isThrowing: throwing, names: lastBodyNames)
    }

    /// The names a struct's body declares, found before parsing it so a
    /// member can use one declared further down.
    func memberNames() -> [String] {
        declaredNames(["var", "let", "func"], statementsOnly: false).map(\.name)
    }

    /// The names declared ahead, at this level of nesting, up to the end of
    /// the block: each with the keyword that declares it. With
    /// `statementsOnly`, only where a statement starts, so `echo func x`
    /// declares nothing.
    func declaredNames(_ keywords: Set<String>, statementsOnly: Bool) -> [(keyword: String, name: String)] {
        var names: [(keyword: String, name: String)] = []
        var depth = 0
        var index = pos
        var nameFollows: String?
        while index < chars.count {
            let c = chars[index]
            if c == "\"" || c == "'" {
                index += 1
                while index < chars.count && chars[index] != c {
                    if chars[index] == "\\" && c == "\"" { index += 1 }
                    index += 1
                }
            } else if c == "/" && index + 1 < chars.count && chars[index + 1] == "/" {
                while index < chars.count && chars[index] != "\n" { index += 1 }
            } else if "{([".contains(c) {
                depth += 1
            } else if "})]".contains(c) {
                if depth == 0 { break }
                depth -= 1
            } else if depth == 0, Parser.isIdentifierStart(c), index == 0 || !Parser.isIdentifierPart(chars[index - 1]) {
                var end = index
                while end < chars.count && Parser.isIdentifierPart(chars[end]) { end += 1 }
                let word = String(chars[index..<end])
                if let keyword = nameFollows {
                    names.append((keyword, word))
                    nameFollows = nil
                } else if keywords.contains(word) && (!statementsOnly || startsStatement(index)) {
                    nameFollows = word
                }
                index = end
                continue
            }
            index += 1
        }
        return names
    }

    /// Whether a statement can start at `index`: only blanks since the
    /// start, a newline, `;` or a brace.
    func startsStatement(_ index: Int) -> Bool {
        var before = index - 1
        while before >= 0, chars[before] == " " || chars[before] == "\t" { before -= 1 }
        return before < 0 || "\n;{}".contains(chars[before])
    }

    /// The protocols a type can conform to, for now all builtin.
    static let protocols: Set = ["Equatable", "Hashable", "Comparable", "CustomStringConvertible", "Encodable", "Sequence"]

    /// `Equatable, Hashable` after a type's `:`.
    mutating func parseConformances() throws(SyntaxError) -> [String] {
        var names: [String] = []
        repeat {
            skipSpaces()
            let start = pos
            guard let name = identifier() else { throw expected("a protocol") }
            guard Parser.protocols.contains(name) else {
                throw SyntaxError("unknown protocol '\(name)'; Swish has \(Parser.protocols.sorted().joined(separator: ", "))")
            }
            pos += name.count
            mark(.type, from: start)
            names.append(name)
            skipSpaces()
        } while consume(",")
        return names
    }

    /// `switch subject { case …: … default: … }`
    mutating func parseSwitch() throws(SyntaxError) -> SwitchStatement {
        keyword("switch")
        skipSpaces()
        conditionDepth += 1
        let subject = try parseExpression()
        conditionDepth -= 1
        skipSpaces()
        guard consume("{") else { throw expected("'{'") }
        switchDepth += 1
        defer { switchDepth -= 1 }

        var cases: [SwitchCase] = []
        while true {
            skipSeparators()
            skipSpaces(newlines: true)
            guard peek() != nil else { throw .incomplete("expected '}'") }
            if consume("}") { break }
            if identifier() == "default" {
                keyword("default")
                skipSpaces()
                guard consume(":") else { throw expected("':' after 'default'") }
                cases.append(SwitchCase(patterns: [], body: try parseCaseBody(declaring: [:])))
                continue
            }
            guard identifier() == "case" else { throw expected("'case' or 'default'") }
            keyword("case")
            var patterns = [try parsePattern()]
            skipSpaces()
            while consume(",") {
                skipSpaces(newlines: true)
                patterns.append(try parsePattern())
                skipSpaces()
            }
            // Every pattern must bind the same names, for the body to use.
            let names = Set(Parser.names(boundBy: patterns[0]))
            guard patterns.allSatisfy({ Set(Parser.names(boundBy: $0)) == names }) else {
                throw SyntaxError("each pattern in a case must bind the same names")
            }
            var bound: [String: NameKind] = [:]
            for name in names { bound[name] = .variable }
            scopes.append(bound)
            defer { scopes.removeLast() }
            var guardExpr: Expr?
            if identifier() == "where" {
                keyword("where")
                guardExpr = try parseExpression()
                skipSpaces()
            }
            guard consume(":") else { throw expected("':' after the case") }
            cases.append(SwitchCase(patterns: patterns, guardExpr: guardExpr, body: try parseCaseBody(declaring: [:])))
        }
        return SwitchStatement(subject: subject, cases: cases)
    }

    /// The statements after `case …:`, up to the next case or the `}`.
    mutating func parseCaseBody(declaring names: [String: NameKind]) throws(SyntaxError) -> Program {
        scopes.append(names)
        defer { scopes.removeLast() }
        var statements: [Statement] = []
        while true {
            skipSeparators()
            guard let c = peek() else { throw .incomplete("expected '}'") }
            if c == "}" || identifier() == "case" || identifier() == "default" { break }
            statements.append(try parseStatement())
            skipSpaces()
            guard let next = peek() else { continue }
            guard next == ";" || next == "\n" || next == "}" else { throw unexpected(next) }
        }
        guard !statements.isEmpty else {
            throw SyntaxError("a case needs at least one statement; write `break` to do nothing")
        }
        return Program(statements: statements)
    }

    /// A pattern: `_`, `let x`, `.name(…)`, `Type.name(…)`, or an
    /// expression to compare with. Under `let`/`var` (`binding`), names in
    /// it bind rather than refer: `let .failed(code)`.
    mutating func parsePattern(binding: Bool = false, mutable: Bool = false) throws(SyntaxError) -> Pattern {
        skipSpaces()
        if let word = identifier(), word == "let" || word == "var" {
            keyword(word)
            return try parsePattern(binding: true, mutable: word == "var")
        }
        if identifier() == "_" {
            pos += 1
            return .wildcard
        }
        if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
            let start = pos
            pos += 1
            let name = identifier()!
            pos += name.count
            mark(.constant, from: start)
            return .enumCase(type: nil, name: name, arguments: peek() == "(" ? try parsePatternArguments(binding: binding, mutable: mutable) : nil)
        }
        if let word = identifier(), kind(of: word) == .type, peek(word.count) == "." {
            mark(.type, from: pos, to: pos + word.count)
            pos += word.count + 1
            let name = try parseName(after: "'.'")
            return .enumCase(type: word, name: name, arguments: peek() == "(" ? try parsePatternArguments(binding: binding, mutable: mutable) : nil)
        }
        if binding, let word = identifier(), !Parser.keywords.contains(word) {
            mark(.variable, from: pos, to: pos + word.count)
            pos += word.count
            return .binding(name: word, mutable: mutable)
        }
        return .expression(try parseExpression(logical: false))
    }

    mutating func parsePatternArguments(binding: Bool, mutable: Bool) throws(SyntaxError) -> [PatternArgument] {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var arguments: [PatternArgument] = []
        skipSpaces()
        while !consume(")") {
            var label: String?
            if let word = identifier(), word != "let", word != "var", peek(word.count) == ":" {
                label = word
                pos += word.count + 1
                skipSpaces()
            }
            arguments.append(PatternArgument(label: label, pattern: try parsePattern(binding: binding, mutable: mutable)))
            skipSpaces()
            if consume(",") { skipSpaces() } else if peek() != ")" { throw expected("',' or ')'") }
        }
        return arguments
    }

    /// The names a pattern binds.
    static func names(boundBy pattern: Pattern) -> [String] {
        switch pattern {
        case .binding(let name, _): [name]
        case .enumCase(_, _, let arguments): (arguments ?? []).flatMap { names(boundBy: $0.pattern) }
        case .wildcard, .expression: []
        }
    }

    mutating func parseDeclaration() throws(SyntaxError) -> Statement {
        let keyword = identifier()!
        self.keyword(keyword)
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'\(keyword)'")
        mark(.variable, from: nameStart)
        skipSpaces()
        var type: TypeAnnotation?
        if consume(":") {
            type = try parseType()
            skipSpaces()
        }
        guard peek() == "=" && peek(1) != "=" else { throw expected("'=' after '\(name)'") }
        pos += 1
        var value = try parseExpression()
        if let type { value = .annotated(value, type) }
        scopes[scopes.count - 1][name] = .variable
        return .declare(name: name, mutable: keyword == "var", value: value)
    }

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
        if identifier() == "try", let command = try parseThrowingCommand() {
            return .pipeline(command)
        }
        if case .command(let reason) = commandAhead() {
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
            self = beforeExpression
            expr = try parseExpression(logical: false)
        }
        skipSpaces()
        guard peek() == "|", peek(1) != "|" else { return .expression(expr) }
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

    /// What a unit is, as `commandAhead` decides.
    enum UnitStart {
        case expression
        /// `notAnExpression`: why, when that's what decided it.
        case command(notAnExpression: String?)

        var isCommand: Bool {
            if case .command = self { true } else { false }
        }
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
