public enum Token: Equatable, Sendable {
    case word(String)
    case pipe
}

public struct SyntaxError: Error, Equatable, CustomStringConvertible {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}

public struct Command: Equatable, Sendable {
    public var argv: [String]
}

public struct Pipeline: Equatable, Sendable {
    public var commands: [Command]
}

/// Splits a command line into words and pipes, applying quoting, backslash
/// escapes, comments, and tilde expansion.
public func tokenize(_ input: String, home: String) throws(SyntaxError) -> [Token] {
    let chars = Array(input)
    var tokens: [Token] = []
    var word = ""
    // Tracked separately from `word` so that `""` yields an empty word.
    var inWord = false

    func flush() {
        if inWord { tokens.append(.word(word)) }
        word = ""
        inWord = false
    }

    func endsWord(_ index: Int) -> Bool {
        index == chars.count || chars[index] == "/" || chars[index] == "|" || chars[index].isWhitespace
    }

    var i = 0
    while i < chars.count {
        let c = chars[i]
        switch c {
        case _ where c.isWhitespace:
            flush()
        case "|":
            flush()
            tokens.append(.pipe)
        case "#" where !inWord:
            i = chars.count
            continue
        case "~" where !inWord && endsWord(i + 1):
            word = home
            inWord = true
        case "'":
            guard let end = chars[(i + 1)...].firstIndex(of: "'") else {
                throw SyntaxError("unterminated single quote")
            }
            word += String(chars[(i + 1)..<end])
            inWord = true
            i = end
        case "\"":
            inWord = true
            i += 1
            while true {
                guard i < chars.count else { throw SyntaxError("unterminated double quote") }
                let d = chars[i]
                if d == "\"" { break }
                if d == "\\", i + 1 < chars.count, "\"\\$`".contains(chars[i + 1]) {
                    word.append(chars[i + 1])
                    i += 2
                    continue
                }
                word.append(d)
                i += 1
            }
        case "\\":
            guard i + 1 < chars.count else { throw SyntaxError("trailing backslash") }
            word.append(chars[i + 1])
            inWord = true
            i += 1
        default:
            word.append(c)
            inWord = true
        }
        i += 1
    }
    flush()
    return tokens
}

/// Groups tokens into a pipeline, or returns nil for a blank line.
public func parse(_ tokens: [Token]) throws(SyntaxError) -> Pipeline? {
    guard !tokens.isEmpty else { return nil }
    var commands: [Command] = []
    var argv: [String] = []
    for token in tokens {
        switch token {
        case .word(let word):
            argv.append(word)
        case .pipe:
            guard !argv.isEmpty else { throw SyntaxError("unexpected '|'") }
            commands.append(Command(argv: argv))
            argv = []
        }
    }
    guard !argv.isEmpty else { throw SyntaxError("expected a command after '|'") }
    commands.append(Command(argv: argv))
    return Pipeline(commands: commands)
}
