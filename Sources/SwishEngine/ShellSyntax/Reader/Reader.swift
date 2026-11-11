import Foundation

/// The shell's grammar, read by the shell. A `Reader` stands on the text of one source at the start
/// of a form of the shell's (a command, a pipeline, `$(…)`, `$name`, `async …`) and reads it as
/// characters; where the form holds Swift (an argument, `\(…)`, a closure, the program in `$(…)`) it
/// finds the extent with the lexical scanner and has the front end cure that text in turn. What it
/// gives back is Swift: the form as the calls it means, which a plain Swift front end reads.
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
        "let", "var", "func", "return", "break", "continue", "do", "catch", "enum", "fallthrough",
        "import", "struct",
        "defer", "guard", "throw", "repeat",
        "class", "actor", "protocol", "extension", "typealias",
    ]
    /// What can come before a declaration's keyword (`final class`, `private func`).
    static let declarationModifiers: Set<String> = [
        "final", "public", "private", "fileprivate", "internal", "open", "indirect",
    ]

    /// The identifier that follows the word at the reader, after spaces.
    func wordAfter(_ word: String) -> String? {
        var offset = word.count
        while peek(offset) == " " || peek(offset) == "\t" { offset += 1 }
        guard let first = peek(offset), Lex.isIdentifierStart(first) else { return nil }
        var name = String(first)
        while let c = peek(offset + name.count), Lex.isIdentifierPart(c) { name.append(c) }
        return name
    }

    /// The keywords a line can begin with: a statement's, a unit's (`if make { … }`), or an
    /// expression's (`await job`). Completion offers them where a command could go.
    static let lineStarts = statementKeywords.subtracting(["catch"])
        .union(["if", "for", "while", "switch", "try", "async", "await"])
    /// The words a command can follow directly and still be in command position.
    static let beforeCommand: Set<String> = ["if", "while", "else", "foreign"]
    static let reservedStarts = statementKeywords.union([
        "if", "for", "while", "switch", "else", "case", "default", "in",
    ])
}
