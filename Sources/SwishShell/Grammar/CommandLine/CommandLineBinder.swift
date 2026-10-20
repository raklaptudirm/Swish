import Swiit
import Foundation

// A command line bound to a declaration's parameters: which overload the words
// mean, and what each parameter is given. It looks at parameters and words
// alone, with no function, value or scope, so the checker binds a call to a
// function the program has only just declared as the runtime binds one it is
// about to run; the runtime then makes the values from what was decided
// (`Shell.bind(commandLine:)`).

/// A word of a command, as binding sees it.
enum CommandWordShape {
    case text(String)
    /// `where { … }`: a closure, whose type isn't known until the parameter it binds is.
    case closure
}

/// What a command line gave each parameter of the overload it chose.
struct CommandLineBinding {
    /// A word a parameter took, and the text it took from it (a flag's inline value is part of the flag's word).
    struct Piece { var word: Int; var text: String? }

    enum Assigned {
        /// Words: a positional, a flag's value, or the rest for a variadic or a collection.
        case words([Piece])
        /// A switch: `--verbose` is true, `--no-verbose` false.
        case flag(Bool)
        /// Not given, and the parameter has a default to fill in.
        case defaulted
        /// Not given, and it needs none: a switch is off, a collection empty, an optional nil.
        case omitted
    }

    /// The overload chosen, as a position among the signatures given.
    var overload: Int
    var assigned: [String: Assigned]
    var penalty: Int

    /// The words a parameter took.
    func pieces(of parameter: String) -> [Piece] {
        if case .words(let pieces)? = assigned[parameter] { pieces } else { [] }
    }
}

extension Shell {
    /// Whether the shell answers `--help` or `-h` for these overloads, as it does unless one claims them.
    func helpRequested(_ words: [CommandWordShape], for callee: Callee) -> Bool {
        guard !callee.parameters.contains(where: { $0.contains { $0.label == "help" || $0.shortFlag == "h" } }) else { return false }
        for case .text(let arg) in words {
            if arg == "--" { return false }
            if arg == "--help" || arg == "-h" { return true }
        }
        return false
    }

    /// Picks the overload the words bind to with the lowest penalty, as a call by its arguments does.
    func bindCommandLine(
        _ words: [CommandWordShape], to callee: Callee, excludingInput: Bool
    ) throws -> CommandLineBinding {
        let name = callee.label
        let overloads = callee.parameters
        if overloads.count == 1 {
            return try bindWords(words, to: overloads[0], overload: 0, name: name, excludingInput: excludingInput)
        }
        var matches: [CommandLineBinding] = []
        for (position, parameters) in overloads.enumerated() {
            do {
                matches.append(try bindWords(words, to: parameters, overload: position, name: name, excludingInput: excludingInput))
            } catch is RuntimeError {
                continue
            }
        }
        func rendered(_ symbol: Symbol) -> String { "  " + signature(of: symbol) }
        guard let best = matches.map(\.penalty).min() else {
            throw RuntimeError("\(name): no overload accepts these arguments; candidates:\n" + callee.overloads.map(rendered).joined(separator: "\n"))
        }
        var bestMatches = matches.filter { $0.penalty == best }
        if bestMatches.count > 1 {
            // Of equals, a function that takes a type itself beats one that takes anything, as in Swift.
            let generic = { (match: CommandLineBinding) in overloads[match.overload].filter { $0.type.isUnknown }.count }
            let fewest = bestMatches.map(generic).min()!
            bestMatches = bestMatches.filter { generic($0) == fewest }
        }
        guard bestMatches.count == 1 else {
            throw RuntimeError("\(name): ambiguous call; these overloads all match:\n" + bestMatches.map { rendered(callee.overloads[$0.overload]) }.joined(separator: "\n"))
        }
        return bestMatches[0]
    }

    /// `bind(commandLine:to:excludingInput:)`, deciding and not making: the same flags, positionals, collections and errors.
    func bindWords(
        _ words: [CommandWordShape], to allParameters: [CommandParameter], overload: Int, name: String,
        excludingInput: Bool
    ) throws -> CommandLineBinding {
        let parameters = allParameters.filter { !(excludingInput && $0.isInput) }
        var longFlags: [String: (parameter: CommandParameter, negated: Bool)] = [:]
        var shortFlags: [Character: CommandParameter] = [:]
        for parameter in parameters {
            guard let label = parameter.label else { continue }
            longFlags[kebabCase(label)] = (parameter, false)
            if parameter.type.isBool, parameter.defaultValue == Value(true) {
                longFlags["no-" + kebabCase(label)] = (parameter, true)
            }
            if let flag = parameter.shortFlag { shortFlags[flag] = parameter }
        }

        typealias Piece = CommandLineBinding.Piece
        var bound: [String: CommandLineBinding.Assigned] = [:]
        var penalty = 0
        /// A word taken as a value of `type`: whether it can be, and what it costs.
        func take(_ word: Int, text: String?, as type: ValueType, for what: String) throws -> Piece {
            if let text {
                if type == .string || type == .any { penalty += 1 }
                _ = try converted(text, to: type, for: what, of: name)
            } else if !type.acceptsFunction {
                throw RuntimeError("\(name): \(what) must be \(type), not Function")
            }
            return Piece(word: word, text: text)
        }
        var collected: [String: [Piece]] = [:]
        func assign(_ parameter: CommandParameter, word: Int, text: String?, flag: String) throws {
            if let (element, _) = Shell.collection(parameter.type) {
                collected[parameter.name, default: []].append(try take(word, text: text, as: element, for: flag))
            } else {
                guard bound[parameter.name] == nil else { throw RuntimeError("\(name): \(flag) given twice") }
                bound[parameter.name] = .words([try take(word, text: text, as: parameter.type, for: flag)])
            }
        }
        func textOf(_ index: Int) -> String? {
            if case .text(let text) = words[index] { text } else { nil }
        }

        var positionals: [Int] = []
        var index = 0
        var flagsEnded = false
        while index < words.count {
            let position = index
            index += 1
            guard let arg = textOf(position), !flagsEnded, arg.hasPrefix("-"), arg != "-" else {
                positionals.append(position)
                continue
            }
            if arg == "--" {
                flagsEnded = true
                continue
            }
            if arg.hasPrefix("--") {
                let body = arg.dropFirst(2)
                let flagName = String(body.prefix { $0 != "=" })
                let inline = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
                guard let (parameter, negated) = longFlags[flagName] else {
                    throw RuntimeError("\(name): unknown option --\(flagName)" + programHint(name))
                }
                if parameter.type.isBool && (inline == nil || negated) {
                    guard inline == nil else { throw RuntimeError("\(name): --\(flagName) doesn't take a value") }
                    if !negated, index < words.count, let next = textOf(index),
                       (try? converted(next, to: parameter.type, for: "", of: name)) != nil {
                        bound[parameter.name] = .words([Piece(word: index, text: next)])
                        index += 1
                    } else {
                        bound[parameter.name] = .flag(!negated)
                    }
                } else if let inline {
                    try assign(parameter, word: position, text: inline, flag: "--\(flagName)")
                } else {
                    guard index < words.count else { throw RuntimeError("\(name): --\(flagName) needs a value") }
                    try assign(parameter, word: index, text: textOf(index), flag: "--\(flagName)")
                    index += 1
                }
                continue
            }
            let letters = Array(arg.dropFirst())
            if shortFlags[letters[0]] == nil, Double(arg) != nil {
                positionals.append(position)
                continue
            }
            var cursor = 0
            while cursor < letters.count {
                let letter = letters[cursor]
                guard let parameter = shortFlags[letter] else {
                    throw RuntimeError("\(name): unknown option -\(letter)\(letters.count > 1 ? " in \(arg)" : "")" + programHint(name))
                }
                cursor += 1
                if parameter.type.isBool {
                    bound[parameter.name] = .flag(true)
                    continue
                }
                var value = String(letters[cursor...])
                if value.hasPrefix("=") { value.removeFirst() }
                if value.isEmpty {
                    guard index < words.count else { throw RuntimeError("\(name): -\(letter) needs a value") }
                    try assign(parameter, word: index, text: textOf(index), flag: "-\(letter)")
                    index += 1
                } else {
                    try assign(parameter, word: position, text: value, flag: "-\(letter)")
                }
                break
            }
        }

        var remaining = positionals[...]
        for parameter in parameters where parameter.label == nil {
            let what = "<\(parameter.name)>"
            if parameter.isVariadic {
                bound[parameter.name] = .words(try remaining.map { try take($0, text: textOf($0), as: parameter.type, for: what) })
                remaining = []
            } else if let (element, _) = Shell.collection(parameter.type) {
                bound[parameter.name] = .words(try remaining.map { try take($0, text: textOf($0), as: element, for: what) })
                remaining = []
            } else if let word = remaining.popFirst() {
                bound[parameter.name] = .words([try take(word, text: textOf(word), as: parameter.type, for: what)])
            }
        }
        if remaining.count == 1, textOf(remaining.first!) == nil,
           let parameter = parameters.first(where: { $0.label != nil && bound[$0.name] == nil && $0.type.acceptsFunction }) {
            bound[parameter.name] = .words([Piece(word: remaining.first!, text: nil)])
            remaining = []
        }
        if let extra = remaining.first {
            throw RuntimeError("\(name): unexpected argument '\(textOf(extra) ?? "closure")'")
        }
        for (name, items) in collected { bound[name] = .words(items) }
        for parameter in parameters where bound[parameter.name] == nil {
            if parameter.hasDefault {
                bound[parameter.name] = .defaulted
            } else if parameter.type.isBool && parameter.label != nil {
                bound[parameter.name] = .omitted
            } else if parameter.label != nil, Shell.collection(parameter.type) != nil {
                bound[parameter.name] = .omitted
            } else if parameter.type.optionalWrapped != nil {
                bound[parameter.name] = .omitted
            } else {
                throw RuntimeError("\(name): missing \(parameter.commandLineName)")
            }
        }
        return CommandLineBinding(overload: overload, assigned: bound, penalty: penalty)
    }
}
