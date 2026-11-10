import Foundation

// What the reader gives back: the Swift each form means.

extension Reader {
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
                if let kind = pipeline.throwing {
                    return "\(kind.keyword) \(emit(pipeline)).check()"
                }
                return "\(emit(pipeline)).\(display ? "run" : "runQuietly")()"
            case .expression(let text):
                let value = operand.isOptionalAttempt ? "(\(text)) != nil" : text
                return "exitStatus(of: \(value))"
            }
        }
        // `exit 1` alone leaves the program, which a `guard` knows when it is a call that never
        // returns.
        if chain.links.isEmpty, !chain.isCondition, case .command(let pipeline) = chain.first,
            pipeline.throwing == nil,
            pipeline.input == nil,
            pipeline.commands.count == 1,
            case .text(let pieces)? = pipeline.commands[0].words.first,
            pieces == [.literal("exit")]
        {
            return "exitShell(\(emit(pipeline)))"
        }
        var result = status(chain.first)
        for link in chain.links {
            result += ".\(link.isAnd ? "and" : "or") { \(status(link.operand)) }"
        }
        return chain.isCondition ? "(\(result)).succeeded" : result
    }

    func emit(_ pipeline: Pipeline) -> String {
        let commands = pipeline.commands.map(emit)
        if commands.count == 1, pipeline.input == nil { return commands[0] }
        let input = pipeline.input.map { ["from: \($0)"] } ?? []
        return "Pipeline(\((input + commands).joined(separator: ", ")))"
    }

    func emit(_ command: Command) -> String {
        var out =
            "Command("
            + command.words
            .map { word in
                switch word {
                case .text(let pieces): emit(word: pieces)
                case .closure(let source): source
                }
            }
            .joined(separator: ", ") + ")"
        if command.external { out += ".external()" }
        if !command.environment.isEmpty {
            out +=
                ".environment(["
                + command.environment
                .map { "\(Reader.string(literal: $0.name)): \(emit(text: $0.value))" }
                .joined(separator: ", ") + "])"
        }
        for redirect in command.redirects {
            switch redirect.target {
            case .file(let pieces, .read):
                out += ".reading(\(redirect.fd), from: \(emit(word: pieces)))"
            case .file(let pieces, .write):
                out += ".writing(\(redirect.fd), to: \(emit(word: pieces)))"
            case .file(let pieces, .append):
                out += ".appending(\(redirect.fd), to: \(emit(word: pieces)))"
            case .descriptor(let other): out += ".sending(\(redirect.fd), to: \(other))"
            }
        }
        if let call = command.call { out += ".calling((\(call)))" }
        return out
    }

    func emit(word pieces: [Piece]) -> String {
        if pieces.count == 1, case .spread(let value) = pieces[0] { return "Spread(\(value))" }
        guard pieces.contains(where: { if case .glob = $0 { true } else { false } }) else {
            return emit(text: pieces)
        }
        let pattern = pieces.map { piece -> Piece in
            switch piece {
            case .literal(let text): .literal(Glob.escape(text))
            case .glob(let text): .literal(text.replacingOccurrences(of: "?", with: "\\?"))
            case .expression(let value), .spread(let value):
                .expression("escapingWildcards(\"\\(\(value))\")")
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
