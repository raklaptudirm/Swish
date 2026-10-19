@_spi(Layer) import Swiit
import Foundation

extension NameRole {
    init?(_ kind: NameKind) {
        switch kind {
        case .variable: self = .variable
        case .function: self = .function
        case .type: self = .type
        case .member: self = .member
        case .staticMember: self = .staticMember
        case .operatorDeclaration: return nil
        }
    }
}

extension Shell {
    /// The shell's front end for this shell's names.
    func makeFront(recovering: Bool = false) -> Front {
        let bound = interpreter.globalNames()
        let front = Front(bound: Names(roles: bound.compactMapValues { NameRole($0) }))
        front.closureArity = { [unowned self] (name: String) -> Int? in
            for candidate in interpreter.commandFunctions(named: name)?.candidates ?? [] {
                for parameter in candidate.parameters { if case .functionType(let parameters, _, _, _) = parameter.type { return parameters.count } }
            }
            return nil
        }
        front.isMethodWithoutInput = { [unowned self] name in
            isStageMethod(name) && interpreter.commandFunctions(named: name) == nil && Shell.shellBuiltins[name] == nil && findExecutable(name) == nil
        }
        front.recovering = recovering
        front.swiftHighlight = { [unowned self] source in
            self.interpreter.frontEnd.highlight(source, bound: bound).map { span in
                let kind: HighlightKind = switch span.kind {
                case .keyword: .keyword
                case .command: .command
                case .flag: .flag
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
        let result = try front.cure(source)
        commandUses = front.uses
        if ProcessInfo.processInfo.environment["SWISH_SHOWCURE"] != nil { FileHandle.standardError.write(Data((result + "\n").utf8)) }
        return result
    }

    /// The program the source is, read by the shell's own front end when that is on.
    func parseSource(_ source: String) -> Result<Program, SyntaxError> {
        do {
            return interpreter.parse(try cured(source))
        } catch let failure as Failure {
            return .failure(SyntaxError(failure.message, incomplete: failure.incomplete))
        } catch {
            return .failure(SyntaxError("\(error)"))
        }
    }
}

extension Shell {
    /// The first command line in the program that its function would not take, as `f 1 --bogus` against `func f(…)`: found
    /// before anything runs, from the function's parameters and the words alone.
    func firstCommandLineError(_ uses: [Front.CommandUse], checker: TypeChecker) -> String? {
        for use in uses {
            guard case .functions(let signatures)? = checker.lookup(use.name) else { continue }
            // After a `|`, a name some type has as a member may be that member, which is found when items arrive.
            if use.piped, isMemberName(use.name) || isStageMethod(use.name) { continue }
            let words = use.words.map { CommandWordShape.text($0) }
            if helpRequested(words, for: signatures) { continue }
            do {
                _ = try bindCommandLine(words, to: signatures, name: use.name, excludingInput: use.piped) { checker.describe(named: $0) }
            } catch {
                return "\(error)"
            }
        }
        return nil
    }
}
