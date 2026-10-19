import Foundation

// Spike: the shell's grammar, read by the shell. A `Reader` stands on the text of one source at the start of a form of the
// shell's (a command, a pipeline, `$(…)`, `$name`, `async …`) and reads it as characters; where the form holds Swift (an
// argument, `\(…)`, a closure, the program in `$(…)`) it finds the extent with the lexical scanner and has the front end cure
// that text in turn. What it gives back is Swift: the form as the calls it means, which a plain Swift front end reads.

struct Failure: Error, CustomStringConvertible {
    var message: String
    var incomplete: Bool
    init(_ message: String, incomplete: Bool = false) {
        self.message = message
        self.incomplete = incomplete
    }
    static func incomplete(_ message: String) -> Failure { Failure(message, incomplete: true) }
    var description: String { message }
}

enum Attempt: Equatable {
    case plain, optional, forced

    var keyword: String {
        switch self {
        case .plain: "try"
        case .optional: "try?"
        case .forced: "try!"
        }
    }
}

/// A piece of a command's word.
enum Piece: Equatable {
    case literal(String)
    /// Unquoted text with a wildcard in it.
    case glob(String)
    /// Swift, an expression's value in the text.
    case expression(String)
    /// An unquoted `$xs` or `\(xs)`: a list in a word of its own is a word per item.
    case spread(String)
}

enum ShellWord: Equatable {
    case text([Piece])
    /// A closure passed as an argument: Swift.
    case closure(String)
}

struct ShellRedirect: Equatable {
    enum Target: Equatable {
        case file([Piece], Mode)
        case descriptor(Int)
    }
    enum Mode: Equatable { case read, write, append }
    var fd: Int
    var target: Target
}

struct CommandOut {
    var words: [ShellWord]
    var external = false
    var redirects: [ShellRedirect] = []
    var environment: [(name: String, value: [Piece])] = []
    var call: String?
}

struct PipelineOut {
    var commands: [CommandOut]
    var source: String
    var input: String?
    var throwing: Attempt?
}

enum Operand {
    case command(PipelineOut)
    case expression(String)

    var isOptionalAttempt: Bool {
        if case .expression(let text) = self { text.hasPrefix("try?") } else { false }
    }
}

struct Chain {
    var first: Operand
    var links: [(isAnd: Bool, operand: Operand)] = []
    var isCondition = false
    var operands: [Operand] { [first] + links.map(\.operand) }
}

enum UnitStart {
    case expression
    case command(notAnExpression: String?)
    var isCommand: Bool { if case .command = self { true } else { false } }
}

/// What a stretch of source is, for coloring it as it is typed.
enum HighlightKind: Equatable, Sendable {
    case keyword, command, flag, string, number, constant, variable, comment, type, punctuation
}

struct HighlightSpan: Equatable, Sendable {
    var range: Range<Int>
    var kind: HighlightKind
}

struct Reader {
    unowned let front: Front
    let text: Text
    /// The same text with its substitutions blanked: what Swift is asked about.
    let blanked: Text
    let names: Names
    var pos: Int
    var conditionDepth = 0
    var guardCondition = false
    var tryDepth = 0
    /// The highlighting of what it has read, in the characters of its text.
    var spans: [HighlightSpan] = []

    var chars: [Character] { text.chars }

    init(front: Front, text: Text, blanked: Text, names: Names, at pos: Int) {
        self.front = front
        self.text = text
        self.blanked = blanked
        self.names = names
        self.pos = pos
    }

    static let statementKeywords: Set<String> = [
        "let", "var", "func", "return", "break", "continue", "do", "catch", "enum", "fallthrough", "import", "struct", "defer", "guard", "throw", "repeat",
        "class", "actor", "protocol", "extension", "typealias",
    ]
    /// The keywords a line can begin with: a statement's, a unit's (`if make { … }`), or an expression's (`await job`). Completion
    /// offers them where a command could go.
    static let lineStarts = statementKeywords.subtracting(["catch"]).union(["if", "for", "while", "switch", "try", "async", "await"])
    /// The words a command can follow directly and still be in command position.
    static let beforeCommand: Set<String> = ["if", "while", "else", "foreign"]
    static let reservedStarts = statementKeywords.union(["if", "for", "while", "switch", "else", "case", "default", "in"])

    // MARK: Highlighting

    mutating func mark(_ kind: HighlightKind, from start: Int, to end: Int? = nil) {
        let end = min(end ?? pos, chars.count)
        if start < end { spans.append(HighlightSpan(range: start..<end, kind: kind)) }
    }

    /// The Swift in a slice of this text, cured; its highlighting joins this reader's. `prefix`: characters put before the slice
    /// that are not in the text.
    mutating func cureSlice(_ slice: String, from start: Int, prefix: Int = 0, asExpression: Bool = true) throws -> String {
        let cured = try front.cureWithSpans(slice, names: names.snapshot(atByte: text.byteOf[min(start, text.count)]), asExpression: asExpression)
        for span in cured.spans where span.range.lowerBound >= prefix {
            spans.append(HighlightSpan(range: (span.range.lowerBound - prefix + start)..<(span.range.upperBound - prefix + start), kind: span.kind))
        }
        return cured.text
    }

    // MARK: Scanning

    func peek(_ offset: Int = 0) -> Character? {
        let index = pos + offset
        return index < chars.count ? chars[index] : nil
    }

    func startsWith(_ s: String) -> Bool {
        var index = pos
        for c in s {
            guard index < chars.count, chars[index] == c else { return false }
            index += 1
        }
        return true
    }

    mutating func consume(_ s: String) -> Bool {
        guard startsWith(s) else { return false }
        pos += s.count
        return true
    }

    func identifier() -> String? {
        guard let first = peek(), Lex.isIdentifierStart(first) else { return nil }
        var name = String(first)
        while let c = peek(name.count), Lex.isIdentifierPart(c) { name.append(c) }
        return name
    }

    mutating func skipSpaces(newlines: Bool = false) {
        while let c = peek() {
            if c == " " || c == "\t" {
                pos += 1
            } else if c == "\\" && peek(1) == "\n" {
                pos += 2
            } else if c == "\n" && newlines {
                pos += 1
            } else if (c == "/" && peek(1) == "/") || (c == "#" && pos == 0 && peek(1) == "!") {
                let start = pos
                while let d = peek(), d != "\n" { pos += 1 }
                mark(.comment, from: start)
            } else {
                return
            }
        }
    }

    func isWordBoundary(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || "|;&(){}<>".contains(c)
    }

    func expected(_ what: String) -> Failure {
        guard let c = peek() else { return .incomplete("expected \(what)") }
        return Failure("expected \(what), found \(c == "\n" ? "newline" : "'\(c)'")")
    }

    // MARK: Chains

    /// Commands joined by `&&` and `||`, with Swift between them or not; nil (having looked ahead) when there is no command in
    /// it, which is Swift's.
    mutating func parseCommandChain(condition: Bool) throws -> Chain? {
        let start = self
        var operands: [Operand] = []
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
        } catch let error as Failure {
            guard sawCommand || error.incomplete else {
                self = start
                return nil
            }
            throw error
        }
        var chain = Chain(first: operands[0], isCondition: condition)
        chain.links = zip(joins, operands.dropFirst()).map { (isAnd: $0, operand: $1) }
        let isShells = chain.operands.contains { operand in
            switch operand {
            case .command: true
            case .expression: condition && operand.isOptionalAttempt
            }
        }
        guard isShells else {
            self = start
            return nil
        }
        return chain
    }

    private mutating func parseChainOperand(_ sawCommand: inout Bool) throws -> Operand {
        skipSpaces()
        guard peek() != nil else { throw Failure.incomplete("expected a command") }
        if let word = identifier(), Reader.reservedStarts.contains(word) {
            throw Failure("'\(word)' must start a statement")
        }
        if identifier() == "try" {
            let before = sawCommand
            sawCommand = true
            if let command = try parseThrowingCommand() { return .command(command) }
            sawCommand = before
        }
        // `async …` is an expression whichever way it goes.
        if identifier() == "async" {
            return .expression(try parseAsync())
        }
        if commandAhead().isCommand {
            sawCommand = true
            return .command(try parsePipeline())
        }
        let start = pos
        let probe = swiftExpression(logical: true) ?? swiftExpression(logical: false)
        guard let probe, probe.failure == nil else {
            throw Failure("not an expression")
        }
        let slice = text.slice(start..<probe.end)
        pos = probe.end
        let cured = try cureSlice(slice, from: start)
        skipSpaces()
        guard peek() == "|", peek(1) != "|" else { return .expression(cured) }
        pos += 1
        skipSpaces(newlines: true)
        sawCommand = true
        return .command(try parsePipeline(from: start, input: cured))
    }

    private func swiftExpression(logical: Bool) -> Probe? {
        let probe = SwiftProbe.expression(in: blanked, at: pos, logical: logical, names: names, strictNames: false, inCondition: conditionDepth > 0)
        return probe.failure == nil ? probe : nil
    }

    /// `try cmd …` or `try! cmd …`, or nil (having looked ahead) when what follows the `try` is an expression.
    mutating func parseThrowingCommand() throws -> PipelineOut? {
        let before = self
        guard let kind = parseTry() else { return nil }
        skipSpaces()
        guard peek() != nil, commandAhead(boolIsCommand: kind != .optional).isCommand else {
            self = before
            return nil
        }
        if kind == .optional {
            throw Failure("try? needs a value; capture the command with try? $(…)")
        }
        tryDepth += 1
        defer { tryDepth -= 1 }
        var pipeline = try parsePipeline()
        pipeline.throwing = kind
        return pipeline
    }

    mutating func parseTry() -> Attempt? {
        guard identifier() == "try" else { return nil }
        let start = pos
        pos += 3
        defer { mark(.keyword, from: start) }
        if consume("?") { return .optional }
        if consume("!") { return .forced }
        return .plain
    }

    /// Whether the unit ahead is a command rather than an expression (see the grammar's rules in `commandAhead` of the
    /// interpreter's old plug-in): an expression if one parses there and the unit ends after it.
    mutating func commandAhead(boolIsCommand: Bool = false) -> UnitStart {
        let saved = self
        defer { self = saved }
        skipSpaces()
        guard let c = peek() else { return .expression }
        if c == "^" || (c == "$" && peek(1).map(Lex.isIdentifierStart) ?? false) { return .command(notAnExpression: nil) }
        // `'raw'` is a string, which Swift has no spelling of: an expression if it is the whole unit.
        if c == "'", let close = chars[(pos + 1)...].firstIndex(of: "'") {
            pos = close + 1
            skipSpaces()
            return endsUnit() ? .expression : .command(notAnExpression: nil)
        }
        if let word = identifier() {
            let after = peek(word.count)
            if boolIsCommand && (word == "true" || word == "false") && after.map(isWordBoundary) ?? true {
                return .command(notAnExpression: nil)
            }
            if after == "(" { return .expression }
            if names.role(of: word, at: here) == .function { return after != "." && after != "[" ? .command(notAnExpression: nil) : .expression }
        }
        var wordEnd = pos
        while wordEnd < chars.count, !isWordBoundary(chars[wordEnd]) { wordEnd += 1 }
        let probe = SwiftProbe.expression(in: blanked, at: pos, logical: true, names: names, inCondition: conditionDepth > 0)
        if let failure = probe.failure {
            guard failure <= wordEnd else { return .expression }
            return .command(notAnExpression: nil)
        }
        pos = probe.end
        skipSpaces()
        guard endsUnit() else { return .command(notAnExpression: nil) }
        return .expression
    }

    func endsUnit() -> Bool {
        guard let c = peek() else { return true }
        if ";\n|&})".contains(c) { return true }
        if c == "{" && conditionDepth > 0 { return true }
        return guardCondition && identifier() == "else"
    }

    // MARK: Pipelines and commands

    mutating func parsePipeline(from start: Int? = nil, input: String? = nil) throws -> PipelineOut {
        let start = start ?? pos
        var commands = [try parseCommand()]
        // A method with nothing piped in, and no function or program by that name, has nothing to work on.
        if input == nil, !commands[0].external, case .text(let pieces)? = commands[0].words.first, pieces.count == 1, case .literal(let name) = pieces[0],
           names.role(of: name, at: here) != .function, front.isMethodWithoutInput(name) {
            throw Failure("\(name) is a method: pipe something into it, as in `ls | \(name)`, or call it on a value, as in `xs.\(name)(…)`")
        }
        var end = pos
        while true {
            skipSpaces()
            guard peek() == "|", peek(1) != "|" else { break }
            pos += 1
            skipSpaces(newlines: true)
            commands.append(try parseCommand())
            end = pos
        }
        let source = text.slice(start..<end).trimmingCharacters(in: .whitespacesAndNewlines)
        front.record(.pipeline, source)
        for (index, command) in commands.enumerated() where !command.external && command.call == nil && command.redirects.isEmpty {
            guard case .text(let first)? = command.words.first, first.count == 1, case .literal(let name) = first[0] else { continue }
            var words: [String] = []
            for word in command.words.dropFirst() {
                guard case .text(let pieces) = word, pieces.allSatisfy({ if case .literal = $0 { true } else { false } }) else { words = []; break }
                words.append(pieces.map { if case .literal(let t) = $0 { t } else { "" } }.joined())
            }
            if command.words.count - 1 == words.count {
                front.record(use: Front.CommandUse(name: name, words: words, piped: index > 0 || input != nil, source: source))
            }
        }
        return PipelineOut(commands: commands, source: source, input: input, throwing: nil)
    }

    mutating func parseCommand() throws -> CommandOut {
        skipSpaces()
        let nameStart = pos
        var external = consume("^")
        let caretStart: Int? = external ? nameStart : nil
        if !external, identifier() == "foreign", peek(7) == " " || peek(7) == "\t" {
            mark(.keyword, from: pos, to: pos + 7)
            pos += 7
            skipSpaces()
            external = true
        }
        var command = CommandOut(words: [], external: external)
        while true {
            skipSpaces()
            guard let c = peek(), !endsCommand(c) else { break }
            if let redirects = try parseRedirect() {
                command.redirects += redirects
                continue
            }
            if c == "{" && peek(1) != "}" {
                command.words.append(.closure(try parseClosure(arityOf: command)))
                continue
            }
            // `sorted(by: "size")`: a name touching its arguments is a call; a trailing closure may follow.
            if c == "(", command.words.count == 1, command.call == nil, !external, pos > 0, Lex.isIdentifierPart(chars[pos - 1]) {
                var arguments = try parseArguments()
                skipSpaces()
                if peek() == "{" {
                    let closure = try parseClosure(arityOf: command)
                    arguments += (arguments.isEmpty ? "" : ", ") + closure
                }
                command.call = arguments
                continue
            }
            if c == "(" {
                throw Failure("unexpected '(' in a command; quote it, or use \\(…) to interpolate an expression")
            }
            if command.call != nil {
                throw Failure("a command written as a call takes all its arguments in the parentheses")
            }
            if c == "&" {
                throw Failure("'&' isn't Swish; background jobs will be `async command`")
            }
            // `NAME=value` before the command sets it for the command.
            if command.words.isEmpty, let name = identifier(), peek(name.count) == "=", peek(name.count + 1) != "=" {
                mark(.variable, from: pos, to: pos + name.count)
                pos += name.count + 1
                let value = peek().map(isWordBoundary) ?? true ? [.literal("")] : try parseWord()
                command.environment.append((name: name, value: value))
                continue
            }
            let wordStart = pos
            let word = try parseWord()
            if command.words.isEmpty {
                mark(.command, from: command.redirects.isEmpty && command.environment.isEmpty ? caretStart ?? wordStart : wordStart)
            } else if chars[wordStart] == "-" {
                mark(.flag, from: wordStart)
            }
            command.words.append(.text(word))
        }
        guard !command.words.isEmpty else {
            if let assignment = command.environment.first {
                throw Failure("\(assignment.name)=… sets a variable for one command; use env.\(assignment.name) = … to set it for the session")
            }
            if let c = peek() { throw Failure(c == "\n" ? "unexpected newline" : "unexpected '\(c)'") }
            throw Failure.incomplete("expected a command")
        }
        return command
    }

    func endsCommand(_ c: Character) -> Bool {
        switch c {
        case "|", ";", "\n", ")", "}": true
        case "&": peek(1) == "&"
        case "{": peek(1) != "}" && conditionDepth > 0
        case "e": guardCondition && identifier() == "else" && (pos == 0 || isWordBoundary(chars[pos - 1]))
        default: false
        }
    }

    // MARK: Redirects

    mutating func parseRedirect() throws -> [ShellRedirect]? {
        let start = pos
        try rejectPosixRedirect()
        func touchesBoundary(after count: Int) -> Bool { peek(count).map(isWordBoundary) ?? true }
        if startsWith("e>o") && touchesBoundary(after: 3) {
            pos += 3
            mark(.punctuation, from: start)
            return [ShellRedirect(fd: 2, target: .descriptor(1))]
        }
        if startsWith("o>e") && touchesBoundary(after: 3) {
            pos += 3
            mark(.punctuation, from: start)
            return [ShellRedirect(fd: 1, target: .descriptor(2))]
        }
        let fds: [Int]
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
            if peek() == nil { throw Failure.incomplete("expected a file to redirect to") }
            throw expected("a file to redirect to")
        }
        let file = try parseWord()
        let mode: ShellRedirect.Mode = fds == [0] ? .read : append ? .append : .write
        if fds == [1, 2] {
            return [ShellRedirect(fd: 1, target: .file(file, mode)), ShellRedirect(fd: 2, target: .descriptor(1))]
        }
        return [ShellRedirect(fd: fds[0], target: .file(file, mode))]
    }

    func rejectPosixRedirect() throws {
        var digits = ""
        while let c = peek(digits.count), Lex.isDigit(c) { digits.append(c) }
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
            throw Failure("numbered descriptors like \(number)\(rest.prefix(1)) aren't part of Swish; redirect with >, e>, e>o, o>e or o+e>")
        default: swish = nil
        }
        if let swish { throw Failure("that's a POSIX redirect; in Swish it's \(swish)") }
    }

    // MARK: Words

    mutating func parseWord() throws -> [Piece] {
        var parts: [Piece] = []
        var literal = ""
        var wildcard = false
        func flush() {
            if !literal.isEmpty { parts.append(wildcard ? .glob(literal) : .literal(literal)) }
            literal = ""
            wildcard = false
        }
        if peek() == "~", peek(1).map({ $0 == "/" || isWordBoundary($0) }) ?? true {
            parts.append(.expression(environment("HOME")))
            pos += 1
        }
        while let c = peek() {
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
                guard let next = peek(1) else { throw Failure.incomplete("expected a character after '\\'") }
                if next == "(" {
                    flush()
                    parts.append(.spread(try parseInterpolation()))
                } else if next == "\n" {
                    pos += 2
                } else if "*[".contains(next) {
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
                    parts.append(.spread(expr))
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

    mutating func parseRawString() throws -> String {
        guard let end = chars[(pos + 1)...].firstIndex(of: "'") else {
            mark(.string, from: pos, to: chars.count)
            throw Failure.incomplete("unterminated string")
        }
        let text = String(chars[(pos + 1)..<end])
        mark(.string, from: pos, to: end + 1)
        pos = end + 1
        return text
    }

    mutating func parseInterpolatedString() throws -> [Piece] {
        let start = pos
        pos += 1
        var parts: [Piece] = []
        var literal = ""
        while true {
            guard let c = peek() else {
                mark(.string, from: start, to: chars.count)
                throw Failure.incomplete("unterminated string")
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
                    throw Failure.incomplete("unterminated string")
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
                default: throw Failure("invalid escape '\\\(next)' in string: write \\\\ for a backslash, or use single quotes to keep every backslash")
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

    mutating func parseUnicodeEscape() throws -> Character {
        guard consume("{") else { throw Failure("expected '{' after '\\u'") }
        var hex = ""
        while let c = peek(), c.isHexDigit {
            hex.append(c)
            pos += 1
        }
        guard consume("}"), let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw Failure("invalid unicode escape '\\u{\(hex)'")
        }
        return Character(scalar)
    }

    // MARK: Swift inside the shell's forms

    /// `\(expression)`, at the backslash: the expression, cured.
    mutating func parseInterpolation() throws -> String {
        guard let close = Lex.closing(chars, from: pos + 1) else {
            mark(.punctuation, from: pos, to: pos + 2)
            throw Failure.incomplete("expected ')'")
        }
        mark(.punctuation, from: pos, to: pos + 2)
        let innerStart = pos + 2
        let inner = text.slice(innerStart..<close)
        mark(.punctuation, from: close, to: close + 1)
        pos = close + 1
        return try cureSlice(inner, from: innerStart)
    }

    /// `{ … }` at the brace: the closure, cured.
    mutating func parseClosure(arityOf command: CommandOut? = nil) throws -> String {
        guard let close = Lex.closing(chars, from: pos) else { throw Failure.incomplete("expected '}'") }
        let source = text.slice(pos..<(close + 1))
        let sourceStart = pos
        pos = close + 1
        let cured = try cureSlice(source, from: sourceStart)
        // A closure word takes what its stage gives it; Swift's closure without parameters or `$0` takes none.
        if SwiftProbe.isParameterlessClosure(source), cured.range(of: #"\$\d"#, options: .regularExpression) == nil {
            var name: String?
            if let command, case .text(let pieces)? = command.words.first, pieces.count == 1, case .literal(let literal) = pieces[0] { name = literal }
            let arity = name.flatMap { names.closureArities[$0] ?? front.closureArity($0) } ?? 1
            if arity > 0 {
                let body = cured.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
                return "{ " + Array(repeating: "_", count: arity).joined(separator: ", ") + " in " + body + " }"
            }
        }
        return cured
    }

    /// `(a, b: c)` at the parenthesis: what is between, cured.
    mutating func parseArguments() throws -> String {
        guard let close = Lex.closing(chars, from: pos) else { throw Failure.incomplete("expected ')'") }
        let innerStart = pos + 1
        let inner = text.slice(innerStart..<close)
        pos = close + 1
        // As the arguments of a call, so that a label is a label (`while:`, `in:`), not the start of a statement.
        let cured = try cureSlice("_(\(inner))", from: innerStart, prefix: 2)
        return String(cured.dropFirst(2).dropLast())
    }

    func environment(_ name: String) -> String { "env[\"\(name)\"]!" }

    /// `$0` in a closure, or a `$` form of the shell's, at the dollar sign; nil if the dollar is just a character.
    mutating func parseDollar() throws -> String? {
        switch peek(1) {
        case let c? where Lex.isDigit(c): return nil
        case "(", "?": return try parseShellDollar()
        case let c? where Lex.isIdentifierStart(c): return try parseShellDollar()
        default: return nil
        }
    }

    /// `$(…)`, `$?` or `$name`, at the dollar sign: `capture { … }`, the variable, or the environment's.
    mutating func parseShellDollar() throws -> String? {
        switch peek(1) {
        case "(":
            mark(.punctuation, from: pos, to: pos + 2)
            guard let close = Lex.closing(chars, from: pos + 1) else { throw Failure.incomplete("expected ')'") }
            let innerStart = pos + 2
            let inner = text.slice(innerStart..<close)
            let throwing = tryDepth > 0
            mark(.punctuation, from: close, to: close + 1)
            pos = close + 1
            let program = try cureSlice(inner, from: innerStart, asExpression: false)
            return throwing ? "captureThrowing({ \(program) })" : "capture({ \(program) })"
        case "?":
            throw Failure("$? isn't Swish: a captured command has its own .status, and `try` makes a failure throw")
        case let c? where Lex.isIdentifierStart(c):
            let start = pos
            pos += 1
            let name = identifier()!
            pos += name.count
            mark(.variable, from: start)
            front.record(.dollar, "$" + name)
            return dollar(name)
        default:
            return nil
        }
    }

    /// The byte offset of the position, which scopes are asked by.
    var here: Int { text.byteOf[min(pos, text.count)] }

    func dollar(_ name: String) -> String {
        switch names.role(of: name, at: here) {
        case .variable?, .member?, .staticMember?: name
        default: environment(name)
        }
    }

    // MARK: async

    mutating func parseAsync() throws -> String {
        let start = pos
        mark(.keyword, from: pos, to: pos + "async".count)
        pos += "async".count
        skipSpaces()
        if peek() == "$" && peek(1) == "(" {
            let open = pos
            mark(.punctuation, from: open, to: open + 2)
            guard let close = Lex.closing(chars, from: pos + 1) else { throw Failure.incomplete("expected ')'") }
            let inner = text.slice((open + 2)..<close)
            mark(.punctuation, from: close, to: close + 1)
            pos = close + 1
            var reader = Reader(front: front, text: Text(inner), blanked: Text(Lex.blankingSubstitutions(Array(inner))), names: names.snapshot(atByte: here), at: 0)
            defer { for span in reader.spans { spans.append(HighlightSpan(range: (span.range.lowerBound + open + 2)..<(span.range.upperBound + open + 2), kind: span.kind)) } }
            guard let chain = try reader.parseCommandChain(condition: false), chain.links.isEmpty,
                  case .command(let pipeline) = chain.first else {
                throw Failure("async $(…) runs one pipeline of commands")
            }
            return "\(emit(pipeline)).startCapturing()"
        }
        guard peek() != nil else { throw Failure.incomplete("expected a command or an expression after 'async'") }
        if commandAhead(boolIsCommand: true).isCommand { return "\(emit(try parsePipeline())).start()" }
        // `async f(x)`, `async { … }`: Swish code, as a task of its own.
        let exprStart = pos
        guard let probe = swiftExpression(logical: false) else { throw Failure("expected an expression after 'async'") }
        pos = probe.end
        let slice = text.slice(exprStart..<probe.end)
        let source = slice.trimmingCharacters(in: .whitespaces)
        let cured = try cureSlice(slice, from: exprStart)
        _ = start
        let label = Reader.string(literal: source)
        if SwiftProbe.isParameterlessClosure(slice) { return "startTask(\(label)) \(cured)" }
        return "startTask(\(label)) { \(cured) }"
    }

    // MARK: Emission

    static func string(literal: String) -> String {
        var out = "\""
        for c in literal {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\0": out += "\\0"
            default: out.append(c)
            }
        }
        return out + "\""
    }

    func emit(_ chain: Chain, statement: Bool) -> String {
        let display = !chain.isCondition && chain.links.isEmpty && statement
        func status(_ operand: Operand) -> String {
            switch operand {
            case .command(let pipeline):
                if let kind = pipeline.throwing { return "\(kind.keyword) \(emit(pipeline)).check()" }
                return "\(emit(pipeline)).\(display ? "run" : "runQuietly")()"
            case .expression(let text):
                let value = operand.isOptionalAttempt ? "(\(text)) != nil" : text
                return "exitStatus(of: \(value))"
            }
        }
        // `exit 1` alone leaves the program, which a `guard` knows when it is a call that never returns.
        if chain.links.isEmpty, !chain.isCondition, case .command(let pipeline) = chain.first, pipeline.throwing == nil, pipeline.input == nil,
           pipeline.commands.count == 1, case .text(let pieces)? = pipeline.commands[0].words.first, pieces == [.literal("exit")] {
            return "exitShell(\(emit(pipeline)))"
        }
        var result = status(chain.first)
        for link in chain.links {
            result += ".\(link.isAnd ? "and" : "or") { \(status(link.operand)) }"
        }
        return chain.isCondition ? "(\(result)).succeeded" : result
    }

    func emit(_ pipeline: PipelineOut) -> String {
        let commands = pipeline.commands.map(emit)
        if commands.count == 1, pipeline.input == nil { return commands[0] }
        let input = pipeline.input.map { ["from: \($0)"] } ?? []
        return "Pipeline(\((input + commands).joined(separator: ", ")))"
    }

    func emit(_ command: CommandOut) -> String {
        var out = "Command(" + command.words.map { word in
            switch word {
            case .text(let pieces): emit(word: pieces)
            case .closure(let source): source
            }
        }.joined(separator: ", ") + ")"
        if command.external { out += ".external()" }
        if !command.environment.isEmpty {
            out += ".environment([" + command.environment.map { "\(Reader.string(literal: $0.name)): \(emit(text: $0.value))" }.joined(separator: ", ") + "])"
        }
        for redirect in command.redirects {
            switch redirect.target {
            case .file(let pieces, .read): out += ".reading(\(redirect.fd), from: \(emit(word: pieces)))"
            case .file(let pieces, .write): out += ".writing(\(redirect.fd), to: \(emit(word: pieces)))"
            case .file(let pieces, .append): out += ".appending(\(redirect.fd), to: \(emit(word: pieces)))"
            case .descriptor(let other): out += ".sending(\(redirect.fd), to: \(other))"
            }
        }
        if let call = command.call { out += ".calling((\(call)))" }
        return out
    }

    func emit(word pieces: [Piece]) -> String {
        if pieces.count == 1, case .spread(let value) = pieces[0] { return "Spread(\(value))" }
        guard pieces.contains(where: { if case .glob = $0 { true } else { false } }) else { return emit(text: pieces) }
        let pattern = pieces.map { piece -> Piece in
            switch piece {
            case .literal(let text): .literal(Glob.escape(text))
            case .glob(let text): .literal(text.replacingOccurrences(of: "?", with: "\\?"))
            case .expression(let value), .spread(let value): .expression("escapingWildcards(\"\\(\(value))\")")
            }
        }
        return "Glob(\(emit(text: pattern)))"
    }

    func emit(text pieces: [Piece]) -> String {
        var merged: [Piece] = []
        for piece in pieces {
            switch piece {
            case .literal(let t), .glob(let t):
                if case .literal(let before)? = merged.last {
                    merged[merged.count - 1] = .literal(before + t)
                } else {
                    merged.append(.literal(t))
                }
            case .expression(let v), .spread(let v): merged.append(.expression(v))
            }
        }
        if merged.isEmpty { return "\"\"" }
        var out = "\""
        for piece in merged {
            switch piece {
            case .literal(let t): out += String(Reader.string(literal: t).dropFirst().dropLast())
            case .expression(let v), .spread(let v): out += "\\(shellText(\(v)))"
            case .glob: break
            }
        }
        return out + "\""
    }
}
