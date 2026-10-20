import Swiit
import Foundation

extension NameRole {
    init(_ role: Symbol.Role) {
        switch role {
        case .variable: self = .variable
        case .function: self = .function
        case .type: self = .type
        }
    }
}

extension Shell {
    /// The shell's front end for this shell's names.
    func makeFront(recovering: Bool = false) -> Front {
        let front = Front(bound: Names(roles: interpreter.names().mapValues { NameRole($0) }))
        front.closureArity = { [unowned self] (name: String) -> Int? in
            for overload in commandFunctions(named: name)?.overloads ?? [] {
                for parameter in overload.function?.parameters ?? [] {
                    if case .function(let parameters, _) = parameter.type { return parameters.count }
                }
            }
            return nil
        }
        front.isMethodWithoutInput = { [unowned self] name in
            isStageMethod(name) && commandFunctions(named: name) == nil && Shell.shellBuiltins[name] == nil && findExecutable(name) == nil
        }
        front.recovering = recovering
        front.swiftHighlight = { [unowned self] source in
            self.interpreter.highlight(source).map { span in
                let kind: HighlightKind = switch span.kind {
                case .keyword: .keyword
                case .function: .command
                case .string: .string
                case .number: .number
                case .constant: .constant
                case .variable: .variable
                case .comment: .comment
                case .type: .type
                case .punctuation: .punctuation
                }
                return HighlightSpan(range: span.range, kind: kind)
            }
        }
        return front
    }

    /// How to color the source, in characters, which may be half typed.
    func highlightSpans(_ source: String) -> [HighlightSpan] {
        (try? makeFront(recovering: true).cureWithSpans(source).spans) ?? []
    }

    /// The source as Swift, its shell forms read.
    func cured(_ source: String) throws -> String {
        let front = makeFront()
        let cured = try front.cure(source)
        let (result, marks) = removingMarks(from: cured)
        scriptMarks.merge(marks) { $1 }
        commandUses = front.uses
        if ProcessInfo.processInfo.environment["SWISH_SHOWCURE"] != nil { FileHandle.standardError.write(Data((result + "\n").utf8)) }
        return result
    }
}

extension Shell {
    /// The first command line in the program that its function would not take, as `f 1 --bogus` against `func f(…)`: found
    /// before anything runs, from the function's parameters and the words alone.
    func firstCommandLineError(_ uses: [Front.CommandUse], declared declarations: Interpreter.Declarations) -> String? {
        // The enums the program declares have no cases to read yet: a word for one is read against what was declared.
        staticEnums = declarations.enumerations
        defer { staticEnums = [:] }
        let declared = declarations.symbols
        for use in uses {
            let functions = declared.filter { $0.name == use.name && $0.function != nil }
            guard let callee = functions.isEmpty ? commandFunctions(named: use.name) : Callee(name: use.name, overloads: functions, receiver: nil, marks: scriptMarks) else { continue }
            // After a `|`, a name some type has as a member may be that member, which is found when items arrive.
            if use.piped, isMemberName(use.name) || isStageMethod(use.name) { continue }
            let words = use.words.map { CommandWordShape.text($0) }
            if helpRequested(words, for: callee) { continue }
            do {
                _ = try bindCommandLine(words, to: callee, excludingInput: use.piped)
            } catch {
                return "\(error)"
            }
        }
        return nil
    }
}
