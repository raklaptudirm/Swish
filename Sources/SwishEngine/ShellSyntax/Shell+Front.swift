import Foundation
import Swiit

extension Names.Role {
    init(_ kind: Symbol.Kind) {
        switch kind {
        case .variable, .property, .enumCase: self = .variable
        case .function, .method, .initializer: self = .function
        case .structure, .enumeration, .class, .actor, .protocol: self = .type
        }
    }
}

extension Shell {
    /// The shell's front end for this shell's names.
    func makeFront(recovering: Bool = false) -> Front {
        let roles = Dictionary(
            interpreter.globals().map { ($0.name, Names.Role($0.kind)) },
            uniquingKeysWith: { first, _ in first }
        )
        let front = Front(bound: Names(roles: roles))
        front.closureArity = { [unowned self] (name: String) -> Int? in
            for overload in runner.commandFunctions(named: name)?.overloads ?? [] {
                for parameter in overload.function?.parameters ?? [] {
                    if case .function(let parameters, _, _, _) = parameter.type {
                        return parameters.count
                    }
                }
            }
            return nil
        }
        front.isMethodWithoutInput = { [unowned self] name in
            runner.isStageMethod(name) && runner.commandFunctions(named: name) == nil
                && builtins[name] == nil
                && runner.findExecutable(name) == nil
        }
        front.recovering = recovering
        front.swiftHighlight = { [unowned self] source in
            self.interpreter.highlighting(source)
                .map { span in
                    let kind: HighlightKind =
                        switch span.kind {
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
        programKnowledge.scriptMarks.merge(marks) { $1 }
        programKnowledge.commandUses = front.uses
        if ProcessInfo.processInfo.environment["SWISH_SHOWCURE"] != nil {
            FileHandle.standardError.write(Data((result + "\n").utf8))
        }
        return result
    }
}

extension Shell {
    /// The first command line in the program that its function would not take, as `f 1 --bogus`
    /// against `func f(…)`: found before anything runs, from the function's parameters and the
    /// words alone.
    func firstCommandLineError(
        _ uses: [Front.CommandUse],
        declared declarations: Interpreter.Declarations
    ) -> String? {
        // The enums the program declares have no cases to read yet: a word for one is read against
        // what was declared.
        programKnowledge.staticMembers = declarations.members
        defer { programKnowledge.staticMembers = [:] }
        let declared = declarations.symbols
        for use in uses {
            let functions = declared.filter { $0.name == use.name && $0.function != nil }
            guard
                let callee = functions.isEmpty
                    ? runner.commandFunctions(named: use.name)
                    : Callee(
                        name: use.name,
                        overloads: functions,
                        receiver: nil,
                        marks: programKnowledge.scriptMarks
                    )
            else { continue }
            // After a `|`, a name some type has as a member may be that member, which is found when
            // items arrive.
            if use.piped, runner.isMemberName(use.name) || runner.isStageMethod(use.name) {
                continue
            }
            let words = use.words.map { CommandWordShape.text($0) }
            if runner.helpRequested(words, for: callee) { continue }
            do {
                _ = try runner.bindCommandLine(words, to: callee, excludingInput: use.piped)
            } catch {
                return "\(error)"
            }
        }
        return nil
    }
}
