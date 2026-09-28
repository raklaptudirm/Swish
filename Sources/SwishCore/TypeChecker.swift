import Foundation
import SwishKit

/// A mistake in types, found before anything runs: the statement (or, in a
/// script, the whole script) doesn't run. See docs/design/types.md.
struct TypeError: Error, CustomStringConvertible {
    let message: String
    /// The line of the statement it's in, when there's more than one.
    var line: Int?

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

/// Works out the type of every expression and checks it fits where it's
/// used, as Swift does: local, two-way inference, with every function's
/// signature written. Names already bound in the shell (from earlier
/// entries at the prompt, and the builtins) come from the shell; those the
/// program declares come from the program.
///
/// It also decides what the interpreter would otherwise decide as it runs,
/// and writes that into the program it returns: which overload a call
/// uses (`.chosen`). Commands, pipelines and builtins' results are
/// `unknown` until phase 3, which fits anywhere.
final class TypeChecker {
    struct Signature {
        var name: String
        var parameters: [Parameter]
        var returns: TypeAnnotation
        var isMutating = false
        var isThrowing = false
        /// Its position among the overloads the interpreter will have.
        var index = 0
    }

    struct StructInfo {
        var name: String
        var stored: [PropertyDecl]
        var computed: [String: TypeAnnotation]
        var methods: [String: [Signature]]
        var initializers: [Signature]
        var memberwise: Signature

        func property(_ name: String) -> PropertyDecl? { stored.first { $0.name == name } }
    }

    struct EnumInfo {
        var name: String
        /// Each case's associated values, in declaration order.
        var cases: [(name: String, payload: [AssociatedValue])]
        var rawType: TypeAnnotation?

        func payload(of name: String) -> [AssociatedValue]? { cases.first { $0.name == name }?.payload }
    }

    enum Symbol {
        case variable(TypeAnnotation, mutable: Bool)
        case functions([Signature])
        case structType(StructInfo)
        case enumType(EnumInfo)
        /// An imported module, `Tools`; its members aren't known until it loads.
        case module
        /// `env`: the environment.
        case environment
    }

    /// Where `return` goes: the declared result, or, for a closure that
    /// didn't say, the types its `return`s give.
    private final class ReturnContext {
        let declared: TypeAnnotation?
        var seen: [TypeAnnotation] = []

        init(declared: TypeAnnotation?) {
            self.declared = declared
        }
    }

    /// Whether an error thrown here is handled: in a `throws` function, a
    /// closure, a `do` with a `catch`, or at the top level.
    private struct ErrorContext {
        var handled: Bool
        /// The function it's in, for messages.
        var function: String?
    }

    private unowned let shell: Shell
    /// What the program declares, innermost last, on top of the shell's names.
    private var scopes: [[String: Symbol]] = [[:]]
    private var returns: [ReturnContext] = []
    private var errorContexts = [ErrorContext(handled: true)]
    /// Above zero while checking what a `try` covers.
    private var tryDepth = 0
    /// Places that can throw, so far: how a `try` or a closure knows it
    /// covers one.
    private var throwingSites = 0
    /// After an `import`, names it may bring can't be checked.
    private var afterImport = false
    private var line: Int?

    init(shell: Shell) {
        self.shell = shell
    }

    /// Checks a program, returning it with what was decided written in.
    func check(_ program: Program) throws(TypeError) -> Program {
        var checked = program
        do {
            try checkBlock(&checked)
        } catch var error as TypeError {
            error.line = error.line ?? line
            throw error
        } catch {
            preconditionFailure("the checker only throws TypeError")
        }
        return checked
    }

    /// The types of the globals a checked program declared, for the next
    /// entry at the prompt.
    var declaredGlobals: [String: TypeAnnotation] {
        scopes[0].compactMapValues { if case .variable(let type, _) = $0 { type } else { nil } }
    }

    // MARK: Statements

    private func checkBlock(_ program: inout Program, declaring names: [String: Symbol] = [:], newScope: Bool = false) throws {
        if newScope { scopes.append(names) }
        defer { if newScope { scopes.removeLast() } }
        // Declared first, so functions and types can be used before (and by)
        // their declarations, as in Swift.
        for statement in program.statements {
            switch statement {
            case .function(let decl): declareFunction(decl)
            case .structDecl(let decl): scopes[scopes.count - 1][decl.name] = .structType(try structInfo(decl))
            case .enumDecl(let decl): scopes[scopes.count - 1][decl.name] = .enumType(enumInfo(decl))
            default: break
            }
        }
        for index in program.statements.indices {
            if index < program.lines.count { line = program.lines[index] }
            try checkStatement(&program.statements[index])
        }
    }

    private func checkStatement(_ statement: inout Statement) throws {
        switch statement {
        case .declare(let name, let mutable, var value):
            var type = try typeOf(&value)
            if type == .optional(.unknown), case .literal(.nothing) = value {
                throw TypeError("'nil' needs a type: let \(name): T? = nil")
            }
            if case .tuple([]) = type { type = .void }
            scopes[scopes.count - 1][name] = .variable(type, mutable: mutable)
            statement = .declare(name: name, mutable: mutable, value: value)
        case .assign(var assignment):
            try checkAssignment(&assignment)
            statement = .assign(assignment)
        case .function(var decl):
            try checkFunction(&decl)
            statement = .function(decl)
        case .setEnvironment(var name, var value):
            try expect(&name, .string, "an environment variable's name")
            _ = try typeOf(&value)
            statement = .setEnvironment(name: name, value: value)
        case .doCatch(var body, let errorName, var handler):
            // A `do` with a `catch` handles what its body throws.
            errorContexts.append(ErrorContext(handled: handler != nil || errorContexts.last!.handled,
                                              function: errorContexts.last!.function))
            try checkBlock(&body, newScope: true)
            errorContexts.removeLast()
            if var caught = handler {
                try checkBlock(&caught, declaring: [errorName: .variable(.named("Error"), mutable: false)], newScope: true)
                handler = caught
            }
            statement = .doCatch(body: body, errorName: errorName, handler: handler)
        case .enumDecl(var decl):
            try checkEnum(&decl)
            statement = .enumDecl(decl)
        case .structDecl(var decl):
            try checkStruct(&decl)
            statement = .structDecl(decl)
        case .importPlugin(let name, var path):
            try expect(&path, .string, "an import's path")
            scopes[scopes.count - 1][name] = .module
            afterImport = true
            statement = .importPlugin(name: name, path: path)
        case .returnStatement(var value):
            guard let context = returns.last else { return }
            if value != nil {
                if context.declared == .void {
                    throw TypeError("a function without '->' returns nothing, so 'return' takes no value")
                }
                if let declared = context.declared {
                    try expect(&value!, declared, "the returned value")
                } else {
                    context.seen.append(try typeOf(&value!))
                }
            } else if let declared = context.declared, declared != .void, declared != .unknown {
                throw TypeError("this function must return \(declared)")
            }
            statement = .returnStatement(value)
        case .fallthroughStatement, .breakStatement, .continueStatement:
            break
        case .chain(var chain):
            try checkChain(&chain, condition: false)
            statement = .chain(chain)
        }
    }

    private func checkChain(_ chain: inout Chain, condition: Bool) throws {
        try checkUnit(&chain.first, condition: condition || !chain.links.isEmpty)
        for index in chain.links.indices { try checkUnit(&chain.links[index].unit, condition: true) }
    }

    /// `condition`: the unit's status decides something, as in `if` or
    /// `&&`: an expression there must be a Bool, an Output, or optional.
    private func checkUnit(_ unit: inout Unit, condition: Bool) throws {
        switch unit {
        case .pipeline(var pipeline):
            try checkPipeline(&pipeline)
            unit = .pipeline(pipeline)
        case .expression(var expr):
            let type = try typeOf(&expr)
            if condition {
                // `if try? build()`: whether it succeeded.
                let attempted = if case .attempt(_, .optional) = expr { true } else { false }
                switch type {
                case .bool, .output, .unknown: break
                case .optional where attempted: break
                default: throw TypeError("a condition must be a Bool, not \(type)")
                }
            }
            unit = .expression(expr)
        case .ifStatement(var node):
            try checkIf(&node)
            unit = .ifStatement(node)
        case .switchStatement(var node):
            try checkSwitch(&node)
            unit = .switchStatement(node)
        case .forLoop(var loop):
            let element = try elementType(of: try typeOf(&loop.sequence))
            try checkBlock(&loop.body, declaring: [loop.variable: .variable(element, mutable: false)], newScope: true)
            unit = .forLoop(loop)
        case .whileLoop(var loop):
            try checkChain(&loop.condition, condition: true)
            try checkBlock(&loop.body, newScope: true)
            unit = .whileLoop(loop)
        }
    }

    private func checkIf(_ node: inout IfStatement) throws {
        var bound: [String: Symbol] = [:]
        switch node.condition {
        case .chain(var chain):
            try checkChain(&chain, condition: true)
            node.condition = .chain(chain)
        case .binding(let name, let mutable, var value):
            let type = try typeOf(&value)
            if case .optional(let wrapped) = type {
                bound[name] = .variable(wrapped, mutable: mutable)
            } else if type == .unknown {
                bound[name] = .variable(.unknown, mutable: mutable)
            } else {
                throw TypeError("'if let' unwraps an optional, but this is \(type)")
            }
            node.condition = .binding(name: name, mutable: mutable, value: value)
        case .pattern(var pattern, var value):
            try checkPattern(&pattern, against: try typeOf(&value), binding: &bound)
            node.condition = .pattern(pattern, value)
        }
        try checkBlock(&node.then, declaring: bound, newScope: true)
        if var otherwise = node.otherwise {
            try checkBlock(&otherwise, newScope: true)
            node.otherwise = otherwise
        }
    }

    private func checkSwitch(_ node: inout SwitchStatement) throws {
        let subject = try typeOf(&node.subject)
        for index in node.cases.indices {
            var bound: [String: Symbol] = [:]
            for patternIndex in node.cases[index].patterns.indices {
                try checkPattern(&node.cases[index].patterns[patternIndex], against: subject, binding: &bound)
            }
            scopes.append(bound)
            defer { scopes.removeLast() }
            if node.cases[index].guardExpr != nil {
                try expect(&node.cases[index].guardExpr!, .bool, "a case's 'where'")
            }
            try checkBlock(&node.cases[index].body, newScope: true)
        }
    }

    private func checkPattern(_ pattern: inout Pattern, against type: TypeAnnotation, binding bound: inout [String: Symbol]) throws {
        switch pattern {
        case .wildcard:
            break
        case .binding(let name, let mutable):
            bound[name] = .variable(type, mutable: mutable)
        case .enumCase(let typeName, let name, var arguments):
            var subject = type
            if case .optional(let wrapped) = subject { subject = wrapped }
            if subject == .unknown {
                for index in (arguments ?? []).indices {
                    try checkPattern(&arguments![index].pattern, against: .unknown, binding: &bound)
                }
                pattern = .enumCase(type: typeName, name: name, arguments: arguments)
                return
            }
            guard case .named(let enumName) = subject, let info = enumInfo(named: enumName) else {
                throw TypeError("a case pattern like .\(name) matches an enum, not \(type)")
            }
            if let typeName, typeName != enumName {
                throw TypeError("\(typeName).\(name) can't match a \(enumName)")
            }
            guard let payload = info.payload(of: name) else { throw TypeError("\(enumName) has no case '\(name)'") }
            guard arguments != nil else { return }
            guard arguments!.count == payload.count else {
                throw TypeError("\(enumName).\(name) has \(payload.count) associated values, not \(arguments!.count)")
            }
            for index in arguments!.indices {
                try checkPattern(&arguments![index].pattern, against: payload[index].type, binding: &bound)
            }
            pattern = .enumCase(type: typeName, name: name, arguments: arguments)
        case .expression(var expr):
            if case .binary(let op, var lower, var upper) = expr, op == .closedRange || op == .halfOpenRange {
                let boundType = type == .double ? TypeAnnotation.double : type
                try expect(&lower, boundType, "a range's bound")
                try expect(&upper, boundType, "a range's bound")
                pattern = .expression(.binary(op, lower, upper))
                return
            }
            let valueType = try typeOf(&expr, expecting: type)
            guard fits(valueType, type) || fits(type, valueType) else {
                throw TypeError("a \(valueType) can't match a \(type)")
            }
            pattern = .expression(expr)
        }
    }

    // MARK: Declarations

    /// Adds `decl` to its name's overloads, in the order the interpreter
    /// keeps them: one with the same parameters replaces the old.
    private func declareFunction(_ decl: FunctionDecl) {
        var overloads: [Signature] = []
        if case .functions(let existing)? = scopes[scopes.count - 1][decl.name] {
            overloads = existing
        } else if scopes.count == 1, let binding = shell.scopes.last?.bindings[decl.name], binding.isFunction,
                  case .function(let set as OverloadSet) = binding.value {
            // At the top, it joins what earlier entries declared.
            overloads = set.candidates.map(signature)
        }
        overloads.removeAll { sameParameters($0.parameters, decl.parameters) }
        overloads.append(Signature(
            name: decl.name, parameters: decl.parameters, returns: decl.returnType ?? .void, isThrowing: decl.isThrowing
        ))
        for index in overloads.indices { overloads[index].index = index }
        scopes[scopes.count - 1][decl.name] = .functions(overloads)
    }

    private func sameParameters(_ a: [Parameter], _ b: [Parameter]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.label == $1.label && $0.type == $1.type && $0.variadic == $1.variadic }
    }

    private func checkFunction(
        _ decl: inout FunctionDecl, self selfType: TypeAnnotation? = nil, mutating: Bool = false, initializing: Bool = false
    ) throws {
        var names: [String: Symbol] = [:]
        for index in decl.parameters.indices {
            let parameter = decl.parameters[index]
            if decl.parameters[index].defaultValue != nil {
                try expect(&decl.parameters[index].defaultValue!, parameter.type, "\(parameter.name)'s default")
            }
            names[parameter.name] = .variable(parameter.variadic ? .list(parameter.type) : parameter.type, mutable: false)
        }
        if let selfType { names["self"] = .variable(selfType, mutable: mutating || initializing) }
        if initializing { names["$initializing"] = .variable(.void, mutable: false) }
        let result = decl.returnType ?? .void
        returns.append(ReturnContext(declared: result))
        errorContexts.append(ErrorContext(handled: decl.isThrowing, function: decl.name))
        scopes.append(names)
        defer {
            returns.removeLast()
            errorContexts.removeLast()
            scopes.removeLast()
        }

        // A body that's one expression is the result, when there's one.
        if result != .void, var expr = implicitReturn(decl.body) {
            try expect(&expr, result, "\(decl.name)'s result")
            decl.body.statements[0] = .chain(Chain(first: .expression(expr)))
            return
        }
        try checkBlock(&decl.body)
        if result != .void && result != .unknown && !definitelyReturns(decl.body) {
            throw TypeError("\(decl.name) must return \(result) on every path")
        }
    }

    private func implicitReturn(_ body: Program) -> Expr? {
        guard body.statements.count == 1, case .chain(let chain) = body.statements[0], chain.links.isEmpty,
              case .expression(let expr) = chain.first else { return nil }
        return expr
    }

    /// Whether running `program` always ends in a `return`: as simple as
    /// Swift's own check, from the last statement.
    private func definitelyReturns(_ program: Program) -> Bool {
        guard let last = program.statements.last else { return false }
        switch last {
        case .returnStatement:
            return true
        case .doCatch(let body, _, let handler):
            return definitelyReturns(body) && handler.map(definitelyReturns) ?? true
        case .chain(let chain) where chain.links.isEmpty:
            switch chain.first {
            case .ifStatement(let node):
                guard let otherwise = node.otherwise else { return false }
                return definitelyReturns(node.then) && definitelyReturns(otherwise)
            case .switchStatement(let node):
                // A switch always matches (or fails), so every case returning is enough.
                return !node.cases.isEmpty && node.cases.allSatisfy { definitelyReturns($0.body) }
            default:
                return false
            }
        default:
            return false
        }
    }

    private func structInfo(_ decl: StructDecl) throws -> StructInfo {
        var computed: [String: TypeAnnotation] = [:]
        for property in decl.properties where property.getter != nil { computed[property.name] = property.type ?? .unknown }
        var methods: [String: [Signature]] = [:]
        for method in decl.methods {
            var signature = Signature(name: method.name, parameters: method.parameters, returns: method.returnType ?? .void,
                                      isMutating: method.isMutating, isThrowing: method.isThrowing)
            signature.index = methods[method.name]?.count ?? 0
            methods[method.name, default: []].append(signature)
        }
        var stored: [PropertyDecl] = []
        for var property in decl.properties where property.getter == nil {
            // An untyped property takes its default's type.
            if property.type == nil, var defaultValue = property.defaultValue {
                property.type = try typeOf(&defaultValue)
            }
            stored.append(property)
        }
        let memberwise = Signature(
            name: decl.name,
            parameters: stored.filter { $0.mutable || $0.defaultValue == nil }.map {
                Parameter(label: $0.name, name: $0.name, type: $0.type ?? .unknown, defaultValue: $0.defaultValue)
            },
            returns: .named(decl.name)
        )
        let initializers = decl.initializers.enumerated().map { index, initializer in
            Signature(name: "\(decl.name).init", parameters: initializer.parameters, returns: .named(decl.name),
                      isMutating: true, isThrowing: initializer.isThrowing, index: index)
        }
        return StructInfo(name: decl.name, stored: stored, computed: computed, methods: methods,
                          initializers: initializers, memberwise: memberwise)
    }

    private func checkStruct(_ decl: inout StructDecl) throws {
        let selfType = TypeAnnotation.named(decl.name)
        for index in decl.properties.indices {
            let property = decl.properties[index]
            if let getter = property.getter {
                var function = FunctionDecl(name: property.name, parameters: [], returnType: property.type, body: getter)
                try checkFunction(&function, self: selfType)
                decl.properties[index].getter = function.body
            } else if property.defaultValue != nil, let type = property.type {
                try expect(&decl.properties[index].defaultValue!, type, "\(decl.name).\(property.name)'s default")
            }
        }
        for index in decl.methods.indices {
            try checkFunction(&decl.methods[index], self: selfType, mutating: decl.methods[index].isMutating)
        }
        for index in decl.initializers.indices {
            var function = decl.initializers[index]
            function.name = "\(decl.name).init"
            try checkFunction(&function, self: selfType, initializing: true)
            function.name = "init"
            decl.initializers[index] = function
        }
    }

    private func enumInfo(_ decl: EnumDecl) -> EnumInfo {
        EnumInfo(name: decl.name, cases: decl.cases.map { ($0.name, $0.associated) }, rawType: decl.rawType)
    }

    private func checkEnum(_ decl: inout EnumDecl) throws {
        guard let rawType = decl.rawType else { return }
        for index in decl.cases.indices where decl.cases[index].rawValue != nil {
            try expect(&decl.cases[index].rawValue!, rawType, "\(decl.name).\(decl.cases[index].name)'s raw value")
        }
    }

    // MARK: Assignment

    private func checkAssignment(_ assignment: inout Assignment) throws {
        guard let symbol = lookup(assignment.root) else { throw TypeError("no variable named '\(assignment.root)'") }
        guard case .variable(let rootType, let mutable) = symbol else {
            throw TypeError("cannot assign to '\(assignment.root)': it isn't a variable")
        }
        guard mutable else {
            if assignment.root == "self" {
                throw TypeError("cannot assign to self here: it's only changed by a mutating method")
            }
            throw TypeError("cannot assign to '\(assignment.root)': it's a 'let' constant")
        }
        var type = rootType
        for index in assignment.path.indices {
            let last = index == assignment.path.count - 1
            switch assignment.path[index] {
            case .member(let name):
                if case .named(let structName) = type, let info = structInfo(named: structName) {
                    guard let property = info.property(name) else {
                        let why = info.computed[name] != nil ? "it's a computed property" : "\(structName) has no property '\(name)'"
                        throw TypeError("cannot assign to '\(name)': \(why)")
                    }
                    let initializing = assignment.root == "self" && index == 0 && lookup("$initializing") != nil
                    guard property.mutable || (initializing && last) else {
                        throw TypeError("cannot assign to '\(name)': it's a 'let' property of \(structName)")
                    }
                    type = property.type ?? .unknown
                } else if case .tuple(let elements) = type {
                    guard let element = tupleElement(name, of: elements) else { throw TypeError("\(type) has no element '\(name)'") }
                    type = element
                } else if type == .unknown || type == .record || type == .any {
                    type = .unknown
                } else {
                    throw TypeError("cannot assign to '\(name)' of \(type)")
                }
            case .index(var indexExpr):
                switch type {
                case .list(let element):
                    try expect(&indexExpr, .int, "a list's index")
                    type = element
                case .dictionary(let key, let value):
                    try expect(&indexExpr, key, "the key")
                    // Assigning nil removes the entry.
                    type = last ? .optional(value) : value
                case .unknown, .record, .any:
                    _ = try typeOf(&indexExpr)
                    type = .unknown
                default:
                    throw TypeError("cannot assign into \(type) by index")
                }
                assignment.path[index] = .index(indexExpr)
            }
        }
        if let op = assignment.op {
            let valueType = try typeOf(&assignment.value, expecting: type)
            let result = try binaryType(op, type, valueType)
            guard fits(result, type) else { throw TypeError("'\(op.rawValue)=' would make \(type) a \(result)") }
        } else {
            try expect(&assignment.value, type, "the value assigned")
        }
    }

    // MARK: Pipelines

    /// Commands take text, and what they give isn't typed yet (phase 3);
    /// the expressions inside them are.
    private func checkPipeline(_ pipeline: inout PipelineNode) throws {
        // `try make`: the command's failure throws, which must be handled.
        if case .some(.none) = pipeline.throwing {
            throwingSites += 1
            try checkHandled("'try \(pipeline.source)'")
        }
        // What a stage takes isn't typed yet, so an empty `[]` needs no type.
        if pipeline.input != nil { _ = try typeOf(&pipeline.input!, expecting: .unknown) }
        for commandIndex in pipeline.commands.indices {
            var command = pipeline.commands[commandIndex]
            for wordIndex in command.words.indices {
                switch command.words[wordIndex] {
                case .text(var parts):
                    try checkParts(&parts)
                    command.words[wordIndex] = .text(parts)
                case .closure(let closure):
                    var expr = Expr.closure(closure)
                    _ = try typeOf(&expr)
                    if case .closure(let checked) = expr { command.words[wordIndex] = .closure(checked) }
                }
            }
            for index in (command.call ?? []).indices { _ = try typeOf(&command.call![index].value, expecting: .unknown) }
            for index in command.environment.indices { try checkParts(&command.environment[index].value) }
            for index in command.redirects.indices {
                if case .file(var parts, let mode) = command.redirects[index].target {
                    try checkParts(&parts)
                    command.redirects[index].target = .file(parts, mode)
                }
            }
            pipeline.commands[commandIndex] = command
        }
    }

    private func checkParts(_ parts: inout [StringPart]) throws {
        for index in parts.indices {
            if case .expression(var expr) = parts[index] {
                _ = try typeOf(&expr)
                parts[index] = .expression(expr)
            }
        }
    }

    // MARK: Throwing

    /// A plain `try` covers something that throws: it has to be handled.
    private func checkHandled(_ what: String) throws {
        guard let context = errorContexts.last, !context.handled else { return }
        let place = context.function.map { "\($0) isn't 'throws'" } ?? "nothing catches it"
        throw TypeError("\(what) can throw, but \(place): mark it 'throws', or use do/catch, try? or try!")
    }

    /// Something that can throw, like a call to a `throws` function: it
    /// needs a `try` covering it.
    private func throwingSite(_ what: String) throws {
        throwingSites += 1
        guard tryDepth > 0 else {
            throw TypeError("\(what) can throw, but isn't marked with 'try'")
        }
    }

    // MARK: Expressions

    /// `expr`'s type, which must fit `expected`.
    private func expect(_ expr: inout Expr, _ expected: TypeAnnotation, _ what: String) throws {
        let type = try typeOf(&expr, expecting: expected)
        guard fits(type, expected) else {
            throw TypeError("\(what) must be \(expected), not \(type)")
        }
    }

    /// `expr`'s type, given what the context expects of it (which a literal,
    /// a closure or a `.case` takes its type from); `expr` gets what the
    /// checker decided.
    func typeOf(_ expr: inout Expr, expecting expected: TypeAnnotation? = nil) throws -> TypeAnnotation {
        switch expr {
        case .literal(let value):
            switch value {
            case .int where expected == .double || expected == .optional(.double):
                return .double // `let x: Double = 1`
            case .nothing:
                if let expected, case .optional = expected { return expected }
                return .optional(.unknown)
            default:
                return type(of: value)
            }
        case .string(var parts):
            try checkParts(&parts)
            expr = .string(parts)
            return .string
        case .variable(let name):
            guard let symbol = lookup(name) else {
                if afterImport { return .unknown }
                throw TypeError("no variable named '\(name)'")
            }
            switch symbol {
            case .variable(let type, _):
                return type
            case .functions(let overloads):
                return functionValue(name, overloads, expected: expected, expr: &expr)
            case .environment:
                return .dictionary(.string, .string)
            case .structType, .enumType, .module:
                return .unknown
            }
        case .dollar(let name):
            if case .variable(let type, _)? = lookup(name) { return type }
            return .string
        case .substitution(var program, let throwing):
            if throwing { try throwingSite("the command") }
            try checkBlock(&program, newScope: true)
            expr = .substitution(program, throwing: throwing)
            return .output
        case .attempt(var inner, let kind):
            let sitesBefore = throwingSites
            tryDepth += 1
            let wanted = expected.flatMap { if case .optional(let wrapped) = $0 { wrapped } else { $0 } }
            let type = try typeOf(&inner, expecting: kind == .optional ? wanted : expected)
            tryDepth -= 1
            expr = .attempt(inner, kind)
            switch kind {
            case .plain:
                if throwingSites > sitesBefore { try checkHandled("this") }
                return type
            case .forced:
                throwingSites = sitesBefore // Handled right here.
                return type
            case .optional:
                throwingSites = sitesBefore
                if case .optional = type { return type }
                if type == .void {
                    // Success is `()`, not nil, as in Swift.
                    expr = .attempt(.voidValue(inner), kind)
                    return .optional(.void)
                }
                return .optional(type)
            }
        case .async(var target):
            switch target {
            case .command(var pipeline):
                try checkPipeline(&pipeline)
                target = .command(pipeline)
            case .capture(var pipeline):
                try checkPipeline(&pipeline)
                target = .capture(pipeline)
            }
            expr = .async(target)
            return .named("Job")
        case .await(var job, let throwing):
            if throwing { try throwingSite("awaiting a job") }
            if job != nil { try expect(&job!, .named("Job"), "what 'await' waits for") }
            expr = .await(job, throwing: throwing)
            return .output
        case .list(var items):
            let type = try listType(&items, expected: expected)
            expr = .list(items)
            return type
        case .record(var entries):
            let type = try dictionaryType(&entries, expected: expected)
            expr = .record(entries)
            return type
        case .tuple(var elements):
            if elements.isEmpty { return .void }
            var wanted: [TypeAnnotation.TupleElement]?
            if case .tuple(let elementTypes)? = expected, elementTypes.count == elements.count { wanted = elementTypes }
            var types: [TypeAnnotation.TupleElement] = []
            for index in elements.indices {
                types.append(.init(label: elements[index].label, type: try typeOf(&elements[index].value, expecting: wanted?[index].type)))
            }
            expr = .tuple(elements)
            return .tuple(types)
        case .closure(var closure):
            let type = try closureType(&closure, expecting: expected)
            expr = .closure(closure)
            return type
        case .call(var callee, var arguments):
            let type = try callType(&callee, &arguments, expected: expected)
            expr = .call(callee, arguments)
            return type
        case .member(var base, let name):
            let type = try memberType(&base, name)
            expr = .member(base, name)
            return type
        case .caseLiteral(let name, var arguments):
            let type = try caseType(name, &arguments, expected: expected)
            expr = .caseLiteral(name, arguments)
            return type
        case .unary(let op, var operand):
            let type = try typeOf(&operand, expecting: op == .negate ? expected : .bool)
            expr = .unary(op, operand)
            switch (op, type) {
            case (.not, .bool), (.not, .unknown): return .bool
            case (.negate, .int), (.negate, .double), (.negate, .filesize), (.negate, .unknown): return type
            default: throw TypeError("'\(op.rawValue)' can't be applied to \(type)")
            }
        case .binary(let op, var lhs, var rhs):
            let type = try binaryExprType(op, &lhs, &rhs, expected: expected)
            expr = .binary(op, lhs, rhs)
            return type
        case .index(var base, var index):
            let type = try indexType(&base, &index)
            expr = .index(base, index)
            return type
        case .annotated(var inner, let type):
            try expect(&inner, type, "the value")
            expr = .annotated(inner, type)
            return type
        case .forceUnwrap(var inner):
            let type = try typeOf(&inner)
            expr = .forceUnwrap(inner)
            if case .optional(let wrapped) = type { return wrapped }
            if type == .unknown { return .unknown }
            throw TypeError("'!' unwraps an optional, but this is \(type)")
        case .optionalMember(var base, let name):
            let wrapped = try optionalBase(&base)
            expr = .optionalMember(base, name)
            let member = try memberType(of: wrapped, name)
            if case .optional = member { return member }
            return member == .unknown ? .unknown : .optional(member)
        case .chosen(var inner, let overload):
            let type = try typeOf(&inner, expecting: expected)
            expr = .chosen(inner, overload: overload)
            return type
        case .voidValue(var inner):
            _ = try typeOf(&inner)
            expr = .voidValue(inner)
            return .void
        }
    }

    /// What `x` in `x?.name` is when it isn't nil.
    private func optionalBase(_ base: inout Expr) throws -> TypeAnnotation {
        let type = try typeOf(&base)
        if case .optional(let wrapped) = type { return wrapped }
        if type == .unknown { return .unknown }
        throw TypeError("'?.' is for optionals; \(type) isn't one: use '.'")
    }

    /// A function used as a value: an overloaded one is picked by the
    /// function type wanted, as in `xs.map(double)`.
    private func functionValue(_ name: String, _ overloads: [Signature], expected: TypeAnnotation?, expr: inout Expr) -> TypeAnnotation {
        if overloads.count == 1 { return functionType(overloads[0]) }
        guard let expected, case .functionType = expected else { return .function }
        let matching = overloads.filter { fits(functionType($0), expected) }
        guard matching.count == 1 else { return .function }
        expr = .chosen(expr, overload: matching[0].index)
        return functionType(matching[0])
    }

    private func type(of value: Value) -> TypeAnnotation {
        switch value {
        case .nothing: .optional(.unknown)
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        case .filesize: .filesize
        case .date: .date
        case .output: .output
        case .list(let items): .list(commonType(items.map(type(of:))) ?? .unknown)
        case .dictionary(let dictionary):
            .dictionary(commonType(dictionary.keys.map(type(of:))) ?? .unknown,
                        commonType(dictionary.values.map(type(of:))) ?? .unknown)
        case .record(let record):
            if let name = record.typeName {
                structInfo(named: name) != nil ? .named(name) : .record
            } else {
                .tuple(record.map { .init(label: Record.isPosition($0.key) ? nil : $0.key, type: type(of: $0.value)) })
            }
        case .enumValue(let value): .named(value.type.name)
        case .object(is Job): .named("Job")
        case .object: .unknown
        case .function: .function
        @unknown default: .unknown
        }
    }

    /// The one type all of `types` fit, if there is one.
    private func commonType(_ types: [TypeAnnotation]) -> TypeAnnotation? {
        guard var common = types.first else { return nil }
        for type in types.dropFirst() {
            if fits(type, common) { continue }
            if fits(common, type) { common = type; continue }
            if common == .unknown || type == .unknown { common = .unknown; continue }
            return nil
        }
        return common
    }

    private func listType(_ items: inout [Expr], expected: TypeAnnotation?) throws -> TypeAnnotation {
        if case .list(let element)? = expected {
            for index in items.indices { try expect(&items[index], element, "a list element") }
            return .list(element)
        }
        if let expected, expected == .any || expected == .unknown {
            for index in items.indices { _ = try typeOf(&items[index]) }
            return expected
        }
        guard !items.isEmpty else { throw TypeError("an empty list needs a type: let xs: [Int] = []") }
        // `[1, 2.5]` is a [Double], as in Swift.
        var natural: [TypeAnnotation] = []
        for index in items.indices { natural.append(try typeOf(&items[index])) }
        let wantsDouble = natural.contains(.double)
        var types: [TypeAnnotation] = []
        for index in items.indices { types.append(wantsDouble ? try typeOf(&items[index], expecting: .double) : natural[index]) }
        guard let element = commonType(types) else {
            throw TypeError("a list's elements must have one type, not \(Set(types.map(\.description)).sorted().joined(separator: " and ")); write its type, like [Any]")
        }
        return .list(element)
    }

    private func dictionaryType(_ entries: inout [RecordEntry], expected: TypeAnnotation?) throws -> TypeAnnotation {
        if case .dictionary(let key, let value)? = expected {
            for index in entries.indices {
                try expect(&entries[index].key, key, "a key")
                try expect(&entries[index].value, value, "a value")
            }
            return .dictionary(key, value)
        }
        guard !entries.isEmpty else { throw TypeError("an empty dictionary needs a type: let d: [String: Int] = [:]") }
        var keys: [TypeAnnotation] = []
        var values: [TypeAnnotation] = []
        for index in entries.indices {
            keys.append(try typeOf(&entries[index].key))
            values.append(try typeOf(&entries[index].value))
        }
        guard let key = commonType(keys) else { throw TypeError("a dictionary's keys must have one type") }
        guard let value = commonType(values) else {
            throw TypeError("a dictionary's values must have one type, not \(Set(values.map(\.description)).sorted().joined(separator: " and ")); for a record, write a tuple, like (name: \"x\", size: 2.mb)")
        }
        return .dictionary(key, value)
    }

    // MARK: Closures

    private func functionType(_ signature: Signature) -> TypeAnnotation {
        .functionType(signature.parameters.map { $0.variadic ? .list($0.type) : $0.type }, signature.returns,
                      throws: signature.isThrowing)
    }

    /// A closure's type. Parameters without a type take the ones the context
    /// expects (`filter` expects `(Element) -> Bool`), or aren't known; its
    /// result is what the context expects, what it says, or what its
    /// `return`s give; it throws if its body can.
    private func closureType(_ closure: inout ClosureLiteral, expecting expected: TypeAnnotation?) throws -> TypeAnnotation {
        var expectedParameters: [TypeAnnotation]?
        var expectedResult: TypeAnnotation?
        if case .functionType(let parameters, let result, _)? = expected, parameters.count == closure.parameters.count {
            expectedParameters = parameters
            expectedResult = result
        }
        var names: [String: Symbol] = [:]
        var parameterTypes: [TypeAnnotation] = []
        for (index, parameter) in closure.parameters.enumerated() {
            let type = parameter.type == .any ? expectedParameters?[index] ?? .unknown : parameter.type
            parameterTypes.append(type)
            names[parameter.name] = .variable(type, mutable: false)
        }
        let declared = closure.returnType ?? (expectedResult == .unknown ? nil : expectedResult)
        let context = ReturnContext(declared: declared == .void ? nil : declared)
        let sitesBefore = throwingSites
        let tryBefore = tryDepth
        returns.append(context)
        errorContexts.append(ErrorContext(handled: true, function: nil))
        scopes.append(names)
        tryDepth = 0 // A `try` outside doesn't reach in.
        defer {
            returns.removeLast()
            errorContexts.removeLast()
            scopes.removeLast()
            tryDepth = tryBefore
            // Throwing is what calling it does, not making it.
            throwingSites = sitesBefore
        }

        var result: TypeAnnotation
        if var expr = implicitReturn(closure.body) {
            let type = try typeOf(&expr, expecting: declared)
            closure.body.statements[0] = .chain(Chain(first: .expression(expr)))
            if let declared, !fits(type, declared) {
                throw TypeError("the closure must return \(declared), not \(type)")
            }
            result = closure.returnType ?? declared ?? type
        } else {
            try checkBlock(&closure.body)
            result = declared ?? commonType(context.seen) ?? (context.seen.isEmpty ? .void : .unknown)
        }
        return .functionType(parameterTypes, result, throws: throwingSites > sitesBefore)
    }

    // MARK: Calls

    private func callType(_ callee: inout Expr, _ arguments: inout [Argument], expected: TypeAnnotation?) throws -> TypeAnnotation {
        // `Point(x: 1)`, `Level(rawValue: 2)`, `f(x)`.
        if case .variable(let name) = callee, let symbol = lookup(name) {
            switch symbol {
            case .structType(let info):
                let candidates = info.initializers.isEmpty ? [info.memberwise] : info.initializers
                let chosen = try resolve(candidates, &arguments, name: name)
                if let chosen, !info.initializers.isEmpty { callee = .chosen(callee, overload: chosen.index) }
                if let chosen, chosen.isThrowing { try throwingSite("\(name).init") }
                return .named(name)
            case .enumType(let info):
                guard arguments.count == 1, arguments[0].label == "rawValue" else {
                    throw TypeError("\(name) is made from a raw value: \(name)(rawValue: …)")
                }
                guard let rawType = info.rawType else { throw TypeError("\(name) has no raw values") }
                try expect(&arguments[0].value, rawType, "the raw value")
                return .optional(.named(name))
            case .functions(let overloads):
                return try call(overloads, callee: &callee, &arguments, name: name)
            default:
                break
            }
        }
        // `x?.f()`: the method's result, or nil.
        if case .optionalMember(var baseExpr, let name) = callee {
            let wrapped = try optionalBase(&baseExpr)
            var member = Expr.member(.annotated(.literal(.nothing), .optional(wrapped)), name)
            let result = try methodCallType(wrapped, baseExpr: nil, name, &member, &arguments)
            callee = .optionalMember(baseExpr, name)
            if case .optional = result { return result }
            return result == .unknown || result == .void ? result : .optional(result)
        }
        if case .member(var baseExpr, let name) = callee {
            // `Result.failed(code: 2)`: a case with associated values.
            if case .variable(let typeName) = baseExpr, case .enumType(let info)? = lookup(typeName) {
                var payload: [Argument]? = arguments
                let type = try caseType(name, &payload, expected: .named(info.name))
                arguments = payload ?? []
                return type
            }
            if case .variable(let module) = baseExpr, case .module? = lookup(module) {
                for index in arguments.indices { _ = try typeOf(&arguments[index].value, expecting: .unknown) }
                return .unknown
            }
            let base = try typeOf(&baseExpr)
            callee = .member(baseExpr, name)
            return try methodCallType(base, baseExpr: baseExpr, name, &callee, &arguments)
        }
        let type = try typeOf(&callee)
        return try apply(type, &arguments, name: "the function")
    }

    /// A call to a named function: the overload is chosen here.
    private func call(_ overloads: [Signature], callee: inout Expr, _ arguments: inout [Argument], name: String) throws -> TypeAnnotation {
        guard let chosen = try resolve(overloads, &arguments, name: name) else {
            // Which one isn't known until it runs (an argument isn't typed yet).
            return commonReturn(overloads)
        }
        if overloads.count > 1 { callee = .chosen(callee, overload: chosen.index) }
        if chosen.isThrowing { try throwingSite("'\(name)'") }
        return chosen.returns
    }

    private func commonReturn(_ overloads: [Signature]) -> TypeAnnotation {
        overloads.allSatisfy { $0.returns == overloads[0].returns } ? overloads[0].returns : .unknown
    }

    /// `base.name(arguments)` for a receiver of type `base`; `baseExpr` is
    /// where it came from, if it can be changed by a mutating method.
    private func methodCallType(
        _ base: TypeAnnotation, baseExpr: Expr?, _ name: String, _ callee: inout Expr, _ arguments: inout [Argument]
    ) throws -> TypeAnnotation {
        if case .named(let structName) = base, let info = structInfo(named: structName), let methods = info.methods[name] {
            guard let chosen = try resolve(methods, &arguments, name: name) else { return commonReturn(methods) }
            if methods.count > 1 { callee = .chosen(callee, overload: chosen.index) }
            if let baseExpr, chosen.isMutating { try checkMutable(baseExpr, method: name) }
            if chosen.isThrowing { try throwingSite("'\(name)'") }
            return chosen.returns
        }
        if let sequenceResult = try sequenceMethodType(name, on: base, &arguments) {
            return sequenceResult
        }
        let member = try memberType(of: base, name)
        return try apply(member, &arguments, name: name)
    }

    /// Calling a value of type `type`.
    private func apply(_ type: TypeAnnotation, _ arguments: inout [Argument], name: String) throws -> TypeAnnotation {
        switch type {
        case .functionType(let parameters, let result, let throwing):
            let signature = Signature(name: name, parameters: parameters.map { Parameter(label: nil, name: "_", type: $0) },
                                      returns: result, isThrowing: throwing)
            _ = try resolve([signature], &arguments, name: name)
            if throwing { try throwingSite(name) }
            return result
        case .function, .unknown, .any:
            for index in arguments.indices { _ = try typeOf(&arguments[index].value, expecting: .unknown) }
            return .unknown
        default:
            throw TypeError("\(type) isn't a function")
        }
    }

    /// A mutating method changes its receiver, which must be a `var` (or
    /// part of one).
    private func checkMutable(_ base: Expr, method: String) throws {
        var root = base
        while true {
            switch root {
            case .member(let inner, _), .index(let inner, _): root = inner
            case .variable(let name):
                if case .variable(_, let mutable)? = lookup(name), !mutable {
                    throw TypeError("cannot use mutating method '\(method)' on '\(name)': it's a 'let' constant")
                }
                return
            default:
                throw TypeError("cannot use mutating method '\(method)' on a value that isn't in a variable")
            }
        }
    }

    // MARK: Overloads

    /// The candidate a call uses, by Swift's rules: of those whose labels,
    /// defaults and types fit, the one whose parameters match the arguments
    /// most exactly. A tie is ambiguous, unless an argument's type isn't
    /// known yet, when nil leaves the choice to run time.
    private func resolve(_ candidates: [Signature], _ arguments: inout [Argument], name: String) throws -> Signature? {
        var fitting: [(signature: Signature, cost: Int, uncertain: Bool, arguments: [Argument], sites: Int)] = []
        var firstError: TypeError?
        let sitesBefore = throwingSites
        for candidate in candidates {
            var attempt = arguments
            throwingSites = sitesBefore
            do {
                let (cost, uncertain) = try match(&attempt, to: candidate)
                fitting.append((candidate, cost, uncertain, attempt, throwingSites))
            } catch let error as TypeError {
                firstError = firstError ?? error
            }
        }
        throwingSites = sitesBefore
        guard let best = fitting.map(\.cost).min() else {
            if candidates.count == 1, let firstError { throw firstError }
            let list = candidates.map { "  " + describe($0) }
            throw TypeError("\(name): no overload accepts these arguments; candidates:\n" + list.joined(separator: "\n"))
        }
        let winners = fitting.filter { $0.cost == best }
        if winners.count > 1 {
            if winners.contains(where: \.uncertain) { return nil }
            throw TypeError("\(name): ambiguous call; these overloads all match:\n"
                            + winners.map { "  " + describe($0.signature) }.joined(separator: "\n"))
        }
        arguments = winners[0].arguments
        throwingSites = winners[0].sites
        return winners[0].signature
    }

    private func describe(_ signature: Signature) -> String {
        "\(signature.name)(" + signature.parameters.map { "\($0.label ?? "_"): \($0.type)" }.joined(separator: ", ") + ")"
    }

    /// Matches `arguments` to `signature`'s parameters by Swift's rules for
    /// labels, defaults, variadics and trailing closures. The cost counts
    /// conversions (a literal Int as a Double, a value made optional, an
    /// Output as its text) and untyped parameters, which match anything.
    private func match(_ arguments: inout [Argument], to signature: Signature) throws -> (cost: Int, uncertain: Bool) {
        let name = signature.name
        var cost = 0
        var uncertain = false
        var index = 0
        func take(_ parameter: Parameter) throws {
            let natural = TypeChecker.hasNaturalType(arguments[index].value) ? try typeOf(&arguments[index].value) : nil
            try expect(&arguments[index].value, parameter.type, "\(name): '\(parameter.name)'")
            switch (natural, parameter.type) {
            case (.unknown?, _): uncertain = true
            case (_, .any), (_, .unknown), (_, .function), (_, .record): cost += 3
            case (let type?, let wanted) where type != wanted: cost += 1
            default: break
            }
            index += 1
        }
        for (position, parameter) in signature.parameters.enumerated() {
            let later = signature.parameters[(position + 1)...]
            let trailing = index == arguments.count - 1 && arguments[index].label == nil && parameter.label != nil
                && later.allSatisfy { $0.label != nil } && parameter.type.acceptsFunction
                && { if case .closure = arguments[index].value { true } else { false } }()
            if index < arguments.count, arguments[index].label == parameter.label || trailing {
                if parameter.variadic {
                    repeat { try take(parameter) } while index < arguments.count && arguments[index].label == nil
                } else {
                    try take(parameter)
                }
            } else if parameter.variadic || parameter.hasDefault {
                continue
            } else {
                let label = parameter.label.map { "'\($0):'" } ?? "#\(position + 1)"
                throw TypeError("\(name): missing argument \(label)")
            }
        }
        guard index == arguments.count else {
            let extra = arguments[index].label.map { "'\($0):'" } ?? "#\(index + 1)"
            throw TypeError("\(name): unexpected argument \(extra)")
        }
        return (cost, uncertain)
    }

    /// Whether an argument has a type of its own, apart from context: not a
    /// closure, a `.case`, `nil` or a collection literal, which take theirs
    /// from the parameter.
    private static func hasNaturalType(_ expr: Expr) -> Bool {
        switch expr {
        case .closure, .caseLiteral, .list, .record, .tuple, .literal(.nothing): false
        default: true
        }
    }

    // MARK: Sequence methods

    /// `xs.filter { … }` and the rest, until phase 3 declares them: the
    /// element type flows through, closures get it for `$0`, and a call
    /// throws if a closure passed to it can (`rethrows`).
    private func sequenceMethodType(_ name: String, on base: TypeAnnotation, _ arguments: inout [Argument]) throws -> TypeAnnotation? {
        guard shell.sequenceMethods[name] != nil else { return nil }
        let element: TypeAnnotation
        switch base {
        case .list(let type): element = type
        case .output: element = .string
        case .unknown, .any: element = .unknown
        default: return nil
        }
        var closureResult: TypeAnnotation = .unknown
        var closureThrows = false
        for index in arguments.indices {
            let wanted: TypeAnnotation? = switch (name, arguments[index].label) {
            case ("filter", nil), ("count", "where"), ("count", nil): .functionType([element], .bool)
            case ("map", nil): .functionType([element], .unknown)
            case ("sorted", "by"), ("sorted", nil): .functionType([element, element], .bool)
            default: nil
            }
            // A closure, or a function by name: `xs.map(double)`.
            if case .functionType(_, let result, let throwing) = try typeOf(&arguments[index].value, expecting: wanted) {
                if name == "map" { closureResult = result }
                closureThrows = closureThrows || throwing
            }
        }
        if closureThrows { try throwingSite("'\(name)'") }
        switch name {
        case "count": return .int
        case "map": return .list(closureResult)
        case "select", "get": return .list(.unknown)
        default: return .list(element)
        }
    }

    // MARK: Members

    private func memberType(_ baseExpr: inout Expr, _ name: String) throws -> TypeAnnotation {
        if case .variable(let typeName) = baseExpr, let symbol = lookup(typeName) {
            switch symbol {
            case .enumType(let info):
                if name == "allCases" {
                    guard info.cases.allSatisfy({ $0.payload.isEmpty }) else {
                        throw TypeError("\(info.name) has no allCases: some cases have associated values")
                    }
                    return .list(.named(info.name))
                }
                var none: [Argument]?
                return try caseType(name, &none, expected: .named(info.name))
            case .environment:
                return .optional(.string)
            case .module:
                return .unknown
            default:
                break
            }
        }
        return try memberType(of: try typeOf(&baseExpr), name)
    }

    private func memberType(of base: TypeAnnotation, _ name: String) throws -> TypeAnnotation {
        if name == "description" || name == "debugDescription" {
            if case .named(let structName) = base, let info = structInfo(named: structName),
               let property = info.property(name) { return property.type ?? .unknown }
            return .string
        }
        switch base {
        case .unknown, .any, .record:
            return .unknown
        case .optional:
            throw TypeError("\(base) might be nil: unwrap it (if let, ??, ?. or !) before using .\(name)")
        case .named(let typeName):
            if let info = structInfo(named: typeName) {
                if let property = info.property(name) { return property.type ?? .unknown }
                if let computed = info.computed[name] { return computed }
                if let methods = info.methods[name] { return methods.count == 1 ? functionType(methods[0]) : .function }
                throw TypeError("\(typeName) has no member '\(name)'")
            }
            if let info = enumInfo(named: typeName) {
                if name == "rawValue" {
                    guard let raw = info.rawType else { throw TypeError("\(typeName) has no raw values") }
                    return raw
                }
                throw TypeError("\(typeName) has no member '\(name)'")
            }
            if let members = TypeChecker.builtinMembers[typeName] {
                guard let type = members[name] else { throw TypeError("\(typeName) has no member '\(name)'") }
                return type
            }
            return .unknown
        case .tuple(let elements):
            guard let element = tupleElement(name, of: elements) else { throw TypeError("\(base) has no element '\(name)'") }
            return element
        default:
            break
        }
        let members: [String: TypeAnnotation]
        switch base {
        case .output:
            members = ["text": .string, "lines": .list(.string), "count": .int, "isEmpty": .bool,
                       "first": .optional(.string), "last": .optional(.string), "status": TypeChecker.status]
        case .list(let element):
            members = ["count": .int, "isEmpty": .bool, "first": .optional(element), "last": .optional(element)]
        case .dictionary(let key, let value):
            members = ["count": .int, "isEmpty": .bool, "keys": .list(key), "values": .list(value)]
        case .string:
            members = ["count": .int, "isEmpty": .bool, "lines": .list(.string)]
        case .filesize:
            members = ["bytes": .int]
        default:
            members = [:]
        }
        guard let type = members[name] else { throw TypeError("\(base) has no member '\(name)'") }
        return type
    }

    private func tupleElement(_ name: String, of elements: [TypeAnnotation.TupleElement]) -> TypeAnnotation? {
        if let position = Int(name), elements.indices.contains(position) { return elements[position].type }
        return elements.first { $0.label == name }?.type
    }

    static let status = TypeAnnotation.tuple([
        .init(label: "code", type: .optional(.int)), .init(label: "signal", type: .optional(.int)), .init(label: "succeeded", type: .bool),
    ])

    /// The members of the shell's own types that aren't structs.
    static let builtinMembers: [String: [String: TypeAnnotation]] = [
        "Job": [
            "id": .int, "command": .string, "state": .named("JobState"), "pids": .list(.int), "output": .optional(.output),
            "resume": .functionType([], .void), "cancel": .functionType([], .void),
        ],
        "Error": ["message": .string, "status": status, "text": .string],
    ]

    private func caseType(_ name: String, _ arguments: inout [Argument]?, expected: TypeAnnotation?) throws -> TypeAnnotation {
        var target = expected
        if case .optional(let wrapped)? = target { target = wrapped }
        guard let target, target != .unknown, target != .any else {
            if target == nil { throw TypeError(".\(name) needs a type here; write the enum's name too, as in Kind.\(name)") }
            for index in (arguments ?? []).indices { _ = try typeOf(&arguments![index].value, expecting: .unknown) }
            return .unknown
        }
        guard case .named(let enumName) = target, let info = enumInfo(named: enumName) else {
            throw TypeError(".\(name) is a case, but a \(target) is wanted here")
        }
        guard let payload = info.payload(of: name) else { throw TypeError("\(enumName) has no case '\(name)'") }
        guard arguments != nil else {
            guard payload.isEmpty else {
                let labels = payload.map { ($0.label ?? "_") + ":" }.joined()
                throw TypeError("\(enumName).\(name) needs its associated values: \(enumName).\(name)(\(labels))")
            }
            return .named(enumName)
        }
        guard !payload.isEmpty else { throw TypeError("\(enumName).\(name) has no associated values") }
        guard arguments!.count == payload.count else {
            throw TypeError("\(enumName).\(name) has \(payload.count) associated values, not \(arguments!.count)")
        }
        for index in arguments!.indices {
            guard arguments![index].label == payload[index].label else {
                let wanted = payload[index].label.map { "'\($0):'" } ?? "no label"
                throw TypeError("\(enumName).\(name): value #\(index + 1) needs \(wanted)")
            }
            try expect(&arguments![index].value, payload[index].type, "\(enumName).\(name): value #\(index + 1)")
        }
        return .named(enumName)
    }

    private func indexType(_ baseExpr: inout Expr, _ index: inout Expr) throws -> TypeAnnotation {
        if case .variable(let name) = baseExpr, case .environment? = lookup(name) {
            try expect(&index, .string, "an environment variable's name")
            return .optional(.string)
        }
        let base = try typeOf(&baseExpr)
        switch base {
        case .list(let element):
            try expect(&index, .int, "a list's index")
            return element
        case .output:
            try expect(&index, .int, "a line's index")
            return .string
        case .dictionary(let key, let value):
            try expect(&index, key, "the key")
            return .optional(value)
        case .unknown, .any, .record:
            _ = try typeOf(&index)
            return .unknown
        default:
            throw TypeError("\(base) can't be indexed")
        }
    }

    // MARK: Operators

    private func binaryExprType(_ op: BinaryOperator, _ lhs: inout Expr, _ rhs: inout Expr, expected: TypeAnnotation?) throws -> TypeAnnotation {
        switch op {
        case .and, .or:
            try expect(&lhs, .bool, "'\(op.rawValue)''s left side")
            try expect(&rhs, .bool, "'\(op.rawValue)''s right side")
            return .bool
        case .coalesce:
            let left = try typeOf(&lhs)
            guard case .optional(let wrapped) = left else {
                // Never nil, so the right side is never used; Swift allows it too.
                _ = try typeOf(&rhs, expecting: left)
                return left
            }
            let right = try typeOf(&rhs, expecting: wrapped == .unknown ? expected : wrapped)
            if wrapped == .unknown { return right }
            // An Output or some text: the Output's text.
            if wrapped == .output, right == .string, Interpreter.isStringExpression(rhs) { return .string }
            if fits(right, wrapped) { return wrapped }
            if fits(right, left) { return left }
            throw TypeError("'??' needs a \(wrapped) on its right, not \(right)")
        case .equal, .notEqual:
            // A `.case` on one side takes the other side's type.
            let (left, right) = try operandTypes(&lhs, &rhs)
            guard fits(left, right) || fits(right, left) || left == .output && right == .string || left == .string && right == .output else {
                throw TypeError("can't compare \(left) with \(right)")
            }
            return .bool
        default:
            let (left, right) = try operandTypes(&lhs, &rhs)
            return try binaryType(op, left, right)
        }
    }

    /// Both sides' types, letting a literal or `.case` on one side take its
    /// type from the other, as Swift does: `1 + 2.5`, `k == .file`.
    private func operandTypes(_ lhs: inout Expr, _ rhs: inout Expr) throws -> (TypeAnnotation, TypeAnnotation) {
        if case .caseLiteral = lhs, !TypeChecker.isContextual(rhs) {
            let right = try typeOf(&rhs)
            return (try typeOf(&lhs, expecting: right), right)
        }
        var rightFirst: TypeAnnotation?
        if TypeChecker.isIntegerLiteral(lhs) {
            var probe = rhs
            rightFirst = try? typeOf(&probe)
        }
        let left = try typeOf(&lhs, expecting: rightFirst)
        let right = try typeOf(&rhs, expecting: left)
        if right == .double, TypeChecker.isIntegerLiteral(lhs) { return (.double, .double) }
        return (left, right)
    }

    private static func isContextual(_ expr: Expr) -> Bool {
        if case .caseLiteral = expr { true } else { false }
    }

    private static func isIntegerLiteral(_ expr: Expr) -> Bool {
        switch expr {
        case .literal(.int): true
        case .unary(.negate, let inner): isIntegerLiteral(inner)
        default: false
        }
    }

    private func binaryType(_ op: BinaryOperator, _ left: TypeAnnotation, _ right: TypeAnnotation) throws -> TypeAnnotation {
        if left == .unknown || right == .unknown {
            switch op {
            case .less, .lessEqual, .greater, .greaterEqual: return .bool
            case .closedRange, .halfOpenRange: return .list(.int)
            default: return left == .unknown ? right : left
            }
        }
        let fail = TypeError("'\(op.rawValue)' can't be applied to \(left) and \(right)")
        switch op {
        case .less, .lessEqual, .greater, .greaterEqual:
            guard left == right, [.int, .double, .string, .filesize, .date].contains(left) else { throw fail }
            return .bool
        case .closedRange, .halfOpenRange:
            guard left == .int, right == .int else { throw fail }
            return .list(.int)
        case .add:
            switch (left, right) {
            case (.int, .int), (.double, .double), (.string, .string), (.filesize, .filesize): return left
            case (.list(let a), .list(let b)) where fits(b, a): return left
            default: throw fail
            }
        case .subtract:
            switch (left, right) {
            case (.int, .int), (.double, .double), (.filesize, .filesize): return left
            case (.date, .date): return .double
            default: throw fail
            }
        case .multiply:
            switch (left, right) {
            case (.int, .int), (.double, .double): return left
            case (.filesize, .int), (.filesize, .double): return .filesize
            case (.int, .filesize), (.double, .filesize): return .filesize
            default: throw fail
            }
        case .divide:
            switch (left, right) {
            case (.int, .int), (.double, .double): return left
            case (.filesize, .int), (.filesize, .double): return .filesize
            case (.filesize, .filesize): return .double
            default: throw fail
            }
        case .remainder:
            guard left == .int, right == .int else { throw fail }
            return .int
        default:
            throw fail
        }
    }

    // MARK: Fitting

    /// Whether a value of type `actual` can be used where `expected` is.
    func fits(_ actual: TypeAnnotation, _ expected: TypeAnnotation) -> Bool {
        if actual == expected || actual == .unknown || expected == .unknown || expected == .any { return true }
        switch (actual, expected) {
        case (.optional(let a), .optional(let b)): return fits(a, b)
        case (_, .optional(let wrapped)): return fits(actual, wrapped)
        case (.list(let a), .list(let b)): return fits(a, b)
        case (.dictionary(let ak, let av), .dictionary(let bk, let bv)): return fits(ak, bk) && fits(av, bv)
        case (.tuple(let a), .tuple(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { x, y in
                (x.label == nil || y.label == nil || x.label == y.label) && fits(x.type, y.type)
            }
        case (.functionType, .function), (.function, .functionType): return true
        case (.functionType(let ap, let ar, let athrows), .functionType(let bp, let br, let bthrows)):
            // A function that throws can't be passed where one that doesn't is wanted.
            return ap.count == bp.count && zip(bp, ap).allSatisfy { fits($0, $1) }
                && (br == .void || fits(ar, br)) && (!athrows || bthrows)
        // A struct's value is a record, as builtins that take any record see it.
        case (.named(let name), .record): return structInfo(named: name) != nil
        case (.tuple, .record): return true
        // An Output is its text where a String is wanted, and its lines
        // where a [String] is.
        case (.output, .string), (.output, .list(.string)): return true
        default: return false
        }
    }

    /// The type of each item when iterating `type`.
    private func elementType(of type: TypeAnnotation) throws -> TypeAnnotation {
        switch type {
        case .list(let element): return element
        case .output, .string: return .string
        case .dictionary(let key, let value):
            return .tuple([.init(label: "key", type: key), .init(label: "value", type: value)])
        case .unknown, .any: return .unknown
        default: throw TypeError("can't iterate over \(type)")
        }
    }

    // MARK: Names

    private func lookup(_ name: String) -> Symbol? {
        for scope in scopes.reversed() {
            if let symbol = scope[name] { return symbol }
        }
        guard let binding = shell.lookup(name) else { return nil }
        switch binding.special {
        case .environment?: return .environment
        case .jobs?: return .variable(.list(.named("Job")), mutable: false)
        default: break
        }
        switch binding.value {
        case .object(let type as StructType):
            return .structType(structInfo(type))
        case .object(let type as EnumType):
            return .enumType(enumInfo(type))
        case .object(is Module):
            return .module
        case .function(let set as OverloadSet):
            return .functions(set.candidates.enumerated().map { index, function in
                var signature = signature(function)
                signature.index = index
                return signature
            })
        default:
            return .variable(shell.staticTypes[name] ?? type(of: binding.value), mutable: binding.mutable)
        }
    }

    private func signature(_ function: Function) -> Signature {
        // A builtin that hasn't declared its result isn't known; a Swish
        // function without `->` returns nothing.
        var returns = function.returnType ?? (function.isBuiltin ? .unknown : .void)
        if function.plugin != nil && returns == .any { returns = .unknown }
        return Signature(name: function.name ?? "closure", parameters: function.parameters, returns: returns,
                         isMutating: function.isMutating, isThrowing: function.isThrowing)
    }

    private func structInfo(named name: String) -> StructInfo? {
        if case .structType(let info)? = lookup(name) { return info }
        return nil
    }

    private func enumInfo(named name: String) -> EnumInfo? {
        if case .enumType(let info)? = lookup(name) { return info }
        return nil
    }

    private func structInfo(_ type: StructType) -> StructInfo {
        var methods: [String: [Signature]] = [:]
        for (name, set) in type.methods {
            methods[name] = set.candidates.enumerated().map { index, method in
                var signature = signature(method)
                signature.index = index
                return signature
            }
        }
        return StructInfo(
            name: type.name, stored: type.stored,
            computed: type.computed.mapValues { $0.returnType ?? .unknown },
            methods: methods,
            initializers: type.initializers?.candidates.enumerated().map { index, initializer in
                Signature(name: initializer.name ?? type.name, parameters: initializer.parameters, returns: .named(type.name),
                          isMutating: true, isThrowing: initializer.isThrowing, index: index)
            } ?? [],
            memberwise: Signature(name: type.name, parameters: type.memberwise.parameters, returns: .named(type.name))
        )
    }

    private func enumInfo(_ type: EnumType) -> EnumInfo {
        let payloads = shell.enumPayloadTypes[ObjectIdentifier(type)] ?? [:]
        let cases = type.cases.map { enumCase in
            (enumCase.name, zip(enumCase.labels, payloads[enumCase.name] ?? enumCase.labels.map { _ in .unknown })
                .map { AssociatedValue(label: $0, type: $1) })
        }
        let rawType: TypeAnnotation? = switch type.cases.first?.rawValue {
        case .int?: .int
        case .string?: .string
        case .double?: .double
        default: nil
        }
        return EnumInfo(name: type.name, cases: cases, rawType: rawType)
    }
}
