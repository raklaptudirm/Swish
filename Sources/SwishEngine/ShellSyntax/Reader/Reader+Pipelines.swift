import Foundation

// Pipelines of commands, and the words of a single command.

extension Reader {
    mutating func parsePipeline(from start: Int? = nil, input: String? = nil) throws -> Pipeline {
        let start = start ?? pos
        var commands = [try parseCommand()]
        // A method with nothing piped in, and no function or program by that name, has nothing to
        // work on.
        if input == nil, !commands[0].external, case .text(let pieces)? = commands[0].words.first,
            pieces.count == 1,
            case .literal(let name) = pieces[0],
            names.role(of: name, at: here) != .function, front.isMethodWithoutInput(name)
        {
            throw Failure(
                "\(name) is a method: pipe something into it, as in `ls | \(name)`, or call it on a value, as in `xs.\(name)(…)`"
            )
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
        for (index, command) in commands.enumerated()
        where !command.external && command.call == nil && command.redirects.isEmpty {
            guard case .text(let first)? = command.words.first, first.count == 1,
                case .literal(let name) = first[0]
            else { continue }
            var words: [String] = []
            for word in command.words.dropFirst() {
                guard case .text(let pieces) = word,
                    pieces.allSatisfy({ if case .literal = $0 { true } else { false } })
                else { words = []; break }
                words.append(pieces.map { if case .literal(let t) = $0 { t } else { "" } }.joined())
            }
            if command.words.count - 1 == words.count {
                front.record(
                    use: Front.CommandUse(
                        name: name,
                        words: words,
                        piped: index > 0 || input != nil,
                        source: source
                    )
                )
            }
        }
        return Pipeline(commands: commands, source: source, input: input, throwing: nil)
    }

    mutating func parseCommand() throws -> Command {
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
        var command = Command(words: [], external: external)
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
            // `sorted(by: "size")`: a name touching its arguments is a call; a trailing closure may
            // follow.
            if c == "(", command.words.count == 1, command.call == nil, !external, pos > 0,
                Lex.isIdentifierPart(chars[pos - 1])
            {
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
                throw Failure(
                    "unexpected '(' in a command; quote it, or use \\(…) to interpolate an expression"
                )
            }
            if command.call != nil {
                throw Failure(
                    "a command written as a call takes all its arguments in the parentheses"
                )
            }
            if c == "&" {
                throw Failure("'&' isn't Swish; background jobs will be `async command`")
            }
            // `NAME=value` before the command sets it for the command.
            if command.words.isEmpty, let name = identifier(), peek(name.count) == "=",
                peek(name.count + 1) != "="
            {
                mark(.variable, from: pos, to: pos + name.count)
                pos += name.count + 1
                let value = peek().map(isWordBoundary) ?? true ? [.literal("")] : try parseWord()
                command.environment.append((name: name, value: value))
                continue
            }
            let wordStart = pos
            let word = try parseWord()
            if command.words.isEmpty {
                mark(
                    .command,
                    from: command.redirects.isEmpty && command.environment.isEmpty
                        ? caretStart ?? wordStart : wordStart
                )
            } else if chars[wordStart] == "-" {
                mark(.flag, from: wordStart)
            }
            command.words.append(.text(word))
        }
        guard !command.words.isEmpty else {
            if let assignment = command.environment.first {
                throw Failure(
                    "\(assignment.name)=… sets a variable for one command; use env.\(assignment.name) = … to set it for the session"
                )
            }
            if let c = peek() {
                throw Failure(c == "\n" ? "unexpected newline" : "unexpected '\(c)'")
            }
            throw Failure.incomplete("expected a command")
        }
        return command
    }

    func endsCommand(_ c: Character) -> Bool {
        switch c {
        case "|", ";", "\n", ")", "}": true
        case "&": peek(1) == "&"
        case "{": peek(1) != "}" && conditionDepth > 0
        case "e":
            guardCondition && identifier() == "else" && (pos == 0 || isWordBoundary(chars[pos - 1]))
        default: false
        }
    }
}
