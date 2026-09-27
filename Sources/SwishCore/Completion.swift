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
            case .keyword, .punctuation: "\u{1B}[35m"
            case .command: commandStyle(String(characters[range]))
            case .flag: "\u{1B}[34m"
            case .string: "\u{1B}[33m"
            case .number, .constant: "\u{1B}[95m"
            case .variable: "\u{1B}[36m"
            case .comment: "\u{1B}[90m"
            case .type: "\u{1B}[93m"
            }
            for index in range { styles[index] = style }
        }
        return styles
    }

    private func commandStyle(_ word: String) -> String? {
        let external = word.hasPrefix("^")
        let name = external ? String(word.dropFirst()) : word
        // Names built at run time can't be checked while typing.
        guard !name.isEmpty, !name.contains(where: { "$\\\"'(".contains($0) }) else { return nil }
        let known: Bool
        if !external && (commandFunctions(named: name) != nil || Shell.builtinNames.contains(name)) {
            known = true
        } else if name.contains("/") {
            let path = name.hasPrefix("~") ? (env("HOME") ?? "") + name.dropFirst() : name
            known = FileManager.default.isExecutableFile(atPath: path)
        } else {
            known = executableNames().contains(name)
        }
        return known ? "\u{1B}[32m" : "\u{1B}[31m"
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

    // MARK: Completion

    /// Completions for the word before `cursor`: commands where a command
    /// name goes, a function's flags (from its signature) after a `-`,
    /// variables after a `$`, and paths otherwise.
    func completions(for text: String, cursor: Int) -> LineEditor.Completion? {
        let context = CompletionContext(scanning: Array(text)[..<cursor])
        let word = context.current
        var candidates: [LineEditor.Candidate]

        if word.hasPrefix("$") && context.quote != "'" {
            candidates = variableCandidates(prefix: String(word.dropFirst()))
        } else if context.words.isEmpty && context.quote == nil {
            let external = word.hasPrefix("^")
            let name = external ? String(word.dropFirst()) : word
            candidates = name.contains("/")
                ? pathCandidates(for: name, quote: nil, executablesOnly: true)
                : commandCandidates(prefix: name, externalOnly: external)
            if external {
                candidates = candidates.map { var candidate = $0; candidate.replacement = "^" + candidate.replacement; return candidate }
            }
        } else if word.hasPrefix("-") && context.quote == nil, let functions = commandFunctions(named: context.words[0]) {
            candidates = flagCandidates(for: functions, prefix: word)
        } else {
            candidates = pathCandidates(for: word, quote: context.quote, executablesOnly: false)
        }
        return LineEditor.Completion(start: context.start, candidates: candidates)
    }

    private func variableCandidates(prefix: String) -> [LineEditor.Candidate] {
        var names = Set(ProcessInfo.processInfo.environment.keys)
        for scope in scopes {
            for (name, binding) in scope.bindings where !binding.isFunction { names.insert(name) }
        }
        return names.filter { $0.hasPrefix(prefix) }.sorted().map {
            LineEditor.Candidate(replacement: "$" + $0, suffix: "", display: "$" + $0)
        }
    }

    private func commandCandidates(prefix: String, externalOnly: Bool) -> [LineEditor.Candidate] {
        var described: [String: String] = [:]
        if !externalOnly {
            for scope in scopes {
                for (name, binding) in scope.bindings {
                    guard binding.isFunction, case .function(let set as OverloadSet) = binding.value else {
                        described[name] = "variable"
                        continue
                    }
                    let summary = set.candidates.compactMap { $0.documentation?.summary }.first { !$0.isEmpty }
                    described[name] = summary.map { String($0.prefix { $0 != "\n" }) } ?? "function"
                }
            }
            for name in Shell.builtinNames { described[name] = "shell builtin" }
            for keyword in ["if", "for", "while", "let", "var", "func"] { described[keyword] = "keyword" }
        }
        var candidates: [String: LineEditor.Candidate] = [:]
        for name in executableNames() where name.hasPrefix(prefix) {
            candidates[name] = LineEditor.Candidate(replacement: escaped(name), display: name)
        }
        for (name, description) in described where name.hasPrefix(prefix) {
            candidates[name] = LineEditor.Candidate(replacement: escaped(name), display: name, description: description)
        }
        return candidates.keys.sorted().map { candidates[$0]! }
    }

    private func flagCandidates(for set: OverloadSet, prefix: String) -> [LineEditor.Candidate] {
        var candidates: [String: LineEditor.Candidate] = [:]
        func add(_ flag: String, _ description: String) {
            guard flag.hasPrefix(prefix), candidates[flag] == nil else { return }
            candidates[flag] = LineEditor.Candidate(replacement: flag, display: flag, description: description)
        }
        for function in set.candidates {
            for parameter in function.parameters {
                guard let label = parameter.label else { continue }
                let help = function.documentation?.parameters[parameter.name]
                let description = help ?? (parameter.type == .bool ? "switch" : "<\(parameter.type)>")
                if parameter.type == .bool, parameter.defaultValue == .literal(.bool(true)) {
                    add("--no-" + kebabCase(label), description)
                }
                add("--" + kebabCase(label), description)
                if let short = parameter.shortFlag { add("-\(short)", description) }
            }
        }
        if !helpClaimed(by: set) {
            add("--help", "show help")
        }
        return candidates.keys.sorted().map { candidates[$0]! }
    }

    private func pathCandidates(for word: String, quote: Character?, executablesOnly: Bool) -> [LineEditor.Candidate] {
        let home = env("HOME") ?? "~"
        let expanded = word.hasPrefix("~") ? home + word.dropFirst() : word
        let typedDirectory = word.lastIndex(of: "/").map { String(word[...$0]) } ?? ""
        let directory = expanded.lastIndex(of: "/").map { String(expanded[...$0]) } ?? ""
        let partial = expanded.lastIndex(of: "/").map { String(expanded[expanded.index(after: $0)...]) } ?? expanded
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.isEmpty ? "." : directory)) ?? []

        var candidates: [LineEditor.Candidate] = []
        for name in names.sorted() where name.hasPrefix(partial) && (partial.hasPrefix(".") || !name.hasPrefix(".")) {
            var isDirectory: ObjCBool = false
            let path = directory + name
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if executablesOnly && !isDirectory.boolValue && !FileManager.default.isExecutableFile(atPath: path) { continue }
            let text = typedDirectory + name
            let replacement = quote.map { String($0) + text } ?? escaped(text)
            let suffix = isDirectory.boolValue ? "/" : quote.map { String($0) + " " } ?? " "
            candidates.append(LineEditor.Candidate(replacement: replacement, suffix: suffix, display: name + (isDirectory.boolValue ? "/" : "")))
        }
        return candidates
    }

    /// Backslash-escapes what command mode would otherwise read specially.
    private func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            if " \t'\"\\$|;&(){}#*[<>`".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Names the parser should know: builtins and globals, as variables or functions.
    func globalNames() -> [String: NameKind] {
        scopes[0].bindings.merging(scopes[1].bindings) { $1 }
            .mapValues { $0.isFunction ? NameKind.function : .variable }
    }
}

/// The command being typed, up to the cursor: the words before the one
/// being completed, and that word's start and (unescaped) text so far.
private struct CompletionContext {
    var words: [String] = []
    var start: Int
    var current = ""
    var quote: Character?

    init(scanning characters: ArraySlice<Character>) {
        var wordStart: Int?
        var index = characters.startIndex
        while index < characters.endIndex {
            let character = characters[index]
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                index += 1
                continue
            }
            switch character {
            case " ", "\t", "<", ">":
                if wordStart != nil { words.append(current) }
                current = ""
                wordStart = nil
            case "|", ";", "\n", "{", "}", "(", ")", "&":
                // A new command starts.
                words = []
                current = ""
                wordStart = nil
            case "'", "\"":
                if wordStart == nil { wordStart = index }
                quote = character
            case "\\":
                if wordStart == nil { wordStart = index }
                if index + 1 < characters.endIndex {
                    current.append(characters[index + 1])
                    index += 1
                }
            default:
                if wordStart == nil { wordStart = index }
                current.append(character)
            }
            index += 1
        }
        start = wordStart ?? characters.endIndex
        // A command after `if`, `while` or `else` is still in command position.
        while let first = words.first, ["if", "while", "else"].contains(first) { words.removeFirst() }
    }
}
