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
/// Phase 1 of the plan: commands, pipelines and builtins' results are
/// `unknown` for now, which fits anywhere, so nothing that ran before is
/// refused for lack of a type.
final class TypeChecker {
    struct Signature {
        var name: String
        var parameters: [Parameter]
        var returns: TypeAnnotation
        var isMutating = false
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

    private unowned let shell: Shell
    /// What the program declares, innermost last, on top of the shell's names.
    private var scopes: [[String: Symbol]] = [[:]]
    /// The return type of each function being checked, innermost last.
    private var returnTypes: [TypeAnnotation] = []
    /// After an `import`, names it may bring can't be checked.
    private var afterImport = false
    private var line: Int?

    init(shell: Shell) {
        self.shell = shell
    }

    /// Checks a program, with the line of the statement a problem is in.
    func check(_ program: Program) throws(TypeError) {
        do {
            try checkBlock(program)
        } catch var error as TypeError {
            error.line = error.line ?? line
            throw error
        } catch {
            preconditionFailure("the checker only throws TypeError")
        }
    }

    /// The types of the globals a checked program declared, for the next
    /// entry at the prompt.
    var declaredGlobals: [String: TypeAnnotation] {
        scopes[0].compactMapValues { if case .variable(let type, _) = $0 { type } else { nil } }
    }

    // MARK: Statements

    private func checkBlock(_ program: Program, declaring names: [String: Symbol] = [:], newScope: Bool = false) throws {
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
        for (index, statement) in program.statements.enumerated() {
            if index < program.lines.count { line = program.lines[index] }
            try checkStatement(statement)
        }
    }

    private func checkStatement(_ statement: Statement) throws {
        switch statement {
        case .declare(let name, let mutable, let value):
            var type = try typeOf(value)
            if type == .optional(.unknown), case .literal(.nothing) = value {
                throw TypeError("'nil' needs a type: let \(name): T? = nil")
            }
            if case .tuple([]) = type { type = .void }
            scopes[scopes.count - 1][name] = .variable(type, mutable: mutable)
        case .assign(let assignment):
            try checkAssignment(assignment)
        case .function(let decl):
            try checkFunction(decl)
        case .setEnvironment(let name, let value):
            try expect(name, .string, "an environment variable's name")
            _ = try typeOf(value)
        case .doCatch(let body, let errorName, let handler):
            try checkBlock(body, newScope: true)
            if let handler {
                try checkBlock(handler, declaring: [errorName: .variable(.named("Error"), mutable: false)], newScope: true)
            }
        case .enumDecl(let decl):
            try checkEnum(decl)
        case .structDecl(let decl):
            try checkStruct(decl)
        case .importPlugin(let name, let path):
            try expect(path, .string, "an import's path")
            scopes[scopes.count - 1][name] = .module
            afterImport = true
        case .returnStatement(let value):
            guard let expected = returnTypes.last else { return }
            if let value {
                if expected == .void { throw TypeError("a function without '->' returns nothing, so 'return' takes no value") }
                try expect(value, expected, "the returned value")
            } else if expected != .void && expected != .unknown {
                throw TypeError("this function must return \(expected)")
            }
        case .fallthroughStatement, .breakStatement, .continueStatement:
            break
        case .chain(let chain):
            try checkChain(chain, condition: false)
        }
    }

    private func checkChain(_ chain: Chain, condition: Bool) throws {
        try checkUnit(chain.first, condition: condition || !chain.links.isEmpty)
        for link in chain.links { try checkUnit(link.unit, condition: true) }
    }

    /// `condition`: the unit's status decides something, as in `if` or
    /// `&&`: an expression there must be a Bool, an Output, or optional.
    private func checkUnit(_ unit: Unit, condition: Bool) throws {
        switch unit {
        case .pipeline(let pipeline):
            try checkPipeline(pipeline)
        case .expression(let expr):
            let type = try typeOf(expr)
            if condition {
                switch type {
                case .bool, .output, .optional, .unknown: break
                default: throw TypeError("a condition must be a Bool, not \(type)")
                }
            }
        case .ifStatement(let node):
            try checkIf(node)
        case .switchStatement(let node):
            try checkSwitch(node)
        case .forLoop(let loop):
            let element = try elementType(of: try typeOf(loop.sequence), iterating: true)
            try checkBlock(loop.body, declaring: [loop.variable: .variable(element, mutable: false)], newScope: true)
        case .whileLoop(let loop):
            try checkChain(loop.condition, condition: true)
            try checkBlock(loop.body, newScope: true)
        }
    }

    private func checkIf(_ node: IfStatement) throws {
        var bound: [String: Symbol] = [:]
        switch node.condition {
        case .chain(let chain):
            try checkChain(chain, condition: true)
        case .binding(let name, let mutable, let value):
            let type = try typeOf(value)
            guard case .optional(let wrapped) = type else {
                if type == .unknown {
                    bound[name] = .variable(.unknown, mutable: mutable)
                    break
                }
                throw TypeError("'if let' unwraps an optional, but this is \(type)")
            }
            bound[name] = .variable(wrapped, mutable: mutable)
        case .pattern(let pattern, let value):
            try checkPattern(pattern, against: try typeOf(value), binding: &bound)
        }
        try checkBlock(node.then, declaring: bound, newScope: true)
        if let otherwise = node.otherwise { try checkBlock(otherwise, newScope: true) }
    }

    private func checkSwitch(_ node: SwitchStatement) throws {
        let subject = try typeOf(node.subject)
        for switchCase in node.cases {
            var bound: [String: Symbol] = [:]
            for pattern in switchCase.patterns { try checkPattern(pattern, against: subject, binding: &bound) }
            scopes.append(bound)
            defer { scopes.removeLast() }
            if let guardExpr = switchCase.guardExpr { try expect(guardExpr, .bool, "a case's 'where'") }
            try checkBlock(switchCase.body, newScope: true)
        }
    }

    private func checkPattern(_ pattern: Pattern, against type: TypeAnnotation, binding bound: inout [String: Symbol]) throws {
        switch pattern {
        case .wildcard:
            break
        case .binding(let name, let mutable):
            bound[name] = .variable(type, mutable: mutable)
        case .enumCase(let typeName, let name, let arguments):
            var subject = type
            if case .optional(let wrapped) = subject { subject = wrapped }
            guard subject != .unknown else {
                for argument in arguments ?? [] { try checkPattern(argument.pattern, against: .unknown, binding: &bound) }
                return
            }
            guard case .named(let enumName) = subject, let info = enumInfo(named: enumName) else {
                throw TypeError("a case pattern like .\(name) matches an enum, not \(type)")
            }
            if let typeName, typeName != enumName {
                throw TypeError("\(typeName).\(name) can't match a \(enumName)")
            }
            guard let payload = info.payload(of: name) else { throw TypeError("\(enumName) has no case '\(name)'") }
            guard let arguments else { return }
            guard arguments.count == payload.count else {
                throw TypeError("\(enumName).\(name) has \(payload.count) associated values, not \(arguments.count)")
            }
            for (argument, value) in zip(arguments, payload) {
                try checkPattern(argument.pattern, against: value.type, binding: &bound)
            }
        case .expression(let expr):
            if case .binary(let op, let lower, let upper) = expr, op == .closedRange || op == .halfOpenRange {
                for bound in [lower, upper] { try expect(bound, type == .double ? .double : type, "a range's bound") }
                return
            }
            let valueType = try typeOf(expr, expecting: type)
            guard fits(valueType, type) || fits(type, valueType) else {
                throw TypeError("a \(valueType) can't match a \(type)")
            }
        }
    }

    // MARK: Declarations

    private func declareFunction(_ decl: FunctionDecl) {
        let signature = Signature(name: decl.name, parameters: decl.parameters, returns: decl.returnType ?? .void)
        var overloads: [Signature] = []
        if case .functions(let existing)? = scopes[scopes.count - 1][decl.name] { overloads = existing }
        overloads.removeAll { sameParameters($0.parameters, decl.parameters) }
        scopes[scopes.count - 1][decl.name] = .functions(overloads + [signature])
    }

    private func sameParameters(_ a: [Parameter], _ b: [Parameter]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.label == $1.label && $0.type == $1.type && $0.variadic == $1.variadic }
    }

    private func checkFunction(_ decl: FunctionDecl, self selfType: TypeAnnotation? = nil, mutating: Bool = false, initializing: Bool = false) throws {
        var names: [String: Symbol] = [:]
        for parameter in decl.parameters {
            if let defaultValue = parameter.defaultValue {
                try expect(defaultValue, parameter.type, "\(parameter.name)'s default")
            }
            names[parameter.name] = .variable(parameter.variadic ? .list(parameter.type) : parameter.type, mutable: false)
        }
        if let selfType { names["self"] = .variable(selfType, mutable: mutating || initializing) }
        if initializing { names["$initializing"] = .variable(.void, mutable: false) }
        let returns = decl.returnType ?? .void
        returnTypes.append(returns)
        defer { returnTypes.removeLast() }
        scopes.append(names)
        defer { scopes.removeLast() }

        // A body that's one expression is the result, when there's one.
        if returns != .void, let expr = implicitReturn(decl.body) {
            try expect(expr, returns, "\(decl.name)'s result")
            return
        }
        try checkBlock(decl.body)
        if returns != .void && returns != .unknown && !definitelyReturns(decl.body) {
            throw TypeError("\(decl.name) must return \(returns) on every path")
        }
    }

    private func implicitReturn(_ body: Program) -> Expr? {
        guard body.statements.count == 1, case .chain(let chain) = body.statements[0], chain.links.isEmpty,
              case .expression(let expr) = chain.first else { return nil }
        return expr
    }

    /// Whether running `program` always ends in a `return` (or a `try!`
    /// that stops): as simple as Swift's own check, from the last statement.
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
            methods[method.name, default: []].append(Signature(
                name: method.name, parameters: method.parameters, returns: method.returnType ?? .void, isMutating: method.isMutating
            ))
        }
        var stored: [PropertyDecl] = []
        for var property in decl.properties where property.getter == nil {
            // An untyped property takes its default's type.
            if property.type == nil, let defaultValue = property.defaultValue {
                property.type = try typeOf(defaultValue)
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
        let initializers = decl.initializers.map {
            Signature(name: "\(decl.name).init", parameters: $0.parameters, returns: .named(decl.name), isMutating: true)
        }
        return StructInfo(name: decl.name, stored: stored, computed: computed, methods: methods,
                          initializers: initializers, memberwise: memberwise)
    }

    private func checkStruct(_ decl: StructDecl) throws {
        let selfType = TypeAnnotation.named(decl.name)
        for property in decl.properties {
            if let getter = property.getter {
                let function = FunctionDecl(name: property.name, parameters: [], returnType: property.type, body: getter)
                try checkFunction(function, self: selfType)
            } else if let defaultValue = property.defaultValue, let type = property.type {
                try expect(defaultValue, type, "\(decl.name).\(property.name)'s default")
            }
        }
        for method in decl.methods { try checkFunction(method, self: selfType, mutating: method.isMutating) }
        for initializer in decl.initializers {
            var function = initializer
            function.name = "\(decl.name).init"
            try checkFunction(function, self: selfType, initializing: true)
        }
    }

    private func enumInfo(_ decl: EnumDecl) -> EnumInfo {
        EnumInfo(name: decl.name, cases: decl.cases.map { ($0.name, $0.associated) }, rawType: decl.rawType)
    }

    private func checkEnum(_ decl: EnumDecl) throws {
        guard let rawType = decl.rawType else { return }
        for enumCase in decl.cases {
            if let raw = enumCase.rawValue { try expect(raw, rawType, "\(decl.name).\(enumCase.name)'s raw value") }
        }
    }

    // MARK: Assignment

    private func checkAssignment(_ assignment: Assignment) throws {
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
        for (index, step) in assignment.path.enumerated() {
            let last = index == assignment.path.count - 1
            switch step {
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
            case .index(let indexExpr):
                switch type {
                case .list(let element):
                    try expect(indexExpr, .int, "a list's index")
                    type = element
                case .dictionary(let key, let value):
                    try expect(indexExpr, key, "the key")
                    // Assigning nil removes the entry.
                    type = last ? .optional(value) : value
                case .unknown, .record, .any:
                    _ = try typeOf(indexExpr)
                    type = .unknown
                default:
                    throw TypeError("cannot assign into \(type) by index")
                }
            }
        }
        if let op = assignment.op {
            let valueType = try typeOf(assignment.value, expecting: type)
            let result = try binaryType(op, type, valueType, lhs: nil, rhs: assignment.value)
            guard fits(result, type) else { throw TypeError("'\(op.rawValue)=' would make \(type) a \(result)") }
        } else {
            try expect(assignment.value, type, "the value assigned")
        }
    }

    // MARK: Pipelines

    /// Commands take text, and what they give isn't typed yet (phase 3);
    /// the expressions inside them are.
    private func checkPipeline(_ pipeline: PipelineNode) throws {
        // What a stage takes isn't typed yet, so an empty `[]` needs no type.
        if let input = pipeline.input { _ = try typeOf(input, expecting: .unknown) }
        for command in pipeline.commands {
            for word in command.words {
                switch word {
                case .text(let parts): try checkParts(parts)
                case .closure(let closure): _ = try closureType(closure, expecting: nil)
                }
            }
            for argument in command.call ?? [] { _ = try typeOf(argument.value) }
            for assignment in command.environment { try checkParts(assignment.value) }
            for redirect in command.redirects {
                if case .file(let parts, _) = redirect.target { try checkParts(parts) }
            }
        }
    }

    private func checkParts(_ parts: [StringPart]) throws {
        for part in parts {
            if case .expression(let expr) = part { _ = try typeOf(expr) }
        }
    }

    // MARK: Expressions

    /// `expr`'s type, which must fit `expected`.
    private func expect(_ expr: Expr, _ expected: TypeAnnotation, _ what: String) throws {
        let type = try typeOf(expr, expecting: expected)
        guard fits(type, expected) else {
            throw TypeError("\(what) must be \(expected), not \(type)")
        }
    }

    func typeOf(_ expr: Expr, expecting expected: TypeAnnotation? = nil) throws -> TypeAnnotation {
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
        case .string(let parts):
            try checkParts(parts)
            return .string
        case .variable(let name):
            guard let symbol = lookup(name) else {
                if afterImport { return .unknown }
                throw TypeError("no variable named '\(name)'")
            }
            switch symbol {
            case .variable(let type, _): return type
            case .functions(let overloads):
                return overloads.count == 1 ? functionType(overloads[0]) : .function
            case .environment: return .dictionary(.string, .string)
            case .structType, .enumType, .module: return .unknown
            }
        case .dollar(let name):
            if case .variable(let type, _)? = lookup(name) { return type }
            return .string
        case .substitution(let program, _):
            try checkBlock(program, newScope: true)
            return .output
        case .attempt(let inner, let kind):
            let type = try typeOf(inner, expecting: expected.flatMap { if case .optional(let w) = $0 { w } else { $0 } })
            guard kind == .optional else { return type }
            if case .optional = type { return type }
            return type == .void ? .optional(.tuple([])) : .optional(type)
        case .async(let target):
            switch target {
            case .command(let pipeline), .capture(let pipeline): try checkPipeline(pipeline)
            }
            return .named("Job")
        case .await(let job, _):
            if let job { try expect(job, .named("Job"), "what 'await' waits for") }
            return .output
        case .list(let items):
            return try listType(items, expected: expected)
        case .record(let entries):
            return try dictionaryType(entries, expected: expected)
        case .tuple(let elements):
            if elements.isEmpty { return .void }
            var expectedElements: [TypeAnnotation.TupleElement]?
            if case .tuple(let wanted)? = expected, wanted.count == elements.count { expectedElements = wanted }
            return .tuple(try elements.enumerated().map { index, element in
                .init(label: element.label, type: try typeOf(element.value, expecting: expectedElements?[index].type))
            })
        case .closure(let closure):
            return try closureType(closure, expecting: expected)
        case .call(let callee, let arguments):
            return try callType(callee, arguments, expected: expected)
        case .member(let base, let name):
            return try memberType(base, name, expected: expected)
        case .caseLiteral(let name, let arguments):
            return try caseType(name, arguments, expected: expected)
        case .unary(let op, let operand):
            let type = try typeOf(operand, expecting: op == .negate ? expected : .bool)
            switch (op, type) {
            case (.not, .bool), (.not, .unknown): return .bool
            case (.negate, .int), (.negate, .double), (.negate, .filesize), (.negate, .unknown): return type
            default: throw TypeError("'\(op.rawValue)' can't be applied to \(type)")
            }
        case .binary(let op, let lhs, let rhs):
            return try binaryExprType(op, lhs, rhs, expected: expected)
        case .index(let base, let index):
            return try indexType(base, index)
        case .annotated(let inner, let type):
            try expect(inner, type, "the value")
            return type
        case .forceUnwrap(let inner):
            let type = try typeOf(inner)
            if case .optional(let wrapped) = type { return wrapped }
            if type == .unknown { return .unknown }
            throw TypeError("'!' unwraps an optional, but this is \(type)")
        case .optionalMember(let base, let name):
            let wrapped = try optionalBase(base)
            let member = try memberType(of: wrapped, name, baseExpr: nil)
            if case .optional = member { return member }
            return member == .unknown ? .unknown : .optional(member)
        }
    }

    /// What `x` in `x?.name` is when it isn't nil.
    private func optionalBase(_ base: Expr) throws -> TypeAnnotation {
        let type = try typeOf(base)
        if case .optional(let wrapped) = type { return wrapped }
        if type == .unknown { return .unknown }
        throw TypeError("'?.' is for optionals; \(type) isn't one: use '.'")
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

    private func listType(_ items: [Expr], expected: TypeAnnotation?) throws -> TypeAnnotation {
        if case .list(let element)? = expected {
            for item in items { try expect(item, element, "a list element") }
            return .list(element)
        }
        if expected == .any || expected == .unknown { for item in items { _ = try typeOf(item) }; return expected! }
        guard !items.isEmpty else { throw TypeError("an empty list needs a type: let xs: [Int] = []") }
        // `[1, 2.5]` is a [Double], as in Swift.
        let wantsDouble = try items.contains { try typeOf($0) == .double }
        let types = try items.map { try typeOf($0, expecting: wantsDouble ? .double : nil) }
        guard let element = commonType(types) else {
            throw TypeError("a list's elements must have one type, not \(Set(types.map(\.description)).sorted().joined(separator: " and ")); write its type, like [Any]")
        }
        return .list(element)
    }

    private func dictionaryType(_ entries: [RecordEntry], expected: TypeAnnotation?) throws -> TypeAnnotation {
        if case .dictionary(let key, let value)? = expected {
            for entry in entries {
                try expect(entry.key, key, "a key")
                try expect(entry.value, value, "a value")
            }
            return .dictionary(key, value)
        }
        guard !entries.isEmpty else { throw TypeError("an empty dictionary needs a type: let d: [String: Int] = [:]") }
        let keys = try entries.map { try typeOf($0.key) }
        let values = try entries.map { try typeOf($0.value) }
        guard let key = commonType(keys) else { throw TypeError("a dictionary's keys must have one type") }
        guard let value = commonType(values) else {
            throw TypeError("a dictionary's values must have one type, not \(Set(values.map(\.description)).sorted().joined(separator: " and ")); for a record, write a tuple, like (name: \"x\", size: 2.mb)")
        }
        return .dictionary(key, value)
    }

    // MARK: Closures and calls

    private func functionType(_ signature: Signature) -> TypeAnnotation {
        .functionType(signature.parameters.map { $0.variadic ? .list($0.type) : $0.type }, signature.returns)
    }

    /// A closure's type. Parameters without a type take the ones the context
    /// expects (`filter` expects `(Element) -> Bool`), or aren't known.
    private func closureType(_ closure: ClosureLiteral, expecting expected: TypeAnnotation?) throws -> TypeAnnotation {
        var expectedParameters: [TypeAnnotation]?
        var expectedResult: TypeAnnotation?
        if case .functionType(let parameters, let result)? = expected, parameters.count == closure.parameters.count {
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
        let returns = closure.returnType ?? expectedResult ?? .unknown
        returnTypes.append(returns == .void ? .unknown : returns)
        defer { returnTypes.removeLast() }
        scopes.append(names)
        defer { scopes.removeLast() }
        if let expr = implicitReturn(closure.body) {
            let type = try typeOf(expr, expecting: returns == .unknown ? nil : returns)
            if closure.returnType != nil, !fits(type, returns) {
                throw TypeError("the closure must return \(returns), not \(type)")
            }
            return .functionType(parameterTypes, closure.returnType ?? (returns == .unknown ? type : returns))
        }
        try checkBlock(closure.body)
        return .functionType(parameterTypes, closure.returnType ?? returns)
    }

    private func callType(_ callee: Expr, _ arguments: [Argument], expected: TypeAnnotation?) throws -> TypeAnnotation {
        // `Point(x: 1)`, `Level(rawValue: 2)`, `f(x)`.
        if case .variable(let name) = callee, let symbol = lookup(name) {
            switch symbol {
            case .structType(let info):
                let candidates = info.initializers.isEmpty ? [info.memberwise] : info.initializers
                return try resolve(candidates, arguments, name: name)
            case .enumType(let info):
                guard arguments.count == 1, arguments[0].label == "rawValue" else {
                    throw TypeError("\(name) is made from a raw value: \(name)(rawValue: …)")
                }
                guard let rawType = info.rawType else { throw TypeError("\(name) has no raw values") }
                try expect(arguments[0].value, rawType, "the raw value")
                return .optional(.named(name))
            case .functions(let overloads):
                return try resolve(overloads, arguments, name: name)
            default:
                break
            }
        }
        // `x?.f()`: the method's result, or nil.
        if case .optionalMember(let baseExpr, let name) = callee {
            let wrapped = try optionalBase(baseExpr)
            let result = try methodCallType(wrapped, baseExpr: nil, name, arguments)
            if case .optional = result { return result }
            return result == .unknown || result == .void ? result : .optional(result)
        }
        if case .member(let baseExpr, let name) = callee {
            // `Result.failed(code: 2)`: a case with associated values.
            if case .variable(let typeName) = baseExpr, case .enumType(let info)? = lookup(typeName) {
                return try caseType(name, arguments, expected: .named(info.name))
            }
            if case .variable(let module) = baseExpr, case .module? = lookup(module) {
                for argument in arguments { _ = try typeOf(argument.value, expecting: .unknown) }
                return .unknown
            }
            return try methodCallType(try typeOf(baseExpr), baseExpr: baseExpr, name, arguments)
        }
        return try applyType(try typeOf(callee), arguments, name: "the function")
    }

    /// `base.name(arguments)` for a receiver of type `base`; `baseExpr` is
    /// where it came from, if it can be changed by a mutating method.
    private func methodCallType(
        _ base: TypeAnnotation, baseExpr: Expr?, _ name: String, _ arguments: [Argument]
    ) throws -> TypeAnnotation {
        if case .named(let structName) = base, let info = structInfo(named: structName), let methods = info.methods[name] {
            let returns = try resolve(methods, arguments, name: name)
            if let baseExpr, methods.allSatisfy(\.isMutating) { try checkMutable(baseExpr, method: name) }
            return returns
        }
        if let sequenceResult = try sequenceMethodType(name, on: base, arguments) {
            return sequenceResult
        }
        let member = try memberType(of: base, name, baseExpr: baseExpr)
        return try applyType(member, arguments, name: name)
    }

    /// Calling a value of type `type`.
    private func applyType(_ type: TypeAnnotation, _ arguments: [Argument], name: String) throws -> TypeAnnotation {
        switch type {
        case .functionType(let parameters, let result):
            let signature = Signature(name: name, parameters: parameters.map { Parameter(label: nil, name: "_", type: $0) }, returns: result)
            return try resolve([signature], arguments, name: name)
        case .function, .unknown, .any:
            for argument in arguments { _ = try typeOf(argument.value, expecting: .unknown) }
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

    /// The result of calling one of `candidates` with `arguments`, by Swift's
    /// rules for labels, defaults, variadics and trailing closures. When
    /// several fit, they must agree on the result, or it isn't known until
    /// the call runs.
    private func resolve(_ candidates: [Signature], _ arguments: [Argument], name: String) throws -> TypeAnnotation {
        var results: [TypeAnnotation] = []
        var firstError: TypeError?
        for candidate in candidates {
            do {
                try match(arguments, to: candidate)
                results.append(candidate.returns)
            } catch let error as TypeError {
                firstError = firstError ?? error
            }
        }
        guard !results.isEmpty else {
            if candidates.count == 1, let firstError { throw firstError }
            let list = candidates.map { "  \(name)(" + $0.parameters.map { "\($0.label ?? "_"): \($0.type)" }.joined(separator: ", ") + ")" }
            throw TypeError("\(name): no overload accepts these arguments; candidates:\n" + list.joined(separator: "\n"))
        }
        return results.allSatisfy { $0 == results[0] } ? results[0] : .unknown
    }

    private func match(_ arguments: [Argument], to signature: Signature) throws {
        let name = signature.name
        var index = 0
        for (position, parameter) in signature.parameters.enumerated() {
            let later = signature.parameters[(position + 1)...]
            let trailing = index == arguments.count - 1 && arguments[index].label == nil && parameter.label != nil
                && later.allSatisfy { $0.label != nil } && parameter.type.acceptsFunction
                && { if case .closure = arguments[index].value { true } else { false } }()
            if index < arguments.count, arguments[index].label == parameter.label || trailing {
                if parameter.variadic {
                    repeat {
                        try expect(arguments[index].value, parameter.type, "\(name): '\(parameter.name)'")
                        index += 1
                    } while index < arguments.count && arguments[index].label == nil
                } else {
                    try expect(arguments[index].value, parameter.type, "\(name): '\(parameter.name)'")
                    index += 1
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
    }

    /// `xs.filter { … }` and the rest, until phase 3 declares them: the
    /// element type flows through, and closures get it for `$0`.
    private func sequenceMethodType(_ name: String, on base: TypeAnnotation, _ arguments: [Argument]) throws -> TypeAnnotation? {
        guard shell.sequenceMethods[name] != nil else { return nil }
        let element: TypeAnnotation
        switch base {
        case .list(let type): element = type
        case .output: element = .string
        case .unknown, .any: element = .unknown
        default: return nil
        }
        var closureResult: TypeAnnotation = .unknown
        for argument in arguments {
            switch (name, argument.label) {
            case ("filter", nil), ("count", "where"), ("count", nil):
                _ = try closureOrValue(argument.value, expecting: .functionType([element], .bool))
            case ("map", nil):
                if case .functionType(_, let result) = try closureOrValue(argument.value, expecting: .functionType([element], .unknown)) {
                    closureResult = result
                }
            case ("sorted", "by"), ("sorted", nil):
                _ = try closureOrValue(argument.value, expecting: .functionType([element, element], .bool))
            default:
                _ = try typeOf(argument.value)
            }
        }
        switch name {
        case "count": return .int
        case "map": return .list(closureResult)
        case "select": return .list(.unknown)
        case "get": return .list(.unknown)
        default: return .list(element)
        }
    }

    private func closureOrValue(_ expr: Expr, expecting expected: TypeAnnotation) throws -> TypeAnnotation {
        if case .closure(let closure) = expr { return try closureType(closure, expecting: expected) }
        return try typeOf(expr)
    }

    // MARK: Members

    private func memberType(_ baseExpr: Expr, _ name: String, expected: TypeAnnotation?) throws -> TypeAnnotation {
        if case .variable(let typeName) = baseExpr, let symbol = lookup(typeName) {
            switch symbol {
            case .enumType(let info):
                if name == "allCases" {
                    guard info.cases.allSatisfy({ $0.payload.isEmpty }) else { throw TypeError("\(info.name) has no allCases: some cases have associated values") }
                    return .list(.named(info.name))
                }
                return try caseType(name, nil, expected: .named(info.name))
            case .environment:
                return .optional(.string)
            case .module:
                return .unknown
            default:
                break
            }
        }
        return try memberType(of: try typeOf(baseExpr), name, baseExpr: baseExpr)
    }

    private func memberType(of base: TypeAnnotation, _ name: String, baseExpr: Expr?) throws -> TypeAnnotation {
        if name == "description" || name == "debugDescription" {
            if case .named(let structName) = base, let info = structInfo(named: structName),
               let property = info.property(name) { return property.type ?? .unknown }
            return .string
        }
        switch base {
        case .unknown, .any, .record:
            return .unknown
        case .optional(let wrapped):
            throw TypeError("\(base) might be nil: unwrap it (if let, ??) before using .\(name)" + (wrapped == .unknown ? "" : ""))
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

    private func caseType(_ name: String, _ arguments: [Argument]?, expected: TypeAnnotation?) throws -> TypeAnnotation {
        var target = expected
        if case .optional(let wrapped)? = target { target = wrapped }
        guard let target, target != .unknown, target != .any else {
            if target == nil { throw TypeError(".\(name) needs a type here; write the enum's name too, as in Kind.\(name)") }
            for argument in arguments ?? [] { _ = try typeOf(argument.value) }
            return .unknown
        }
        guard case .named(let enumName) = target, let info = enumInfo(named: enumName) else {
            throw TypeError(".\(name) is a case, but a \(target) is wanted here")
        }
        guard let payload = info.payload(of: name) else { throw TypeError("\(enumName) has no case '\(name)'") }
        guard let arguments else {
            guard payload.isEmpty else {
                let labels = payload.map { ($0.label ?? "_") + ":" }.joined()
                throw TypeError("\(enumName).\(name) needs its associated values: \(enumName).\(name)(\(labels))")
            }
            return .named(enumName)
        }
        guard !payload.isEmpty else { throw TypeError("\(enumName).\(name) has no associated values") }
        guard arguments.count == payload.count else {
            throw TypeError("\(enumName).\(name) has \(payload.count) associated values, not \(arguments.count)")
        }
        for (index, (argument, value)) in zip(arguments, payload).enumerated() {
            guard argument.label == value.label else {
                let wanted = value.label.map { "'\($0):'" } ?? "no label"
                throw TypeError("\(enumName).\(name): value #\(index + 1) needs \(wanted)")
            }
            try expect(argument.value, value.type, "\(enumName).\(name): value #\(index + 1)")
        }
        return .named(enumName)
    }

    private func indexType(_ baseExpr: Expr, _ index: Expr) throws -> TypeAnnotation {
        if case .variable(let name) = baseExpr, case .environment? = lookup(name) {
            try expect(index, .string, "an environment variable's name")
            return .optional(.string)
        }
        let base = try typeOf(baseExpr)
        switch base {
        case .list(let element):
            try expect(index, .int, "a list's index")
            return element
        case .output:
            try expect(index, .int, "a line's index")
            return .string
        case .dictionary(let key, let value):
            try expect(index, key, "the key")
            return .optional(value)
        case .unknown, .any, .record:
            _ = try typeOf(index)
            return .unknown
        default:
            throw TypeError("\(base) can't be indexed")
        }
    }

    // MARK: Operators

    private func binaryExprType(_ op: BinaryOperator, _ lhs: Expr, _ rhs: Expr, expected: TypeAnnotation?) throws -> TypeAnnotation {
        switch op {
        case .and, .or:
            try expect(lhs, .bool, "'\(op.rawValue)''s left side")
            try expect(rhs, .bool, "'\(op.rawValue)''s right side")
            return .bool
        case .coalesce:
            let left = try typeOf(lhs)
            guard case .optional(let wrapped) = left else {
                // Never nil, so the right side is never used; Swift allows it too.
                _ = try typeOf(rhs, expecting: left)
                return left
            }
            let right = try typeOf(rhs, expecting: wrapped == .unknown ? expected : wrapped)
            if wrapped == .unknown { return right }
            // An Output or some text: the Output's text.
            if wrapped == .output, right == .string, Interpreter.isStringExpression(rhs) { return .string }
            if fits(right, wrapped) { return wrapped }
            if fits(right, left) { return left }
            throw TypeError("'??' needs a \(wrapped) on its right, not \(right)")
        case .equal, .notEqual:
            // A `.case` on one side takes the other side's type.
            let (left, right) = try operandTypes(lhs, rhs)
            guard fits(left, right) || fits(right, left) || left == .output && right == .string || left == .string && right == .output else {
                throw TypeError("can't compare \(left) with \(right)")
            }
            return .bool
        default:
            let (left, right) = try operandTypes(lhs, rhs)
            return try binaryType(op, left, right, lhs: lhs, rhs: rhs)
        }
    }

    /// Both sides' types, letting a literal or `.case` on one side take its
    /// type from the other, as Swift does: `1 + 2.5`, `k == .file`.
    private func operandTypes(_ lhs: Expr, _ rhs: Expr) throws -> (TypeAnnotation, TypeAnnotation) {
        if case .caseLiteral = lhs, !TypeChecker.isContextual(rhs) {
            let right = try typeOf(rhs)
            return (try typeOf(lhs, expecting: right), right)
        }
        let left = try typeOf(lhs, expecting: TypeChecker.isIntegerLiteral(lhs) ? try? typeOf(rhs) : nil)
        let right = try typeOf(rhs, expecting: left)
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

    private func binaryType(_ op: BinaryOperator, _ left: TypeAnnotation, _ right: TypeAnnotation, lhs: Expr?, rhs: Expr?) throws -> TypeAnnotation {
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
        case (.functionType(let ap, let ar), .functionType(let bp, let br)):
            return ap.count == bp.count && zip(bp, ap).allSatisfy { fits($0, $1) } && (br == .void || fits(ar, br))
        // A struct's value is a record, as builtins that take any record see it.
        case (.named(let name), .record): return structInfo(named: name) != nil
        case (.tuple, .record): return true
        // An Output is its text where a String is wanted, and its lines
        // where a [String] is.
        case (.output, .string), (.output, .list(.string)): return true
        case (.list, .record): return false
        default: return false
        }
    }

    /// The type of each item when iterating `type`.
    private func elementType(of type: TypeAnnotation, iterating: Bool) throws -> TypeAnnotation {
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
            return .functions(set.candidates.map(signature))
        default:
            return .variable(shell.staticTypes[name] ?? type(of: binding.value), mutable: binding.mutable)
        }
    }

    private func signature(_ function: Function) -> Signature {
        // A builtin that hasn't declared its result isn't known; a Swish
        // function without `->` returns nothing.
        var returns = function.returnType ?? (function.isBuiltin ? .unknown : .void)
        if function.plugin != nil && returns == .any { returns = .unknown }
        return Signature(name: function.name ?? "closure", parameters: function.parameters, returns: returns, isMutating: function.isMutating)
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
        for (name, set) in type.methods { methods[name] = set.candidates.map(signature) }
        return StructInfo(
            name: type.name, stored: type.stored,
            computed: type.computed.mapValues { $0.returnType ?? .unknown },
            methods: methods,
            initializers: type.initializers?.candidates.map { Signature(name: $0.name ?? type.name, parameters: $0.parameters, returns: .named(type.name)) } ?? [],
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
