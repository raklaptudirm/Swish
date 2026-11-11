import Foundation
import Swiit

extension Shell {
    // MARK: Highlighting

    /// What each stretch of `text` is, from the parser's spans. A command word is `.command` if it
    /// would run something and `.unknownCommand` if not; one built at run time can't be told while
    /// typing, and has no span.
    public func highlighting(of text: String) -> [HighlightSpan] {
        let characters = Array(text)
        return highlightSpans(text)
            .compactMap { span in
                guard span.kind == .command else { return span }
                let range = span.range.clamped(to: 0..<characters.count)
                let piped = Shell.isPiped(characters, before: range.lowerBound)
                guard let known = isKnownCommand(String(characters[range]), piped: piped) else {
                    return nil
                }
                return HighlightSpan(range: span.range, kind: known ? .command : .unknownCommand)
            }
    }

    /// An ANSI style for each character of `text`, from `highlighting(of:)`.
    func highlightStyles(_ text: String) -> [String?] {
        highlighting(of: text).paintedStyles(count: text.count).map { $0?.escape }
    }

    /// Whether the command starting at `index` comes after a `|`.
    private static func isPiped(_ characters: [Character], before index: Int) -> Bool {
        var before = index - 1
        while before >= 0, characters[before].isWhitespace { before -= 1 }
        return before >= 0 && characters[before] == "|"
            && (before == 0 || characters[before - 1] != "|")
    }

    /// Whether `word` names something that would run, or nil when it is built at run time.
    private func isKnownCommand(_ word: String, piped: Bool) -> Bool? {
        let external = word.hasPrefix("^")
        let name = external ? String(word.dropFirst()) : word
        // Names built at run time can't be checked while typing.
        guard !name.isEmpty, !name.contains(where: { "$\\\"'(".contains($0) }) else { return nil }
        if !external
            && (runner.commandFunctions(named: name) != nil
                || runner.stageNames.sequence.contains(name)
                || runner.stageNames.streams.contains(name)
                || builtins[name] != nil)
        {
            return true
        }
        if !external && piped && runner.isMemberName(name) {
            // After a `|`, a method of what's piped in: which type's isn't
            // known while typing, so any type's will do.
            return true
        }
        if name.contains("/") {
            let path = name.hasPrefix("~") ? (env("HOME") ?? "") + name.dropFirst() : name
            return FileManager.default.isExecutableFile(atPath: path)
        }
        return executableNames().contains(name)
    }

    /// Names of programs on PATH, cached for a few seconds, since the
    /// highlighter asks on every keystroke.
    func executableNames() -> Set<String> {
        let path = env("PATH") ?? ""
        if let cache = programKnowledge.executableCache, cache.path == path,
            Date().timeIntervalSince(cache.time) < 10
        {
            return cache.names
        }
        var names: Set<String> = []
        for directory in path.split(separator: ":") {
            let directory = String(directory)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
                if access(directory + "/" + name, X_OK) == 0 { names.insert(name) }
            }
        }
        programKnowledge.executableCache = (path, Date(), names)
        return names
    }
}
