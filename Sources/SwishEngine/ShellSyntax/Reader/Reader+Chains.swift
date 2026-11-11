import Foundation

// Commands joined by `&&` and `||`, with Swift between them or not.

extension Reader {
    /// Commands joined by `&&` and `||`, with Swift between them or not; nil (having looked ahead)
    /// when there is no command in it, which is Swift's.
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

    func swiftExpression(logical: Bool) -> SwiftProbe.Extent? {
        let probe = SwiftProbe.expression(
            in: blanked,
            at: pos,
            logical: logical,
            names: names,
            strictNames: false,
            inCondition: conditionDepth > 0
        )
        return probe.failure == nil ? probe : nil
    }

    /// `try cmd …` or `try! cmd …`, or nil (having looked ahead) when what follows the `try` is an
    /// expression.
    mutating func parseThrowingCommand() throws -> Pipeline? {
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

    /// Whether the unit ahead is a command rather than an expression: an expression if one parses
    /// there and the unit ends after it.
    mutating func commandAhead(boolIsCommand: Bool = false) -> UnitStart {
        let saved = self
        defer { self = saved }
        skipSpaces()
        guard let c = peek() else { return .expression }

        if c == "^" || (c == "$" && peek(1).map(Lex.isIdentifierStart) ?? false) {
            return .command(notAnExpression: nil)
        }

        // `'raw'` is a string, which Swift has no spelling of: an expression if it is the whole
        // unit.
        if c == "'", let close = chars[(pos + 1)...].firstIndex(of: "'") {
            pos = close + 1
            skipSpaces()
            return endsUnit() ? .expression : .command(notAnExpression: nil)
        }

        if let word = identifier() {
            let after = peek(word.count)
            if boolIsCommand && (word == "true" || word == "false")
                && after.map(isWordBoundary) ?? true
            {
                return .command(notAnExpression: nil)
            }
            if after == "(" { return .expression }
            if names.role(of: word, at: here) == .function {
                return after != "." && after != "[" ? .command(notAnExpression: nil) : .expression
            }
        }

        var wordEnd = pos
        while wordEnd < chars.count, !isWordBoundary(chars[wordEnd]) { wordEnd += 1 }

        let probe = SwiftProbe.expression(
            in: blanked,
            at: pos,
            logical: true,
            names: names,
            inCondition: conditionDepth > 0
        )

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
}
