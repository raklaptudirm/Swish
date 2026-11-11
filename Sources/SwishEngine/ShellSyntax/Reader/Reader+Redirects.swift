import Foundation

// Redirections (`>`, `>>`, `<`, `e>` and the rest), and the POSIX forms it refuses.

extension Reader {
    mutating func parseRedirect() throws -> [Redirect]? {
        let start = pos
        try rejectPosixRedirect()
        func touchesBoundary(after count: Int) -> Bool { peek(count).map(isWordBoundary) ?? true }
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
        let mode: Redirect.Mode = fds == [0] ? .read : append ? .append : .write
        if fds == [1, 2] {
            return [
                Redirect(fd: 1, target: .file(file, mode)),
                Redirect(fd: 2, target: .descriptor(1)),
            ]
        }
        return [Redirect(fd: fds[0], target: .file(file, mode))]
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
            throw Failure(
                "numbered descriptors like \(number)\(rest.prefix(1)) aren't part of Swish; redirect with >, e>, e>o, o>e or o+e>"
            )
        default: swish = nil
        }
        if let swish { throw Failure("that's a POSIX redirect; in Swish it's \(swish)") }
    }
}
