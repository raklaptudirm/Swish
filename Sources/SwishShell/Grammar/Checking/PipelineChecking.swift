import Foundation

// Checking a pipeline, written against what a layer can ask of the checker (Layer/CheckContext.swift) and nothing else.

extension CommandNode {
    /// The command's name, when it's written out rather than built at run time.
    var literalName: String? {
        guard case .text(let parts)? = words.first, parts.count == 1, case .literal(let name) = parts[0] else { return nil }
        return name
    }

    /// The words after the name, when all of them are written out.
    var literalWords: [String]? {
        var result: [String] = []
        for word in words.dropFirst() {
            guard case .text(let parts) = word else { return nil }
            var text = ""
            for part in parts {
                guard case .literal(let literal) = part else { return nil }
                text += literal
            }
            result.append(text)
        }
        return result
    }
}

extension CheckContext {
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
            try throwingTry("'try \(pipeline.source)'")
        }
        var flowing: ValueType?
        // `"a b" | split(…)`: a value that isn't a sequence is the first
        // stage's receiver itself.
        var single: ValueType?
        if pipeline.input != nil {
            // Stages type what flows, so an empty `[]` needs no type.
            let type = try typeOf(&pipeline.input!, expecting: .unknown)
            if type.isList { pipeline.inputIsList = true }
            flowing = streamElement(type)
            if flowing == type && !type.isUnknownOrAny { single = type }
        }
        for index in pipeline.commands.indices {
            var command = pipeline.commands[index]
            try checkCommandText(&command)
            if index == 0, let single, let result = try checkBridgedStage(command.literalName ?? "", &command, element: single, receiver: .value) {
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
    func streamElement(_ type: ValueType) -> ValueType {
        itemType(ofSequence: type) ?? type
    }

    /// Checks one stage, fed items of type `input` (nil at the start), and
    /// gives the type of what it passes on.
    func checkStage(_ command: inout CommandNode, input: ValueType?) throws -> ValueType {
        guard let name = command.literalName, !command.external else {
            try checkClosures(&command)
            return .string // A program's lines.
        }
        let element = input ?? .unknown
        let known = input != nil && !element.isUnknownOrAny
        // A method of the items as they come, where there is one: it reads
        // no more than the stage after it asks for.
        if input != nil {
            let attempt = command
            do {
                if let result = try checkBridgedStage(name, &command, element: element, receiver: .flow) { return result }
            } catch let flowError as TypeFailure {
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
        if input != nil, let methods = sequenceMethod(named: name) {
            // The prelude's additions, and its streaming versions of Swift's
            // methods; where none fits, Swift's own.
            let attempt = command
            do {
                command.resolution = .sequenceMethod
                return try checkSequenceStage(name, methods, &command, element: element)
            } catch let error as TypeFailure {
                // Swift's, or else the prelude's error, the one meant first.
                command = attempt
                do {
                    guard let result = try checkBridgedStage(name, &command, element: element, receiver: .collected) else { throw error }
                    return result
                } catch let swiftError as TypeFailure {
                    command = attempt
                    throw preferred(prelude: error, swift: swiftError)
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
        // A method with nothing piped in, and no function or program by
        // that name, has nothing to work on.
        if input == nil, shell!.isStageMethod(name), lookup(name) == nil, shell!.findExecutable(name) == nil {
            throw TypeFailure("\(name) is a method: pipe something into it, as in `ls | \(name)`, or call it on a value, as in `xs.\(name)(…)`")
        }
        if case .functions(let overloads)? = lookup(name) {
            return try checkFunctionStage(name, overloads, &command, piped: input != nil || command.readsStandardInput)
        }
        // Only a program is left, and a program only takes words.
        if command.call != nil || command.words.contains(where: { if case .closure = $0 { true } else { false } }) {
            let what = input.map { " of \(ValueType.list($0))" } ?? ""
            throw TypeFailure("\(name) isn't a method\(what) or a function, and a program can't take a closure or (…)")
        }
        try checkClosures(&command)
        return .string
    }

    /// `xs | max`, `xs | joined(separator: ",")`, or `names | uppercased`:
    /// a Swift member of the items collected (as an Array), or of each item.
    /// Nil when the type has no member by that name.
    func checkBridgedStage(
        _ name: String, _ command: inout CommandNode, element: ValueType, receiver: StageReceiver
    ) throws -> ValueType? {
        guard !command.external, let found = stageMembers(named: name, receiver: receiver, element: element) else { return nil }
        let signatures = found.members.map(\.signature)
        command.resolution = .bridged(type: found.typeName, receiver: receiver, bindings: found.bindings)
        let result: ValueType
        if var call = command.call {
            let visible = signatures.map { signature -> Signature in
                var signature = signature
                signature.parameters.removeFirst()
                return signature
            }
            guard let chosen = try resolve(visible, arguments: &call, name: name, bindings: found.bindings) else {
                command.call = call
                return .unknown
            }
            command.call = call
            if signatures.count > 1 { command.overload = chosen.index }
            if chosen.isThrowing { try throwingSite("'\(name)'") }
            result = chosen.returns
        } else {
            result = try checkCommandLine(name, signatures, &command, bindings: found.bindings, excludingInput: true)
        }
        // Collected, a list comes out as its items; each item's result flows on as it is.
        return receiver == .each ? result : streamElement(result)
    }

    /// `ls | sorted --by size`, or `ls | sorted(by: \.size)`: a method of
    /// the sequence, with `Element` what flows in.
    func checkSequenceStage(
        _ name: String, _ methods: [Signature], _ command: inout CommandNode, element: ValueType
    ) throws -> ValueType {
        if var call = command.call {
            defer { command.call = call }
            let found = try sequenceMethodResult(named: name, element: element, arguments: &call)
            if let overload = found?.overload { command.overload = overload }
            return streamElement(found?.type ?? .unknown)
        }
        // `select`'s result is a tuple of the fields it names, which Swift could
        // only type with parameter packs over key paths; until then its rule is
        // here (https://github.com/raklaptudirm/Swiit/blob/main/Docs/foundations.md, open questions).
        if name == "select" {
            guard let fields = command.literalWords else { return .unknown }
            return streamElement(try selectResult(element: element, fields: fields))
        }
        let result = try checkCommandLine(name, methods, &command, bindings: ["Element": element], excludingInput: true)
        return streamElement(result)
    }

    /// `points | describe`: a method of each item, when their type has one.
    func checkItemMethodStage(_ name: String, _ command: inout CommandNode, element: ValueType) throws -> ValueType? {
        guard let found = itemMethods(of: element, named: name) else { return nil }
        if !found.isHostObject {
            if found.methods.count == 1 && found.methods[0].isMutating {
                throw TypeFailure("\(found.typeName).\(name) is mutating, and a piped value can't change: call it on a variable")
            }
            // Written as a call, `scaled(by: 3)`, it binds as Swift does.
            if var call = command.call {
                defer { command.call = call }
                return try resolve(found.methods, arguments: &call, name: name)?.returns ?? commonReturn(found.methods)
            }
            return try checkCommandLine(name, found.methods, &command, bindings: [:], excludingInput: false)
        }
        // A host object's method, as the host described it.
        try checkClosures(&command)
        return found.methods[0].returns
    }

    /// A function as a stage: its result per item, or its elements when it
    /// gives a list.
    func checkFunctionStage(
        _ name: String, _ overloads: [Signature], _ command: inout CommandNode, piped: Bool
    ) throws -> ValueType {
        let visible = piped ? overloads.map(\.withoutInput) : overloads
        if var call = command.call {
            defer { command.call = call }
            guard let chosen = try resolve(visible, arguments: &call, name: name) else {
                return streamElement(commonReturn(overloads))
            }
            if overloads.count > 1 { command.overload = chosen.index }
            return streamElement(chosen.returns)
        }
        let result = try checkCommandLine(name, visible, &command, bindings: [:], excludingInput: piped)
        return streamElement(result)
    }

    /// Binds a command line's arguments as the interpreter will, to find
    /// the overload it'll use and to catch a wrong flag or value now; then
    /// types key paths (`--by size`) and closures by what that overload
    /// wants, and gives its result. A word built at run time (`$x`) leaves
    /// the choice to run time.
    func checkCommandLine(
        _ name: String, _ signatures: [Signature], _ command: inout CommandNode,
        bindings initial: [String: ValueType], excludingInput: Bool
    ) throws -> ValueType {
        var words: [CommandWordShape] = []
        /// Where each closure is among the command's words.
        var closureWords: [Int] = []
        for (index, word) in command.words.enumerated().dropFirst() {
            switch word {
            case .text(let parts):
                var text = ""
                for part in parts {
                    guard case .literal(let literal) = part else {
                        try checkClosures(&command)
                        return commonReturn(signatures.map { var s = $0; s.returns = substitute(s.returns, initial); return s })
                    }
                    text += literal
                }
                words.append(.text(text))
            case .closure:
                closureWords.append(index)
                words.append(.closure)
            }
        }
        // `--help` shows help instead of running.
        if shell!.helpRequested(words, for: signatures) { return .string }
        let binding: CommandLineBinding
        do {
            binding = try shell!.bindCommandLine(words, to: signatures, name: name, excludingInput: excludingInput, declaredEnum: { self.isEnum($0) })
        } catch let error as CommandLineFailure {
            throw TypeFailure(error.message)
        }
        guard binding.overload < signatures.count else { return .unknown }
        let signature = signatures[binding.overload]
        var bindings = initial
        for parameter in signature.parameters {
            // `--by size`: a key path read from the items.
            if let (rootPattern, _) = parameter.type.keyPathParts, let text = binding.pieces(of: parameter.name).first?.text {
                var type = substitute(rootPattern, bindings)
                let root = type
                if !type.isUnknown {
                    for member in text.split(separator: ".").map(String.init) { type = try memberType(of: type, member) }
                }
                unify(parameter.type, .keyPath(root, type), &bindings)
            }
        }
        for word in closureWords {
            // A placeholder's word is counted from the command's name; a binding's from the first argument.
            guard let parameter = signature.parameters.first(where: { binding.pieces(of: $0.name).contains { $0.word == word - 1 } }),
                  case .closure(var closure) = command.words[word] else { continue }
            let actual = try closureType(&closure, expecting: substitute(parameter.type, bindings))
            command.words[word] = .closure(closure)
            guard fits(actual, substitute(parameter.type, bindings)) else {
                throw TypeFailure("\(name): '\(parameter.name)' must be \(substitute(parameter.type, bindings)), not \(actual)")
            }
            unify(parameter.type, actual, &bindings)
        }
        for (parameter, protocols) in signature.generics {
            guard let bound = bindings[parameter], !bound.isUnknown else { continue }
            for proto in protocols where !conforms(bound, to: proto) {
                throw TypeFailure("\(name) needs \(parameter) to be \(proto.hasPrefix("=") ? String(proto.dropFirst()) : proto), and \(bound) isn't")
            }
        }
        return substitute(signature.returns, bindings)
    }

    /// Closures in a command whose parameters aren't known: typed loosely.
    func checkClosures(_ command: inout CommandNode) throws {
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
