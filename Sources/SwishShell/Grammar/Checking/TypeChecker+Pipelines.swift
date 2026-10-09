@_spi(Shell) import Swiit
import Foundation
import SwishKit

extension TypeChecker {
    // MARK: Pipelines

    /// A pipeline's stages, each typed by what flows into it: the value at
    /// its start, a program's lines (Strings), or what the stage before
    /// gives. From that type the checker decides what each name is (a method
    /// of the sequence, of its items, a function, or a program) and records
    /// it for the interpreter, and checks the arguments written literally by
    /// binding them as the interpreter will.
    func checkPipeline(_ pipeline: inout PipelineNode) throws {
        // `try make`: the command's failure throws, which must be handled.
        if case .some(.none) = pipeline.throwing {
            throwingSites += 1
            try checkHandled("'try \(pipeline.source)'")
        }
        var flowing: TypeAnnotation?
        // `"a b" | split(…)`: a value that isn't a sequence is the first
        // stage's receiver itself.
        var single: TypeAnnotation?
        if pipeline.input != nil {
            // Stages type what flows, so an empty `[]` needs no type.
            let type = try typeOf(&pipeline.input!, expecting: .unknown)
            flowing = streamElement(type)
            if flowing == type && type != .unknown && type != .any { single = type }
        }
        for index in pipeline.commands.indices {
            var command = pipeline.commands[index]
            try checkCommandText(&command)
            if index == 0, let single, let result = try checkBridgedStage(command.words.first.flatMap { _ in TypeChecker.literalName(command) } ?? "", &command, element: single, receiver: .value) {
                flowing = result
            } else {
                flowing = try checkStage(&command, input: flowing)
            }
            pipeline.commands[index] = command
        }
    }

    /// The expressions in a command's words, environment and redirects.
    func checkCommandText(_ command: inout CommandNode) throws {
        for wordIndex in command.words.indices {
            if case .text(var parts) = command.words[wordIndex] {
                try checkParts(&parts)
                command.words[wordIndex] = .text(parts)
            }
        }
        for index in command.environment.indices { try checkParts(&command.environment[index].value) }
        for index in command.redirects.indices {
            if case .file(var parts, let mode) = command.redirects[index].target {
                try checkParts(&parts)
                command.redirects[index].target = .file(parts, mode)
            }
        }
    }

    /// What a value flowing into a pipeline is, item by item.
    func streamElement(_ type: TypeAnnotation) -> TypeAnnotation {
        switch type {
        case .list(let element): element
        case .generic: bridgedElement(type) ?? type
        // A bridged sequence, like a FilePath's components: its elements.
        case .named(let name) where Bridge.types[name]?.conformances["Sequence"] != nil:
            Bridge.types[name]?.associatedTypes["Element"] ?? type
        default: type
        }
    }

    /// Checks one stage, fed items of type `input` (nil at the start), and
    /// gives the type of what it passes on.
    func checkStage(_ command: inout CommandNode, input: TypeAnnotation?) throws -> TypeAnnotation {
        guard let name = TypeChecker.literalName(command), !command.external else {
            try checkClosures(&command, expecting: [:])
            return .string // A program's lines.
        }
        let element = input ?? .unknown
        let known = input != nil && element != .unknown && element != .any
        // A method of the items as they come, where there is one: it reads
        // no more than the stage after it asks for.
        if input != nil {
            let attempt = command
            do {
                if let result = try checkBridgedStage(name, &command, element: element, receiver: .flow) { return result }
            } catch let flowError as TypeError {
                // Where its arguments don't fit, the items collected may have
                // a member that does (`prefix(while:)`); if not, it's the
                // first one's error that says what's wrong.
                command = attempt
                if let result = try? checkBridgedStage(name, &command, element: element, receiver: .collected) { return result }
                command = attempt
                throw flowError
            }
        }
        // A stage is a method call: of the items collected, then of each
        // item, then a function, then a program (see foundations.md).
        if input != nil, let methods = shell!.interpreter.sequenceMethods[name] {
            // The prelude's additions, and its streaming versions of Swift's
            // methods; where none fits, Swift's own.
            let attempt = command
            do {
                command.resolution = .sequenceMethod
                return try checkSequenceStage(name, methods, &command, element: element)
            } catch let error as TypeError {
                // Swift's, or else the prelude's error, the one meant first.
                command = attempt
                do {
                    guard let result = try checkBridgedStage(name, &command, element: element, receiver: .collected) else { throw error }
                    return result
                } catch let swiftError as TypeError {
                    command = attempt
                    throw TypeChecker.preferred(prelude: error, swift: swiftError)
                }
            }
        }
        if input != nil, let result = try checkBridgedStage(name, &command, element: element, receiver: .collected) {
            return result
        }
        if input != nil, let result = try checkItemMethodStage(name, &command, element: element) {
            command.resolution = .itemMethod
            return result
        }
        if known, let result = try checkBridgedStage(name, &command, element: element, receiver: .each) {
            return result
        }
        // Decided here, even when the items' type isn't known: the
        // interpreter doesn't guess.
        if input != nil { command.resolution = .other }
        // A method with nothing piped in, and no function or program by
        // that name, has nothing to work on.
        if input == nil, shell!.isStageMethod(name), lookup(name) == nil, shell!.findExecutable(name) == nil {
            throw TypeError("\(name) is a method: pipe something into it, as in `ls | \(name)`, or call it on a value, as in `xs.\(name)(…)`")
        }
        if case .functions(let overloads)? = lookup(name) {
            let runtime = shell!.interpreter.commandFunctions(named: name)
            return try checkFunctionStage(name, overloads, runtime, &command, piped: input != nil)
        }
        // Only a program is left, and a program only takes words.
        if command.call != nil || command.words.contains(where: { if case .closure = $0 { true } else { false } }) {
            let what = input.map { " of \(TypeAnnotation.list($0))" } ?? ""
            throw TypeError("\(name) isn't a method\(what) or a function, and a program can't take a closure or (…)")
        }
        try checkClosures(&command, expecting: [:])
        return .string
    }

    /// `xs | max`, `xs | joined(separator: ",")`, or `names | uppercased`:
    /// a Swift member of the items collected (as an Array), or of each item.
    /// Nil when the type has no member by that name.
    func checkBridgedStage(
        _ name: String, _ command: inout CommandNode, element: TypeAnnotation, receiver: StageReceiver
    ) throws -> TypeAnnotation? {
        let receiverType: TypeAnnotation = switch receiver {
        case .collected: .list(element)
        case .flow: .generic("Flow", [element])
        case .each, .value: element
        }
        guard !command.external, let (bridgedType, bindings) = bridged(receiverType),
              let runtime = shell!.bridgedStage(bridgedType.name, name, receiver: receiver, bindings: bindings) else { return nil }
        let signatures = (receiver == .flow ? Bridge.flowMembers(name) : Bridge.stageMembers(bridgedType.name, name)).enumerated().map { position, entry in
            Signature(name: name, parameters: [Bridge.receiverParameter(receiver, element: element)] + entry.member.parameters,
                      returns: entry.member.returns, isThrowing: entry.member.isThrowing,
                      isRethrowing: entry.member.isRethrowing, index: position, generics: entry.member.generics)
        }
        command.resolution = .bridged(type: bridgedType.name, receiver: receiver, bindings: bindings)
        let result: TypeAnnotation
        if var call = command.call {
            let visible = signatures.map { signature -> Signature in
                var signature = signature
                signature.parameters.removeFirst()
                return signature
            }
            guard let chosen = try resolve(visible, &call, name: name, bindings: bindings) else {
                command.call = call
                return .unknown
            }
            command.call = call
            if signatures.count > 1 { command.overload = chosen.index }
            if chosen.isThrowing { try throwingSite("'\(name)'") }
            result = chosen.returns
        } else {
            result = try checkCommandLine(name, runtime, signatures, &command, bindings: bindings, excludingInput: true)
        }
        // Collected, a list comes out as its items; each item's result flows on as it is.
        return receiver == .each ? result : streamElement(result)
    }

    /// The command's name, when it's written out rather than built at run time.
    static func literalName(_ command: CommandNode) -> String? {
        guard case .text(let parts)? = command.words.first, parts.count == 1, case .literal(let name) = parts[0] else { return nil }
        return name
    }

    /// `ls | sorted --by size`, or `ls | sorted(by: \.size)`: a method of
    /// the sequence, with `Element` what flows in.
    func checkSequenceStage(
        _ name: String, _ methods: OverloadSet, _ command: inout CommandNode, element: TypeAnnotation
    ) throws -> TypeAnnotation {
        if var call = command.call {
            var callee = Expr.variable(name)
            let result = try sequenceMethodType(name, on: .list(element), &callee, &call) ?? .unknown
            command.call = call
            if case .chosen(_, let overload) = callee { command.overload = overload }
            return streamElement(result)
        }
        // `select`'s result is a tuple of the fields it names, which Swift could
        // only type with parameter packs over key paths; until then its rule is
        // here (Docs/Design/foundations.md, open questions).
        if name == "select" {
            let fields = TypeChecker.literalWords(command)
            guard let fields else { return .unknown }
            var arguments = fields.map { Argument(label: nil, value: .literal(.string($0))) }
            return streamElement(try selectType(element, arguments: &arguments))
        }
        let result = try checkCommandLine(name, methods, sequenceSignatures(methods), &command,
                                          bindings: ["Element": element], excludingInput: true)
        return streamElement(result)
    }

    /// `points | describe`: a method of each item, when their type has one.
    func checkItemMethodStage(_ name: String, _ command: inout CommandNode, element: TypeAnnotation) throws -> TypeAnnotation? {
        guard case .named(let typeName) = element else { return nil }
        if let info = structInfo(named: typeName), let methods = info.methods[name] {
            if methods.count == 1 && methods[0].isMutating {
                throw TypeError("\(typeName).\(name) is mutating, and a piped value can't change: call it on a variable")
            }
            if case .object(let type as StructType)? = shell!.interpreter.lookup(typeName)?.value, let set = type.methods[name] {
                return try checkCommandLine(name, set, methods, &command, bindings: [:], excludingInput: false)
            }
            try checkClosures(&command, expecting: [:])
            return commonReturn(methods)
        }
        if let members = interpreter.objectMembers[typeName], case .functionType(_, let result, _)? = members[name] {
            try checkClosures(&command, expecting: [:])
            return result
        }
        return nil
    }

    /// A function as a stage: its result per item, or its elements when it
    /// gives a list.
    func checkFunctionStage(
        _ name: String, _ overloads: [Signature], _ runtime: OverloadSet?, _ command: inout CommandNode, piped: Bool
    ) throws -> TypeAnnotation {
        let visible = overloads.map { signature -> Signature in
            var signature = signature
            if piped { signature.parameters.removeAll(where: \.isInput) }
            return signature
        }
        if var call = command.call {
            guard let chosen = try resolve(visible, &call, name: name) else {
                command.call = call
                return streamElement(commonReturn(overloads))
            }
            command.call = call
            if overloads.count > 1 { command.overload = chosen.index }
            return streamElement(chosen.returns)
        }
        guard let runtime, runtime.candidates.count == overloads.count else {
            // Declared in this program, so not bound yet: checked as it runs.
            try checkClosures(&command, expecting: [:])
            return streamElement(commonReturn(overloads))
        }
        let result = try checkCommandLine(name, runtime, visible, &command, bindings: [:], excludingInput: piped)
        return streamElement(result)
    }

    /// The words after a command's name, when all of them are written out.
    static func literalWords(_ command: CommandNode) -> [String]? {
        var words: [String] = []
        for word in command.words.dropFirst() {
            guard case .text(let parts) = word else { return nil }
            var text = ""
            for part in parts {
                guard case .literal(let literal) = part else { return nil }
                text += literal
            }
            words.append(text)
        }
        return words
    }

    /// Binds a command line's arguments as the interpreter will, to find
    /// the overload it'll use and to catch a wrong flag or value now; then
    /// types key paths (`--by size`) and closures by what that overload
    /// wants, and gives its result. A word built at run time (`$x`) leaves
    /// the choice to run time.
    func checkCommandLine(
        _ name: String, _ set: OverloadSet, _ signatures: [Signature], _ command: inout CommandNode,
        bindings initial: [String: TypeAnnotation], excludingInput: Bool
    ) throws -> TypeAnnotation {
        var arguments: [CommandArgument] = []
        var placeholders: [(word: Int, function: Function)] = []
        for (index, word) in command.words.enumerated().dropFirst() {
            switch word {
            case .text(let parts):
                var text = ""
                for part in parts {
                    guard case .literal(let literal) = part else {
                        try checkClosures(&command, expecting: initial)
                        return commonReturn(signatures.map { var s = $0; s.returns = substitute(s.returns, initial); return s })
                    }
                    text += literal
                }
                arguments.append(.text(text))
            case .closure:
                // Stands in for the closure, to see which parameter it binds.
                let stand = Function(name: nil, parameters: [], returnType: nil, body: .native { _, _ in .nothing })
                placeholders.append((index, stand))
                arguments.append(.value(.function(stand)))
            }
        }
        // `--help` shows help instead of running.
        if shell!.helpRequested(arguments, for: set) { return .string }
        let function: Function
        let bound: [String: Value]
        do {
            (function, bound) = try shell!.interpreter.resolve(set) { try self.shell!.bind(commandLine: arguments, to: $0, excludingInput: excludingInput) }
        } catch let error as RuntimeError {
            throw TypeError(error.description)
        }
        guard let index = set.candidates.firstIndex(where: { $0 === function }), index < signatures.count else { return .unknown }
        let signature = signatures[index]
        var bindings = initial
        for parameter in signature.parameters {
            // `--by size`: a key path read from the items.
            if case .keyPath(let rootPattern, _) = parameter.type, case .function(let keyPath as KeyPathValue)? = bound[parameter.name] {
                var type = substitute(rootPattern, bindings)
                let root = type
                if type != .unknown {
                    for member in keyPath.path { type = try memberType(of: type, member) }
                }
                unify(parameter.type, .keyPath(root, type), &bindings)
            }
        }
        for placeholder in placeholders {
            guard let parameter = signature.parameters.first(where: {
                if case .function(let value as Function)? = bound[$0.name] { value === placeholder.function } else { false }
            }), case .closure(var closure) = command.words[placeholder.word] else { continue }
            let actual = try closureType(&closure, expecting: substitute(parameter.type, bindings))
            command.words[placeholder.word] = .closure(closure)
            guard fits(actual, substitute(parameter.type, bindings)) else {
                throw TypeError("\(name): '\(parameter.name)' must be \(substitute(parameter.type, bindings)), not \(actual)")
            }
            unify(parameter.type, actual, &bindings)
        }
        for (parameter, protocols) in signature.generics {
            guard let bound = bindings[parameter], bound != .unknown else { continue }
            for proto in protocols where !conforms(bound, to: proto) {
                throw TypeError("\(name) needs \(parameter) to be \(proto.hasPrefix("=") ? String(proto.dropFirst()) : proto), and \(bound) isn't")
            }
        }
        return substitute(signature.returns, bindings)
    }

    /// Closures in a command whose parameters aren't known: typed loosely.
    func checkClosures(_ command: inout CommandNode, expecting bindings: [String: TypeAnnotation]) throws {
        for index in command.words.indices {
            if case .closure(var closure) = command.words[index] {
                _ = try closureType(&closure, expecting: nil)
                command.words[index] = .closure(closure)
            }
        }
        for index in (command.call ?? []).indices { _ = try typeOf(&command.call![index].value, expecting: .unknown) }
    }

    func checkParts(_ parts: inout [WordPart]) throws {
        for index in parts.indices {
            switch parts[index] {
            case .expression(var expr):
                _ = try typeOf(&expr)
                parts[index] = .expression(expr)
            case .spread(var expr):
                _ = try typeOf(&expr)
                parts[index] = .spread(expr)
            case .literal, .glob:
                break
            }
        }
    }
}

extension TypeChecker {
    /// The shell, when checking its commands: pipeline stages are typed with
    /// the shell's help on what a name is.
    var shell: Shell? { interpreter.owner as? Shell }
}
