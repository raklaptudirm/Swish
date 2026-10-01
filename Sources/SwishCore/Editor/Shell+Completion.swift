import Foundation
import SwishKit

extension Shell {
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
        } else if ["help", "which"].contains(context.words[0]) && context.quote == nil
                    && !word.hasPrefix("-") && !word.contains("/") {
            // `help <name>`: anything that runs, as for the first word.
            candidates = commandCandidates(prefix: word, externalOnly: false)
                .filter { !["variable", "keyword"].contains($0.description) }
        } else if word.hasPrefix("-") && context.quote == nil,
                  let functions = sequenceMethods[context.words[0]] ?? commandFunctions(named: context.words[0]) {
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
            for name in Shell.workingBuiltins { described[name] = "shell builtin" }
            for (name, set) in sequenceMethods {
                described[name] = set.candidates.first?.documentation.map { String($0.summary.prefix { $0 != "\n" }) } ?? "sequence method"
            }
            for keyword in ["if", "for", "while", "let", "var", "func", "async", "await", "do", "try", "enum", "switch", "import", "struct"] {
                described[keyword] = "keyword"
            }
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
            if " \t'\"\\$|;&(){}*[<>`".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
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
        // A command after `if`, `while`, `else` or `foreign`, or after
        // `NAME=value`, is still in command position.
        while let first = words.first, ["if", "while", "else", "foreign"].contains(first) || first.contains("=") {
            words.removeFirst()
        }
    }
}
