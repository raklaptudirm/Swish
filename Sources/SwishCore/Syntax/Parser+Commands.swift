import Foundation
import SwishKit

extension Parser {
    // MARK: Command mode

    mutating func parsePipeline(from start: Int? = nil, input: Expr? = nil) throws(SyntaxError) -> PipelineNode {
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

    mutating func parseCommand() throws(SyntaxError) -> CommandNode {
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
        var call: [Argument]?
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
            // `sorted(by: "size")`: a name touching its arguments is a call,
            // as in Swift; a trailing closure may follow.
            if c == "(", words.count == 1, call == nil, !external, pos > 0, Parser.isIdentifierPart(chars[pos - 1]) {
                call = try parseArguments()
                skipSpaces()
                if peek() == "{" {
                    pos += 1
                    call!.append(Argument(label: nil, value: .closure(try parseClosure())))
                }
                continue
            }
            if c == "(" {
                throw SyntaxError("unexpected '(' in a command; quote it, or use \\(…) to interpolate an expression")
            }
            if call != nil {
                throw SyntaxError("a command written as a call takes all its arguments in the parentheses")
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
                // A command's name may be a function the body calls.
                if word.count == 1, case .literal(let name) = word[0] { use(name) }
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
        return CommandNode(words: words, external: external, redirects: redirects, environment: environment, call: call)
    }

    /// A redirect at the current position, or nil if there isn't one:
    /// `> file`, `>> file` and `< file` for standard output and input;
    /// `e>` and `e>>` for standard error; `o+e>` and `o+e>>` for both; `e>o`
    /// sends standard error wherever standard output goes, and `o>e` the
    /// other way. POSIX forms like `2>&1` are an error naming the new one.
    mutating func parseRedirect() throws(SyntaxError) -> [Redirect]? {
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
    func rejectPosixRedirect() throws(SyntaxError) {
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

    func endsCommand(_ c: Character) -> Bool {
        switch c {
        case "|", ";", "\n", ")", "}": true
        case "&": peek(1) == "&"
        case "{": peek(1) != "}" && conditionDepth > 0
        // `guard test -d x else { … }`: `else` isn't the command's.
        case "e": guardCondition && identifier() == "else" && (pos == 0 || isWordBoundary(chars[pos - 1]))
        default: false
        }
    }

    func isWordBoundary(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || "|;&(){}<>".contains(c)
    }

    mutating func parseWord() throws(SyntaxError) -> [WordPart] {
        var parts: [WordPart] = []
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
                parts += try parseInterpolatedString(dollar: true).map(WordPart.init)
            case "\\":
                guard let next = peek(1) else { throw .incomplete("expected a character after '\\'") }
                if next == "(" {
                    flush()
                    parts.append(.spread(try parseInterpolation()))
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
}
