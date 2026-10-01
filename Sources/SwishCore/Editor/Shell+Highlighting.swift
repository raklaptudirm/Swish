import Foundation
import SwishKit

extension Shell {
    // MARK: Highlighting

    /// An ANSI style for each character of `text`, from the parser's spans.
    /// Command names are green if they'd run something and red if not.
    func highlightStyles(_ text: String) -> [String?] {
        let characters = Array(text)
        var styles = [String?](repeating: nil, count: characters.count)
        // Longer spans first, so what's inside them (an interpolation in a
        // string) is painted over them.
        for span in Parser.highlight(text, bound: globalNames()).sorted(by: { $0.range.count > $1.range.count }) {
            let range = span.range.clamped(to: 0..<characters.count)
            let style: String? = switch span.kind {
            case .keyword, .punctuation: Style.keyword.escape
            case .command: commandStyle(String(characters[range]), piped: Shell.isPiped(characters, before: range.lowerBound))
            case .flag: Style.flag.escape
            case .string: Style.string.escape
            case .number, .constant: Style.constant.escape
            case .variable: Style.variable.escape
            case .comment: Style.comment.escape
            case .type: Style.type.escape
            }
            for index in range { styles[index] = style }
        }
        return styles
    }

    /// Whether the command starting at `index` comes after a `|`.
    private static func isPiped(_ characters: [Character], before index: Int) -> Bool {
        var before = index - 1
        while before >= 0, characters[before].isWhitespace { before -= 1 }
        return before >= 0 && characters[before] == "|" && (before == 0 || characters[before - 1] != "|")
    }

    private func commandStyle(_ word: String, piped: Bool) -> String? {
        let external = word.hasPrefix("^")
        let name = external ? String(word.dropFirst()) : word
        // Names built at run time can't be checked while typing.
        guard !name.isEmpty, !name.contains(where: { "$\\\"'(".contains($0) }) else { return nil }
        let known: Bool
        if !external && (commandFunctions(named: name) != nil || sequenceMethods[name] != nil
                         || Shell.builtinNames.contains(name)) {
            known = true
        } else if !external && piped && isMemberName(name) {
            // After a `|`, a method of what's piped in: which type's isn't
            // known while typing, so any type's will do.
            known = true
        } else if name.contains("/") {
            let path = name.hasPrefix("~") ? (env("HOME") ?? "") + name.dropFirst() : name
            known = FileManager.default.isExecutableFile(atPath: path)
        } else {
            known = executableNames().contains(name)
        }
        return (known ? Style.green : Style.red).escape
    }

    /// Names of programs on PATH, cached for a few seconds, since the
    /// highlighter asks on every keystroke.
    func executableNames() -> Set<String> {
        let path = env("PATH") ?? ""
        if let cache = executableCache, cache.path == path, Date().timeIntervalSince(cache.time) < 10 {
            return cache.names
        }
        var names: Set<String> = []
        for directory in path.split(separator: ":") {
            let directory = String(directory)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
                if access(directory + "/" + name, X_OK) == 0 { names.insert(name) }
            }
        }
        executableCache = (path, Date(), names)
        return names
    }
}
