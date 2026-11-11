import Foundation

// `async …`: a command or a block started as a job.

extension Reader {
    mutating func parseAsync() throws -> String {
        let start = pos
        mark(.keyword, from: pos, to: pos + "async".count)
        pos += "async".count
        skipSpaces()

        if peek() == "$" && peek(1) == "(" {
            let open = pos
            mark(.punctuation, from: open, to: open + 2)
            guard let close = Lex.closing(chars, from: pos + 1) else {
                throw Failure.incomplete("expected ')'")
            }
            let inner = text.slice((open + 2)..<close)
            mark(.punctuation, from: close, to: close + 1)
            pos = close + 1
            var reader = Reader(
                front: front,
                text: Text(inner),
                blanked: Text(Lex.blankingSubstitutions(Array(inner))),
                names: names.snapshot(atByte: here),
                at: 0
            )
            defer {
                for span in reader.spans {
                    spans.append(
                        HighlightSpan(
                            range: (span.range.lowerBound + open + 2)..<(span.range.upperBound
                                + open + 2),
                            kind: span.kind
                        )
                    )
                }
            }
            guard let chain = try reader.parseCommandChain(condition: false), chain.links.isEmpty,
                case .command(let pipeline) = chain.first
            else {
                throw Failure("async $(…) runs one pipeline of commands")
            }
            return "\(emit(pipeline)).startCapturing()"
        }

        guard peek() != nil else {
            throw Failure.incomplete("expected a command or an expression after 'async'")
        }

        if commandAhead(boolIsCommand: true).isCommand {
            return "\(emit(try parsePipeline())).start()"
        }

        // `async f(x)`, `async { … }`: Swish code, as a task of its own.
        let exprStart = pos
        guard let probe = swiftExpression(logical: false) else {
            throw Failure("expected an expression after 'async'")
        }
        pos = probe.end
        let slice = text.slice(exprStart..<probe.end)
        let source = slice.trimmingCharacters(in: .whitespaces)
        let cured = try cureSlice(slice, from: exprStart)
        _ = start
        let label = Reader.string(literal: source)
        if SwiftProbe.isParameterlessClosure(slice) { return "startTask(\(label)) \(cured)" }
        return "startTask(\(label)) { \(cured) }"
    }
}
