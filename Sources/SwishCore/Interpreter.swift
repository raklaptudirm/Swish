import Foundation
import SwishKit

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    /// The status the failure gives: a failed command's own, for `$(…)`.
    var status: Int32 = 1
    /// For a failed command, its output, so `catch` can look at it.
    var output: CommandOutput?

    init(_ description: String, status: Int32 = 1, output: CommandOutput? = nil) {
        self.description = description
        self.status = status
        self.output = output
    }

    /// What `catch` binds: the message, how it ended (`status.code`,
    /// `status.signal`, `status.succeeded`), and a failed command's `text`.
    var value: Value {
        let code = output.map { $0.code } ?? Int(status)
        return .record(Record([
            "message": .string(description),
            "status": .record(Record([
                "code": code.map(Value.int) ?? .nothing,
                "signal": output?.signal.map(Value.int) ?? .nothing,
                "succeeded": .bool(false),
            ], typeName: "Status")),
            "text": .string(output?.text ?? ""),
        ], typeName: "Error"))
    }
}

/// A runtime error under `try!`: it stops a script, not just the line.
struct FatalError: Error {
    let error: RuntimeError
}

/// ^C while the shell itself was running code.
/// ^C, or in a script SIGTERM or SIGHUP: stops what's running.
struct Interrupted: Error {
    var signal: Int32 = SIGINT
}

/// Non-local exits, thrown up to the loop or call that handles them. The
/// parser guarantees each one has a handler.
enum ControlFlow: Error {
    case returned(Value)
    case breakLoop
    case continueLoop
    case fallthroughCase
}

struct Binding {
    /// Builtin names whose values are live: read when they're used.
    enum Special {
        /// `env`: the environment, as a record; `env.NAME` is nil if unset.
        case environment
        /// `jobs`: the jobs in the background, oldest first.
        case jobs
        /// `self` in a struct's `init`, which may set its `let` properties.
        case initializing
    }

    /// Where the value lives, shared by every scope that has this
    /// variable: the one it was declared in, and closures that use it.
    private let cell: Cell
    var value: Value {
        get { cell.value }
        nonmutating set { cell.value = newValue }
    }
    let mutable: Bool
    /// Declared with `func`, which makes it callable in command mode.
    var isFunction = false
    var special: Special?

    init(value: Value, mutable: Bool, isFunction: Bool = false, special: Special? = nil) {
        cell = Cell(value)
        self.mutable = mutable
        self.isFunction = isFunction
        self.special = special
    }

    /// A variable's storage, so a closure can share it without keeping the
    /// whole scope it's in.
    private final class Cell {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}

/// A reference type so closures share variables with the scope they
/// captured, as in Swift.
final class Scope {
    var bindings: [String: Binding]
    /// For a closure's scope: where it was made, held weakly so it can't
    /// keep them alive, for names bound there after it was made (a local
    /// function declared further down).
    var fallbacks: [WeakScope] = []

    init(_ bindings: [String: Binding] = [:]) {
        self.bindings = bindings
    }

    /// The scope binding `name`: this one, or where it was made.
    func holding(_ name: String) -> Scope? {
        if bindings[name] != nil { return self }
        for fallback in fallbacks.reversed() {
            if let scope = fallback.scope, scope.bindings[name] != nil { return scope }
        }
        return nil
    }
}

struct WeakScope {
    weak var scope: Scope?
}

enum FunctionBody {
    case swish(Program)
    /// A builtin written in Swift, called with the bound arguments.
    case native((Shell, [String: Value]) throws -> Value)
    /// A builtin that transforms its `@input` stream lazily, so `first 5`
    /// can stop pulling after five items.
    case stream((Shell, ValueStream, [String: Value]) throws -> ValueStream)
}

/// A Swish function or closure, or a builtin written in Swift. Both get the
/// same argument binding, help, overloads and streaming.
final class Function: Callable, @unchecked Sendable {
    let name: String?
    let parameters: [Parameter]
    let returnType: TypeAnnotation?
    let body: FunctionBody
    let captured: [Scope]
    let documentation: Documentation?
    /// The imported module it came from, for a plugin's function.
    let plugin: String?
    /// A struct's `mutating func` (or `init`), which may change `self`.
    let isMutating: Bool
    /// `throws`: a call to it needs `try`.
    let isThrowing: Bool
    /// `rethrows`: a call throws if a closure passed to it does.
    let isRethrowing: Bool
    /// Type parameters and their constraints, for a generic builtin.
    let generics: [String: [String]]

    init(
        name: String?, parameters: [Parameter], returnType: TypeAnnotation?, body: FunctionBody,
        captured: [Scope] = [], documentation: Documentation? = nil, plugin: String? = nil, isMutating: Bool = false,
        isThrowing: Bool = false, isRethrowing: Bool = false, generics: [String: [String]] = [:]
    ) {
        self.isRethrowing = isRethrowing
        self.generics = generics
        self.plugin = plugin
        self.isMutating = isMutating
        self.isThrowing = isThrowing
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.captured = captured
        self.documentation = documentation
    }

    var inputParameter: Parameter? {
        parameters.first(where: \.isInput)
    }

    /// Whether a new declaration would replace this one rather than overload it.
    func hasSameSignature(as other: Function) -> Bool {
        let signature = { (p: Parameter) in [p.label ?? "_", p.type.description, "\(p.variadic)", "\(p.isInput)"] }
        return parameters.map(signature) == other.parameters.map(signature)
    }

    var description: String {
        guard let name else { return "<closure>" }
        let labels = parameters.map { ($0.label ?? "_") + ":" }.joined()
        return "<func \(name)(\(labels))>"
    }

    var isBuiltin: Bool {
        if case .swish = body { false } else { true }
    }

    /// A body that is a single expression returns its value, as in Swift:
    /// a closure's, or a function's that says what it returns. A function
    /// without `->` returns nothing.
    var implicitReturn: Expr? {
        guard name == nil || returnType != nil, case .swish(let body) = body, body.statements.count == 1,
              case .chain(let chain) = body.statements[0], chain.links.isEmpty,
              case .expression(let expr) = chain.first else { return nil }
        return expr
    }
}

/// How a unit's result is used.
enum UnitContext {
    /// A whole statement: an expression's value is displayed.
    case statement
    /// Part of a chain: only the exit status matters.
    case operand
    /// An `if` or `while` condition: expressions must be Bool.
    case condition
}

private let maxCallDepth = 10_000

extension Shell {
    // MARK: Statements

    func run(_ program: Program) throws -> Int32 {
        var status: Int32 = 0
        try hoistDeclarations(program)
        // `defer` blocks run as the block ends, however it ends.
        var deferred: [Program] = []
        defer { runDeferred(deferred) }
        for statement in program.statements {
            if case .deferBlock(let body) = statement {
                deferred.append(body)
                continue
            }
            if statement.declaresType { continue } // Hoisted.
            try checkInterrupt()
            status = try run(statement)
            lastStatus = status
        }
        return status
    }

    /// The branch of an `if` its condition picks, with what the condition
    /// binds; nil for no `else`.
    private func chooseBranch(_ node: IfStatement) throws -> (Program?, [String: Binding]) {
        if let bindings = try holds(node.condition) { return (node.then, bindings) }
        return (node.otherwise, [:])
    }

    /// What an `if` or `guard` condition binds when it holds; nil when it doesn't.
    private func holds(_ condition: IfStatement.Condition) throws -> [String: Binding]? {
        switch condition {
        case .pattern(let pattern, let expr):
            var bindings: [String: Binding] = [:]
            return try match(pattern, try evaluate(expr), into: &bindings) ? bindings : nil
        case .chain(let chain):
            return try run(chain, context: .condition) == 0 ? [:] : nil
        case .binding(let name, let mutable, let expr):
            let value = try evaluate(expr)
            return value != .nothing ? [name: Binding(value: value, mutable: mutable)] : nil
        }
    }

    /// Declares a block's functions and types before it runs, so they can
    /// be used before their declarations, as in Swift. A function is
    /// declared again where it's written, which captures what's been
    /// declared by then, as it always has.
    func hoistDeclarations(_ program: Program) throws {
        for statement in program.statements {
            if case .function = statement { _ = try run(statement) }
            else if statement.declaresType { _ = try run(statement) }
        }
    }

    /// Deferred blocks, last first. One that fails is reported; the rest
    /// still run, as nothing can leave a `defer`.
    func runDeferred(_ blocks: [Program]) {
        let status = lastStatus
        for body in blocks.reversed() {
            do {
                _ = try runBlock(body)
            } catch let error as RuntimeError {
                report("error: \(error)")
            } catch {
                report("error: \(error)")
            }
        }
        lastStatus = status
    }

    func runBlock(_ program: Program, declaring bindings: [String: Binding] = [:]) throws -> Int32 {
        scopes.append(Scope(bindings))
        defer { scopes.removeLast() }
        return try run(program)
    }

    /// Per-item errors reported while a statement runs make its status a
    /// failure, even though the statement carried on.
    private func run(_ statement: Statement) throws -> Int32 {
        let errorsBefore = itemErrorCount
        let status = try runReportedErrorsAside(statement)
        return itemErrorCount > errorsBefore && status == 0 ? 1 : status
    }

    private func runReportedErrorsAside(_ statement: Statement) throws -> Int32 {
        switch statement {
        case .extensionDecl:
            return 0 // Only the prelude has these; it's read at startup.
        case .deferBlock:
            return 0 // Collected by the block that holds it.
        case .declare(let name, let mutable, let expr):
            let value = try evaluate(expr)
            scopes[scopes.count - 1].bindings[name] = Binding(value: value, mutable: mutable)
            return 0
        case .assign(let assignment):
            try assign(assignment)
            return 0
        case .structDecl(let decl):
            declare(decl)
            return 0
        case .function(let decl):
            // Captures the scope it's bound in, so it can call itself.
            let function = Function(
                name: decl.name, parameters: decl.parameters, returnType: decl.returnType,
                body: .swish(decl.body), captured: captureScopes(decl.names), documentation: decl.documentation,
                isThrowing: decl.isThrowing
            )
            // A second declaration with a different signature overloads the
            // name; one with the same signature replaces the old one.
            let scope = scopes[scopes.count - 1]
            var candidates = [function]
            if let existing = scope.bindings[decl.name], existing.isFunction,
               case .function(let callable) = existing.value, let set = callable as? OverloadSet {
                candidates = set.candidates.filter { !$0.hasSameSignature(as: function) } + candidates
            }
            scope.bindings[decl.name] = Binding(
                value: .function(OverloadSet(name: decl.name, candidates: candidates)), mutable: false, isFunction: true
            )
            return 0
        case .setEnvironment(let nameExpr, let valueExpr):
            guard lookup("env")?.special == .environment else {
                throw RuntimeError("env is a variable here, not the environment")
            }
            let name = try evaluate(nameExpr)
            guard case .string(let key) = name, !key.isEmpty, !key.contains("=") else {
                throw RuntimeError("an environment variable's name must be a String without '=', not \(name)")
            }
            let value = try evaluate(valueExpr)
            if value == .nothing {
                unsetenv(key)
            } else {
                setenv(key, value.description, 1)
            }
            return 0
        case .doCatch(let body, let errorName, let handler):
            do {
                return try runBlock(body)
            } catch let error as RuntimeError {
                guard let handler else { throw error }
                return try runBlock(handler, declaring: [errorName: Binding(value: error.value, mutable: false)])
            } catch let reported as AlreadyReported {
                guard let handler else { throw reported }
                return try runBlock(handler, declaring: [errorName: Binding(value: reported.error.value, mutable: false)])
            }
        case .importPlugin(let name, let pathExpr):
            let path = try evaluate(pathExpr)
            guard case .string(let text) = path else {
                throw RuntimeError("import \(name): the path must be a String, not \(path.typeName)")
            }
            try importPlugin(name, from: text)
            return 0
        case .enumDecl(let decl):
            try declare(decl)
            return 0
        case .fallthroughStatement:
            throw ControlFlow.fallthroughCase
        case .guardStatement(let condition, let otherwise):
            if let bindings = try holds(condition) {
                for (name, binding) in bindings { scopes[scopes.count - 1].bindings[name] = binding }
                return 0
            }
            _ = try runBlock(otherwise)
            // The checker sees to it that the else leaves; `exit` might not
            // (with jobs left, it only warns).
            throw RuntimeError("guard's else carried on")
        case .returnStatement(let expr):
            // A `.case` returned from a function declared to return an enum.
            throw ControlFlow.returned(try expr.map { try evaluate($0, expecting: returnTypes.last ?? nil) } ?? .nothing)
        case .breakStatement:
            throw ControlFlow.breakLoop
        case .continueStatement:
            throw ControlFlow.continueLoop
        case .chain(let chain):
            return try run(chain, context: .statement)
        }
    }

    private func run(_ chain: Chain, context: UnitContext) throws -> Int32 {
        let unitContext = chain.links.isEmpty || context == .condition ? context : .operand
        var status = try run(chain.first, context: unitContext)
        for link in chain.links where (link.op == .and) == (status == 0) {
            status = try run(link.unit, context: unitContext)
        }
        return status
    }

    private func run(_ unit: Unit, context: UnitContext) throws -> Int32 {
        switch unit {
        case .pipeline(let node):
            let stages = try stages(for: node)
            let status = try runPipeline(stages, source: node.source, display: context == .statement)
            // `try make`: failing throws, with the status in the error.
            if case .some(let kind) = node.throwing, status != 0 {
                let (code, signal) = exitCode(status)
                let error = RuntimeError("\(node.source) failed with status \(status)", status: status,
                                         output: CommandOutput(text: "", code: code, signal: signal))
                throw kind == .forced ? FatalError(error: error) : error
            }
            return status

        case .expression(let expr):
            let value = try evaluate(expr)
            // A bare `true`/`false` stands in for the Unix commands: status only.
            let isBoolLiteral = if case .literal(.bool) = expr { true } else { false }
            // `await build`: the job wrote to the terminal; its Output has
            // nothing more to show.
            let awaitedToTerminal = expr.isAwait && value.isEmptyOutput
            // `xs.removeLast()` alone: Swift's @discardableResult.
            let discarded = if case .bridged(let type, let member, _, _) = expr {
                Bridge.types[type]?.members[member].discardableResult == true
            } else { false }
            if context == .statement && !isBoolLiteral && !awaitedToTerminal && !discarded {
                display(value)
            }
            if case .bool(let truth) = value { return truth ? 0 : 1 }
            // `await build && echo ok`: an Output's status is its command's.
            if case .output(let output) = value, !output.succeeded {
                return output.code.map(Int32.init) ?? 128 + Int32(output.signal ?? 0)
            }
            // A `try?` that caught an error is a failure, so `try? $(…) != nil
            // && …` and `if try? …` work. Other nils, like a function that
            // returns nothing, aren't.
            if case .attempt(_, .optional) = expr { return value == .nothing ? 1 : 0 }
            if context == .condition {
                throw RuntimeError("condition must be a Bool, not \(value.typeName)")
            }
            return 0

        case .switchStatement(let node):
            return try runSwitch(node)

        case .ifStatement(let node):
            let (branch, bindings) = try chooseBranch(node)
            guard let branch else { return 0 }
            return try runBlock(branch, declaring: bindings)

        case .forLoop(let loop):
            var status: Int32 = 0
            try forEachElement(of: loop.sequence) { element in
                let bindings = loop.variable == "_" ? [:] : [loop.variable: Binding(value: element, mutable: false)]
                return try runLoopBody(loop.body, declaring: bindings, status: &status)
            }
            return status

        case .whileLoop(let loop):
            var status: Int32 = 0
            while try run(loop.condition, context: .condition) == 0 {
                guard try runLoopBody(loop.body, declaring: [:], status: &status) else { break }
            }
            return status
        }
    }

    /// Runs one iteration; false means `break`.
    private func runLoopBody(_ body: Program, declaring bindings: [String: Binding], status: inout Int32) throws -> Bool {
        try checkInterrupt()
        do {
            status = try runBlock(body, declaring: bindings)
        } catch ControlFlow.breakLoop {
            return false
        } catch ControlFlow.continueLoop {}
        return true
    }

    /// Iterates lists, ranges lazily (so `for i in 1...1_000_000_000` never
    /// builds a list), strings by character, as in Swift, the Swift
    /// sequences Swish holds, and command output by line.
    private func forEachElement(of sequence: Expr, _ body: (Value) throws -> Bool) throws {
        if case .binary(let op, let lower, let upper) = sequence, op == .closedRange || op == .halfOpenRange {
            for i in try intRange(op, try evaluate(lower), try evaluate(upper)) {
                guard try body(.int(i)) else { return }
            }
            return
        }
        let value = try evaluate(sequence)
        let elements: AnyIterator<Value>
        if case .string(let text) = value {
            elements = AnyIterator(text.lazy.map { .string(String($0)) }.makeIterator())
        } else if let items = Shell.items(of: value) {
            elements = items
        } else {
            throw RuntimeError("can't iterate over \(value.typeName)")
        }
        for element in elements {
            guard try body(element) else { return }
        }
    }

    /// A bare value at the prompt, shown as `debugPrint` would.
    private func display(_ value: Value) {
        guard callDepth == 0 else { return }
        show(value, debug: true)
    }

    func checkInterrupt() throws {
        if let signal = takeInterruptSignal() { throw Interrupted(signal: signal) }
    }

    // MARK: Expressions

    func evaluate(_ expr: Expr) throws -> Value {
        switch expr {
        case .literal(let value):
            return value
        case .string(let parts):
            return .string(try expand(parts))
        case .variable(let name):
            guard let binding = lookup(name) else { throw RuntimeError("no variable named '\(name)'") }
            switch binding.special {
            case .environment?: return environmentRecord()
            case .jobs?:
                updateJobs() // So their states are current.
                return .list(jobs.map { .object($0) })
            case .initializing?, nil: return binding.value
            }
        case .dollar(let name):
            if let binding = lookup(name) { return binding.value }
            if let value = env(name) { return .string(value) }
            throw RuntimeError("no variable or environment variable named '\(name)'")
        case .substitution(let program, let throwing):
            var status: Int32 = 0
            var text = try capturing { status = try runBlock(program) }
            while text.last == "\n" { text.removeLast() }
            let (code, signal) = exitCode(status)
            let output = CommandOutput(text: text, code: code, signal: signal)
            // Without `try`, failing is just what `.status` says.
            if throwing && status != 0 {
                throw RuntimeError("$(…) failed with status \(status)", status: status, output: output)
            }
            return .output(output)
        case .list(let elements):
            return .list(try elements.map(evaluate))
        case .record(let entries):
            // `["a": 1]`: a dictionary, as in Swift.
            var dictionary = ValueDictionary()
            for entry in entries {
                dictionary[try evaluate(entry.key)] = try evaluate(entry.value)
            }
            return .dictionary(dictionary)
        case .forceUnwrap(let inner):
            let value = try evaluate(inner)
            guard value != .nothing else { throw RuntimeError("unwrapped nil with '!'") }
            return value
        case .optionalMember(let base, let name):
            let value = try evaluate(base)
            return value == .nothing ? .nothing : try member(name, of: value)
        case .optionalIndex(let base, let index):
            let value = try evaluate(base)
            return value == .nothing ? .nothing : try element(of: value, at: try evaluate(index))
        case .annotated(let inner, let type):
            let value = try evaluate(inner, expecting: type)
            guard let conforming = conform(value, to: type) else {
                throw RuntimeError("expected \(type), not \(value.typeName)")
            }
            return conforming
        case .tuple(let elements):
            // `(name: "x", 2)`: unlabeled elements are keyed by position.
            var record = Record()
            for (index, element) in elements.enumerated() {
                record[element.label ?? String(index)] = try evaluate(element.value)
            }
            return .record(record)
        case .caseLiteral(let name, _):
            throw RuntimeError(".\(name) needs a type here; write the enum's name too, as in Kind.\(name)")
        case .binary(let op, let lhs, let rhs) where (op == .equal || op == .notEqual)
            && (Shell.isCaseLiteral(lhs) || Shell.isCaseLiteral(rhs)):
            // `$0.type == .directory`: the case comes from the other side's enum.
            let known = try evaluate(Shell.isCaseLiteral(lhs) ? rhs : lhs)
            guard case .enumValue(let enumValue) = known else {
                throw RuntimeError("\(op.rawValue) with a .case needs an enum on the other side, not \(known.typeName)")
            }
            let literal = Shell.isCaseLiteral(lhs) ? lhs : rhs
            guard case .caseLiteral(let name, let arguments) = literal else { preconditionFailure() }
            let equal = try makeCase(enumValue.type, name, arguments) == known
            return .bool(op == .equal ? equal : !equal)
        case .member(let base, let name):
            // An unset environment variable is nil, not a missing field.
            if isEnvironment(base) { return env(name).map(Value.string) ?? .nothing }
            return try member(name, of: try evaluate(base))
        case .closure(let literal):
            return .function(Function(
                name: nil, parameters: literal.parameters, returnType: literal.returnType,
                body: .swish(literal.body), captured: captureScopes(literal.names)
            ))
        case .call(let callee, let arguments):
            // The overload the checker chose, when there's a choice.
            var callee = callee
            var overload: Int?
            if case .chosen(let inner, let index) = callee {
                callee = inner
                overload = index
            }
            let value: Value
            // `x?.f()`: nothing when `x` is nil.
            if case .optionalMember(let baseExpr, let name) = callee {
                let base = try evaluate(baseExpr)
                if base == .nothing { return .nothing }
                return try evaluate(.call(.member(.literal(base), name), arguments))
            }
            if case .member(let baseExpr, let name) = callee {
                let base = try evaluate(baseExpr)
                // `Result.failed(code: 2)`: a case with associated values.
                if case .object(let type as EnumType) = base {
                    return try makeCase(type, name, arguments)
                }
                // `p.move(by: 1)`: a struct's method, with `p` as `self`.
                if case .record(let record) = base, record[name] == nil, let type = structType(of: record),
                   let methods = type.methods[name] {
                    return try callMethod(narrowed(methods, overload), of: base, at: baseExpr, arguments)
                }
                // `xs.sorted(by: "size")`: a sequence's method.
                if let methods = sequenceMethods[name], let items = base.sequenceItems {
                    return try callSequenceMethod(narrowed(methods, overload), on: items, arguments)
                }
                value = try member(name, of: base)
            } else {
                value = try evaluate(callee)
            }
            // `Point(x: 1, y: 2)`: a new struct.
            if case .object(let type as StructType) = value {
                return try construct(type, arguments, overload: overload)
            }
            // `Level(rawValue: 2)`: the case with that raw value, or nil.
            if case .object(let type as EnumType) = value {
                guard arguments.count == 1, arguments[0].label == "rawValue" else {
                    throw RuntimeError("\(type.name) is made from a raw value: \(type.name)(rawValue: …)")
                }
                return type.case(rawValue: try evaluate(arguments[0].value)).map(Value.enumValue) ?? .nothing
            }
            // `.case` arguments wait for their parameter's type.
            let values = try arguments.map { argument -> Argument in
                if case .caseLiteral = argument.value { return argument }
                return Argument(label: argument.label, value: .literal(try evaluate(argument.value)))
            }
            switch value {
            case .function(let set as OverloadSet):
                let (function, bindings) = try resolve(narrowed(set, overload)) { try self.bind(values, to: $0) }
                return try invoke(function, with: bindings)
            case .function(let function as Function):
                return try invoke(function, with: try bind(values, to: function).bindings)
            case .function(let native as NativeFunction):
                let function = hostFunction(native.function)
                return try invoke(function, with: try bind(values, to: function).bindings)
            case .function(let keyPath as KeyPathValue):
                guard values.count == 1 else { throw RuntimeError("a key path reads one value") }
                return try keyPath.read(from: try evaluate(values[0].value), in: self)
            default:
                throw RuntimeError("\(value.typeName) isn't a function")
            }
        case .unary(let op, let operand):
            return try apply(op, try evaluate(operand))
        case .binary(.and, let lhs, let rhs):
            return .bool(try truth(lhs, for: .and) && truth(rhs, for: .and))
        case .binary(.or, let lhs, let rhs):
            return .bool(try truth(lhs, for: .or) || truth(rhs, for: .or))
        case .attempt(let operand, .plain):
            return try evaluate(operand)
        case .bridged(let typeName, let member, let receiver, let arguments):
            return try runBridged(typeName, member, receiver: receiver, arguments)
        case .filePath:
            return .string(scriptPath ?? "<prompt>")
        case .ifExpression(let node):
            let (branch, bindings) = try chooseBranch(node)
            guard let branch, let expr = IfStatement.branchExpression(branch) else { return .nothing }
            scopes.append(Scope(bindings))
            defer { scopes.removeLast() }
            return try evaluate(expr)
        case .cast(let inner, let type, let kind):
            let value = try evaluate(inner)
            let converted = conform(value, to: type)
            switch kind {
            case .conditional: return converted ?? .nothing
            case .check: return .bool(converted != nil)
            case .upcast: return converted ?? value
            case .forced:
                guard let converted else { throw RuntimeError("'as!' failed: a \(value.typeName) isn't a \(type)") }
                return converted
            }
        case .keyPath(_, let path):
            return .function(KeyPathValue(path: path))
        case .voidValue(let operand):
            _ = try evaluate(operand)
            return .record(Record())
        case .chosen(let inner, let overload):
            // A function as a value, with the overload the checker picked.
            if case .function(let set as OverloadSet) = try evaluate(inner) {
                return .function(narrowed(set, overload))
            }
            return try evaluate(inner)
        case .attempt(let operand, .optional):
            do {
                return try evaluate(operand)
            } catch is RuntimeError {
                return .nothing
            } catch is AlreadyReported {
                return .nothing
            }
        case .attempt(let operand, .forced):
            do {
                return try evaluate(operand)
            } catch let error as RuntimeError {
                throw FatalError(error: error)
            }
        case .async(let target):
            switch target {
            case .command(let node):
                return .object(try startJob(try stages(for: node), source: node.source, capture: false))
            case .capture(let node):
                return .object(try startJob(try stages(for: node), source: node.source, capture: true))
            }
        case .await(let target, let throwing):
            let job: Job
            if let target {
                let value = try evaluate(target)
                guard case .object(let object as Job) = value else {
                    throw RuntimeError("await needs a Job, not \(value.typeName)")
                }
                job = object
            } else {
                guard let latest = jobs.last else { throw RuntimeError("there are no jobs to await") }
                job = latest
            }
            let output = try awaitJob(job)
            if throwing && !output.succeeded {
                throw RuntimeError("\(job.source) failed with status \(job.status)", status: job.status, output: output)
            }
            return .output(output)
        case .binary(.coalesce, let lhs, let rhs):
            let value = try evaluate(lhs)
            if value == .nothing { return try evaluate(rhs) }
            // `(try? $(git config x)) ?? "vi"` is a String: the checker types
            // it so, so the Output gives its text.
            if case .output(let output) = value, Interpreter.isStringExpression(rhs) { return .string(output.text) }
            return value
        case .binary(let op, let lhs, let rhs) where [.less, .lessEqual, .greater, .greaterEqual].contains(op)
            && (Shell.isCaseLiteral(lhs) || Shell.isCaseLiteral(rhs)):
            // `level < .high`: the case comes from the other side's enum.
            let known = try evaluate(Shell.isCaseLiteral(lhs) ? rhs : lhs)
            guard case .enumValue(let enumValue) = known else {
                throw RuntimeError("\(op.rawValue) with a .case needs an enum on the other side, not \(known.typeName)")
            }
            guard case .caseLiteral(let name, let arguments) = Shell.isCaseLiteral(lhs) ? lhs : rhs else { preconditionFailure() }
            let literal = try makeCase(enumValue.type, name, arguments)
            return Shell.isCaseLiteral(lhs) ? try apply(op, literal, known) : try apply(op, known, literal)
        case .binary(let op, let lhs, let rhs) where op == .closedRange || op == .halfOpenRange:
            return try makeRange(op, try evaluate(lhs), try evaluate(rhs))
        case .binary(let op, let lhs, let rhs):
            return try apply(op, try evaluate(lhs), try evaluate(rhs))
        case .index(let base, let index):
            if isEnvironment(base) {
                let key = try evaluate(index)
                guard case .string(let name) = key else { throw RuntimeError("env is indexed by name, not \(key.typeName)") }
                return env(name).map(Value.string) ?? .nothing
            }
            return try element(of: try evaluate(base), at: try evaluate(index))
        }
    }

    static func isCaseLiteral(_ expr: Expr) -> Bool {
        if case .caseLiteral = expr { true } else { false }
    }

    private func isEnvironment(_ expr: Expr) -> Bool {
        guard case .variable(let name) = expr else { return false }
        return lookup(name)?.special == .environment
    }

    private func environmentRecord() -> Value {
        var record = Record(typeName: "Environment")
        for (key, value) in ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key }) {
            record[key] = .string(value)
        }
        return .record(record)
    }

    /// A status as an exit code, or the signal that ended the command.
    func exitCode(_ status: Int32) -> (code: Int?, signal: Int?) {
        if status > 128 && status == lastSignalStatus { return (nil, Int(status - 128)) }
        return (Int(status), nil)
    }

    /// Sets environment variables around `body`, then puts them back.
    func withEnvironment<T>(_ variables: [(String, String)], _ body: () throws -> T) rethrows -> T {
        guard !variables.isEmpty else { return try body() }
        let saved = variables.map { ($0.0, env($0.0)) }
        for (name, value) in variables { setenv(name, value, 1) }
        defer {
            for (name, value) in saved.reversed() {
                if let value { setenv(name, value, 1) } else { unsetenv(name) }
            }
        }
        return try body()
    }

    /// Joins a string's parts into one string. Interpolation never splits.
    private func expand(_ parts: [StringPart]) throws -> String {
        try parts.map { part in
            switch part {
            case .literal(let text), .glob(let text): text
            case .expression(let expr), .spread(let expr): try evaluate(expr).description
            }
        }.joined()
    }

    /// A command word's arguments: one, unless it has an unquoted wildcard,
    /// when it's the matching paths. Interpolated values are literal in the
    /// pattern, so `"$dir"/*.txt` works whatever `$dir` holds. A pattern
    /// that matches nothing is an error, not passed on as it is. An
    /// unquoted list alone in the word is its items: `rm $files`.
    private func expandWord(_ parts: [StringPart]) throws -> [String] {
        if parts.count == 1, case .spread(let expr) = parts[0], case .list(let items) = try evaluate(expr) {
            return items.map(\.description)
        }
        var text = ""
        var pattern = ""
        var hasGlob = false
        for part in parts {
            switch part {
            case .literal(let literal):
                text += literal
                pattern += Glob.escape(literal)
            case .glob(let glob):
                text += glob
                // `?` isn't a wildcard in Swish, so URLs need no quoting.
                pattern += glob.replacingOccurrences(of: "?", with: "\\?")
                hasGlob = true
            case .expression(let expr), .spread(let expr):
                let value = try evaluate(expr).description
                text += value
                pattern += Glob.escape(value)
            }
        }
        guard hasGlob, Glob.hasWildcards(pattern) else { return [text] }
        let matches = Glob.expand(pattern)
        guard !matches.isEmpty else { throw RuntimeError("no matches for \(text)") }
        return matches
    }

    private func resolve(_ redirect: Redirect) throws -> ResolvedRedirect {
        switch redirect.target {
        case .descriptor(let source):
            return ResolvedRedirect(fd: redirect.fd, action: .duplicate(source))
        case .file(let parts, let mode):
            let paths = try expandWord(parts)
            guard paths.count == 1 else {
                throw RuntimeError("ambiguous redirect: \(paths.count) files match")
            }
            return ResolvedRedirect(fd: redirect.fd, action: .open(paths[0], mode))
        }
    }

    func lookup(_ name: String) -> Binding? {
        scopeHolding(name)?.bindings[name]
    }

    /// The innermost scope binding `name`.
    func scopeHolding(_ name: String) -> Scope? {
        for scope in scopes.reversed() {
            if let holding = scope.holding(name) { return holding }
        }
        return nil
    }

    /// What a closure or nested function keeps of the scopes it's made in:
    /// the global ones, and only the local variables its body names, each
    /// shared with where it's declared. Keeping whole scopes would keep the
    /// one the closure itself is stored in: a cycle, never freed.
    func captureScopes(_ names: NamesUsed) -> [Scope] {
        guard scopes.count > 2 else { return scopes }
        let local = scopes[2...]
        let capture = Scope()
        for name in names.names {
            if let scope = local.last(where: { $0.holding(name) != nil })?.holding(name) {
                capture.bindings[name] = scope.bindings[name]
            }
        }
        capture.fallbacks = local.map { WeakScope(scope: $0) } + local.flatMap(\.fallbacks)
        return Array(scopes[..<2]) + [capture]
    }

    /// The functions a command name refers to, if it was declared with `func`.
    func commandFunctions(named name: String) -> OverloadSet? {
        guard let binding = lookup(name), binding.isFunction,
              case .function(let callable) = binding.value else { return nil }
        return callable as? OverloadSet
    }

    private func intRange(_ op: BinaryOperator, _ lower: Value, _ upper: Value) throws -> Range<Int> {
        guard case .int(let low) = lower, case .int(let high) = upper else {
            throw RuntimeError("a range needs Int bounds, not \(lower.typeName) and \(upper.typeName)")
        }
        guard low <= high else { throw RuntimeError("range \(low)\(op.rawValue)\(high) has its bounds reversed") }
        if op == .halfOpenRange { return low..<high }
        guard high < Int.max else { throw RuntimeError("arithmetic overflow") }
        return low..<(high + 1)
    }

    private func truth(_ expr: Expr, for op: BinaryOperator) throws -> Bool {
        let value = try evaluate(expr)
        guard case .bool(let truth) = value else {
            throw RuntimeError("'\(op.rawValue)' needs Bool operands, not \(value.typeName)")
        }
        return truth
    }

    private func apply(_ op: UnaryOperator, _ value: Value) throws -> Value {
        switch (op, value) {
        case (.not, .bool(let b)):
            return .bool(!b)
        case (.negate, .int(let n)):
            let (result, overflow) = Int(0).subtractingReportingOverflow(n)
            guard !overflow else { throw RuntimeError("arithmetic overflow") }
            return .int(result)
        case (.negate, .double(let d)):
            return .double(-d)
        case (.negate, .filesize(let bytes)):
            return .filesize(-bytes)
        default:
            throw RuntimeError("'\(op.rawValue)' can't be applied to \(value.typeName)")
        }
    }

    func apply(_ op: BinaryOperator, _ lhs: Value, _ rhs: Value) throws -> Value {
        // Output compares as its text; other String operations go through `.text`.
        let comparisons: [BinaryOperator] = [.equal, .notEqual, .less, .lessEqual, .greater, .greaterEqual]
        if case .output(let output) = lhs, comparisons.contains(op) {
            return try apply(op, .string(output.text), rhs)
        }
        if case .output(let output) = rhs, comparisons.contains(op) {
            return try apply(op, lhs, .string(output.text))
        }
        if case .output = lhs, op == .add {
            throw RuntimeError("'+' needs the text of a command's output: use .text")
        }
        if op == .equal || op == .notEqual {
            if case .enumValue(let value) = lhs, case .string(let text) = rhs {
                throw RuntimeError("can't compare \(value.type.name) with a String; compare with a case, like .\(text)")
            }
            if case .string(let text) = lhs, case .enumValue(let value) = rhs {
                throw RuntimeError("can't compare a String with \(value.type.name); compare with a case, like .\(text)")
            }
        }
        switch (op, lhs, rhs) {
        case (.equal, _, _):
            return .bool(lhs.isEqual(to: rhs))
        case (.notEqual, _, _):
            return .bool(!lhs.isEqual(to: rhs))
        case (.add, .string(let a), .string(let b)):
            return .string(a + b)
        case (.add, .list(let a), .list(let b)):
            return .list(a + b)
        case (_, .string(let a), .string(let b)):
            if let result = compare(op, a, b) { return .bool(result) }
        case (_, .int(let a), .int(let b)):
            return try integerArithmetic(op, a, b)
        case (_, .int, .double), (_, .double, .int), (_, .double, .double):
            if let result = try floatingArithmetic(op, lhs.asDouble!, rhs.asDouble!) { return result }
        case (_, .filesize(let a), .filesize(let b)):
            switch op {
            case .add: return try checkedFileSize(Double(a) + Double(b))
            case .subtract: return try checkedFileSize(Double(a) - Double(b))
            case .divide: return .double(Double(a) / Double(b))
            default: if let result = compare(op, a, b) { return .bool(result) }
            }
        case (.multiply, .filesize(let bytes), _) where rhs.asDouble != nil:
            return try checkedFileSize(Double(bytes) * rhs.asDouble!)
        case (.multiply, _, .filesize(let bytes)) where lhs.asDouble != nil:
            return try checkedFileSize(Double(bytes) * lhs.asDouble!)
        case (.divide, .filesize(let bytes), _) where rhs.asDouble != nil:
            guard rhs.asDouble != 0 else { throw RuntimeError("division by zero") }
            return try checkedFileSize(Double(bytes) / rhs.asDouble!)
        case (_, .date(let a), .date(let b)):
            if op == .subtract { return .double(a.timeIntervalSince(b)) }
            if let result = compare(op, a, b) { return .bool(result) }
        // A Comparable enum: in the order its cases are declared.
        case (_, .enumValue(let a), .enumValue(let b)) where a.type === b.type:
            if let result = compare(op, a.index, b.index) { return .bool(result) }
        default:
            break
        }
        throw RuntimeError("'\(op.rawValue)' can't be applied to \(lhs.typeName) and \(rhs.typeName)")
    }

    private func checkedFileSize(_ bytes: Double) throws -> Value {
        guard bytes.magnitude < Double(Int64.max) else { throw RuntimeError("arithmetic overflow") }
        return .filesize(Int64(bytes))
    }

    private func integerArithmetic(_ op: BinaryOperator, _ a: Int, _ b: Int) throws -> Value {
        let result: (partialValue: Int, overflow: Bool)
        switch op {
        case .add: result = a.addingReportingOverflow(b)
        case .subtract: result = a.subtractingReportingOverflow(b)
        case .multiply: result = a.multipliedReportingOverflow(by: b)
        case .divide, .remainder:
            guard b != 0 else { throw RuntimeError("division by zero") }
            result = op == .divide ? a.dividedReportingOverflow(by: b) : a.remainderReportingOverflow(dividingBy: b)
        default:
            if let comparison = compare(op, a, b) { return .bool(comparison) }
            throw RuntimeError("'\(op.rawValue)' can't be applied to Int and Int")
        }
        guard !result.overflow else { throw RuntimeError("arithmetic overflow") }
        return .int(result.partialValue)
    }

    private func floatingArithmetic(_ op: BinaryOperator, _ a: Double, _ b: Double) throws -> Value? {
        switch op {
        case .add: .double(a + b)
        case .subtract: .double(a - b)
        case .multiply: .double(a * b)
        case .divide: .double(a / b)
        default: compare(op, a, b).map(Value.bool)
        }
    }

    private func compare<T: Comparable>(_ op: BinaryOperator, _ a: T, _ b: T) -> Bool? {
        switch op {
        case .less: a < b
        case .lessEqual: a <= b
        case .greater: a > b
        case .greaterEqual: a >= b
        default: nil
        }
    }

    /// A pipeline's stages, with words expanded and redirects resolved.
    func stages(for node: PipelineNode) throws -> [Stage] {
        var stages: [Stage] = []
        if let input = node.input {
            stages.append(.value(try evaluate(input)))
        }
        for (index, command) in node.commands.enumerated() {
            // After a `|`, a name can be a method of what's piped in.
            let piped = index > 0 || node.input != nil
            var arguments: [CommandArgument] = []
            for word in command.words {
                switch word {
                case .text(let parts): arguments += try expandWord(parts).map(CommandArgument.text)
                case .closure(let literal): arguments.append(.value(try evaluate(.closure(literal))))
                }
            }
            guard case .text(let name) = arguments[0] else {
                throw RuntimeError("a closure can't be a command name")
            }
            if let call = command.call {
                guard !command.external else { throw RuntimeError("a program can't be called with (…)") }
                // `.case` arguments wait for their parameter's type.
                arguments += try call.map { argument in
                    if case .caseLiteral = argument.value { return .call(argument) }
                    return .call(Argument(label: argument.label, value: .literal(try evaluate(argument.value))))
                }
            }
            let redirects = try command.redirects.map(resolve)
            let environment = try command.environment.map { ($0.name, try expand($0.value)) }
            let rest = Array(arguments.dropFirst())
            // Methods of the input first (the sequence's, then its items'),
            // then functions, then programs; `foreign` skips to programs.
            // What the checker found, from the input's type, decides; without
            // that, the interpreter looks.
            let resolution = command.resolution
            if !command.external, piped, case .bridged(let type, let receiver, let bindings)? = resolution,
               let members = bridgedStage(type, name, receiver: receiver, bindings: bindings) {
                // `xs | max`: a Swift member, as the checker found it.
                stages.append(.function(narrowed(members, command.overload), rest, redirects: redirects, environment: environment))
            } else if !command.external, piped, resolution == .sequenceMethod, let methods = sequenceMethods[name] {
                stages.append(.function(narrowed(methods, command.overload), rest, redirects: redirects, environment: environment))
            } else if !command.external, piped, resolution == .itemMethod {
                stages.append(.method(name, rest, redirects: redirects, environment: environment))
            } else if !command.external, let functions = commandFunctions(named: name) {
                stages.append(.function(narrowed(functions, command.overload), rest, redirects: redirects, environment: environment))
            } else if !command.external, !piped, sequenceMethods[name] != nil, findExecutable(name) == nil {
                throw RuntimeError("\(name) is a method of sequences: pipe something into it, as in `ls | \(name)`, or call it on a list, as in `xs.\(name)(…)`")
            } else {
                let argv = try arguments.map { argument -> String in
                    guard case .text(let text) = argument else {
                        throw RuntimeError("\(name) is an external command, so it can't take a closure")
                    }
                    return text
                }
                // Not a program after all, and it was only a command because it
                // isn't an expression: that's the error to show (`1...2...3`).
                if let why = command.notAnExpression, !Shell.builtinNames.contains(name), !name.contains("/"),
                   findExecutable(name) == nil {
                    throw RuntimeError("\(name) isn't a command, and as an expression: \(why)")
                }
                // `run test`: the task file, in a Swish of its own.
                let program = !command.external && name == "run" ? try taskCommand(Array(argv.dropFirst())) : argv
                stages.append(.external(program, skipBuiltins: command.external || name == "run", redirects: redirects, environment: environment))
            }
        }
        return stages
    }

    /// Record fields first, then the few members values have.
    func member(_ name: String, of value: Value) throws -> Value {
        if case .enumValue(let enumValue) = value, name == "rawValue" {
            guard let raw = enumValue.rawValue else { throw RuntimeError("\(enumValue.type.name) has no raw values") }
            return raw
        }
        if case .object(let type as EnumType) = value, type.case(named: name) != nil, type.member(name) == nil {
            return try makeCase(type, name, nil) // Says what values it needs.
        }
        if case .object(let object) = value, name != "description" && name != "debugDescription" {
            if object is SwiftValue, let property = try bridgedProperty(name, of: value) { return property }
            guard let member = object.member(name) else {
                throw RuntimeError("\(object.typeName) has no member '\(name)'")
            }
            return member
        }
        // Every value has its textual form, as a CustomStringConvertible
        // does in Swift: what interpolation shows. A record's own field of
        // that name comes first.
        if name == "description" || name == "debugDescription" {
            if case .record(let record) = value, let field = record[name] { return field }
            return .string(name == "description" ? value.description : value.debugDescription)
        }
        // `pair.1`: a tuple's element by position, labeled or not.
        if case .record(let record) = value, record.typeName == nil, record[name] == nil,
           let position = Int(name), position >= 0, position < record.count {
            return Array(record)[position].value
        }
        if case .record(let record) = value, record[name] == nil, let type = structType(of: record),
           let found = try structMember(name, of: record, type) {
            return found
        }
        switch (value, name) {
        case (.output(let output), "text"): return .string(output.text)
        case (.output(let output), "lines"): return .list(output.lines.map(Value.string))
        case (.output(let output), "count"): return .int(output.lines.count)
        case (.output(let output), "isEmpty"): return .bool(output.text.isEmpty)
        case (.output(let output), "first"): return output.lines.first.map(Value.string) ?? .nothing
        case (.output(let output), "last"): return output.lines.last.map(Value.string) ?? .nothing
        case (.output(let output), "status"): return .record(output.status)
        case (.record(let record), _) where record[name] != nil: return record[name]!
        case (.record(let record), "count"): return .int(record.count)
        case (.record(let record), "isEmpty"): return .bool(record.count == 0)
        case (.record(let record), "keys"): return .list(record.keys.map(Value.string))
        case (.record(let record), "values"): return .list(record.map(\.value))
        case (.dictionary(let dictionary), "keys"): return .list(dictionary.keys)
        case (.dictionary(let dictionary), "values"): return .list(dictionary.values)
        case (.string(let text), "lines"):
            return .list(text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map { .string(String($0)) })
        case (.filesize(let bytes), "bytes"): return .int(Int(bytes))
        case (.record(let record), _):
            throw RuntimeError("\(record.typeName ?? "Record") has no field '\(name)'")
        default:
            // Swift's own properties, as a key path like `\.count` reads them.
            if let property = try bridgedProperty(name, of: value) { return property }
            throw RuntimeError("\(value.typeName) has no member '\(name)'")
        }
    }

    private func element(of base: Value, at index: Value) throws -> Value {
        if case .dictionary(let dictionary) = base {
            return dictionary[index] ?? .nothing
        }
        if case .record(let record) = base, case .string(let key) = index {
            return record[key] ?? .nothing
        }
        if case .output(let output) = base {
            return try element(of: .list(output.lines.map(Value.string)), at: index)
        }
        guard case .list(let elements) = base else {
            throw RuntimeError("\(base.typeName) can't be indexed")
        }
        guard case .int(let i) = index else {
            throw RuntimeError("a list index must be an Int, not \(index.typeName)")
        }
        guard elements.indices.contains(i) else {
            throw RuntimeError("index \(i) is out of range for a list of \(elements.count)")
        }
        return elements[i]
    }

    // MARK: Calls

    /// Runs `function` with its parameters bound to `arguments`.
    /// Calls `function`. A method gets `receiver` as `self`, and leaves it
    /// there as the method changed it.
    func invoke(_ function: Function, with arguments: [String: Value], receiver: Receiver? = nil) throws -> Value {
        guard callDepth < maxCallDepth else {
            throw RuntimeError("maximum call depth (\(maxCallDepth)) exceeded")
        }
        try checkInterrupt()
        switch function.body {
        case .native(let body):
            return try body(self, arguments)
        case .stream(let transform):
            // Called directly: the input is a list, and so is the result.
            let input = function.inputParameter.flatMap { arguments[$0.name] } ?? .list([])
            let output = try transform(self, .elements(of: input), arguments)
            var items: [Value] = []
            while let item = try output.next() { items.append(item) }
            return .list(items)
        case .swish:
            break
        }

        let savedScopes = scopes
        let argumentScope = Scope(arguments.mapValues { Binding(value: $0, mutable: false) })
        if let receiver {
            argumentScope.bindings["self"] = Binding(
                value: receiver.value, mutable: receiver.mutable, special: receiver.initializing ? .initializing : nil
            )
        }
        // A nested function reaches itself through the call, not by keeping
        // the binding it's stored in, which would be a cycle.
        if let name = function.name, function.captured.count > 2, argumentScope.bindings[name] == nil,
           case .swish = function.body {
            argumentScope.bindings[name] = Binding(
                value: .function(OverloadSet(name: name, candidates: [function])), mutable: false, isFunction: true
            )
        }
        scopes = function.captured + [argumentScope]
        callDepth += 1
        returnTypes.append(function.returnType)
        defer {
            if let receiver, let changed = argumentScope.bindings["self"]?.value { receiver.value = changed }
            scopes = savedScopes
            callDepth -= 1
            returnTypes.removeLast()
        }

        let result: Value
        if let expr = function.implicitReturn {
            result = try evaluate(expr, expecting: function.returnType)
        } else {
            guard case .swish(let body) = function.body else { preconditionFailure() }
            do {
                _ = try run(body)
                result = .nothing
            } catch ControlFlow.returned(let value) {
                result = value
            }
        }

        guard let returnType = function.returnType else { return result }
        guard let conforming = conform(result, to: returnType) else {
            let what = result == .nothing ? "nothing" : result.typeName
            throw RuntimeError("\(function.name ?? "closure") must return \(returnType), but returned \(what)")
        }
        return conforming
    }

    /// Calls a function value with positional arguments, as builtins like
    /// `where` call the closures they're given.
    func call(_ value: Value, with arguments: [Value]) throws -> Value {
        let unlabeled = arguments.map { Argument(label: nil, value: .literal($0)) }
        switch value {
        case .function(let set as OverloadSet):
            let (function, bindings) = try resolve(set) { try self.bind(unlabeled, to: $0) }
            return try invoke(function, with: bindings)
        case .function(let function as Function):
            return try invoke(function, with: try bind(unlabeled, to: function).bindings)
        case .function(let native as NativeFunction):
            let function = hostFunction(native.function)
            return try invoke(function, with: try bind(unlabeled, to: function).bindings)
        case .function(let keyPath as KeyPathValue):
            guard arguments.count == 1 else { throw RuntimeError("a key path reads one value") }
            return try keyPath.read(from: arguments[0], in: self)
        default:
            throw RuntimeError("\(value.typeName) isn't a function")
        }
    }

    /// A closure last and unlabeled can go to a labeled parameter, as a
    /// trailing closure does in Swift (`xs.sorted { $0.x < $1.x }` for
    /// `by:`), unless a later unlabeled parameter is waiting for it.
    private func isTrailingClosure(
        _ arguments: [Argument], at index: Int, for parameter: Parameter, before later: ArraySlice<Parameter>
    ) -> Bool {
        guard index == arguments.count - 1, arguments[index].label == nil, parameter.label != nil,
              later.allSatisfy({ $0.label != nil }) else { return false }
        switch arguments[index].value {
        case .closure, .literal(.function): return parameter.type.acceptsFunction
        default: return false
        }
    }

    /// Matches expression-mode arguments to parameters by Swift's rules:
    /// in order, labels must match, defaulted parameters may be skipped.
    ///
    /// The penalty counts conversions and untyped parameters, so overload
    /// resolution can prefer the most specific match.
    func bind(_ arguments: [Argument], to function: Function) throws -> (bindings: [String: Value], penalty: Int) {
        let name = function.name ?? "closure"
        var bound: [String: Value] = [:]
        var penalty = 0
        func checked(_ value: Value, for parameter: Parameter) throws -> Value {
            let result = try self.checked(value, for: parameter, of: name)
            if parameter.type == .any || !result.isEqual(to: value) || result.typeName != value.typeName { penalty += 1 }
            return result
        }
        var index = 0
        for (position, parameter) in function.parameters.enumerated() {
            if index < arguments.count, arguments[index].label == parameter.label
                || isTrailingClosure(arguments, at: index, for: parameter, before: function.parameters[(position + 1)...]) {
                if parameter.variadic {
                    var values: [Value] = []
                    repeat {
                        values.append(try evaluate(arguments[index].value, expecting: parameter.type))
                        index += 1
                    } while index < arguments.count && arguments[index].label == nil
                    bound[parameter.name] = try checked(.list(values), for: parameter)
                } else {
                    bound[parameter.name] = try checked(try evaluate(arguments[index].value, expecting: parameter.type), for: parameter)
                    index += 1
                }
            } else if parameter.variadic {
                bound[parameter.name] = .list([])
            } else if let defaultValue = parameter.defaultValue {
                bound[parameter.name] = try defaultArgument(defaultValue, for: parameter, of: function)
            } else if parameter.externalDefault != nil {
                continue // The plugin fills it in.
            } else {
                let label = parameter.label.map { "'\($0):'" } ?? "#\(function.parameters.firstIndex(of: parameter)! + 1)"
                throw RuntimeError("\(name): missing argument \(label)")
            }
        }
        guard index == arguments.count else {
            let extra = arguments[index].label.map { "'\($0):'" } ?? "#\(index + 1)"
            throw RuntimeError("\(name): unexpected argument \(extra)")
        }
        return (bound, penalty)
    }

    /// Defaults are evaluated at call time, in the scope the function was defined in.
    func defaultArgument(_ expr: Expr, for parameter: Parameter, of function: Function) throws -> Value {
        let savedScopes = scopes
        scopes = function.captured
        defer { scopes = savedScopes }
        return try checked(try evaluate(expr, expecting: parameter.type), for: parameter, of: function.name ?? "closure")
    }

    func checked(_ value: Value, for parameter: Parameter, of function: String) throws -> Value {
        let type = parameter.variadic ? TypeAnnotation.list(parameter.type) : parameter.type
        guard let conforming = conform(value, to: type) else {
            throw RuntimeError("\(function): '\(parameter.name)' must be \(type), not \(value.typeName)")
        }
        return conforming
    }

    // MARK: Capturing output

    /// Runs `body` with standard output redirected into a string, as `$(…)` does.
    func capturing(_ body: () throws -> Void) throws -> String {
        guard let pipe = makePipe() else { throw RuntimeError("pipe: \(errorMessage(errno))") }
        // Drain concurrently, so output larger than the pipe buffer can't
        // deadlock against the wait for the command to finish.
        let collector = OutputCollector(reading: pipe.read)
        let savedOutput = stdoutFD
        stdoutFD = pipe.write
        let result = Result { try body() }
        stdoutFD = savedOutput
        close(pipe.write)
        let output = collector.finish()
        try result.get()
        return output
    }
}

final class OutputCollector: @unchecked Sendable {
    private var bytes: [UInt8] = []
    private let done = DispatchSemaphore(value: 0)

    init(reading fd: Int32) {
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    bytes += buffer[..<count]
                } else if count == -1 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(fd)
            done.signal()
        }
    }

    func finish() -> String {
        done.wait()
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// `set` with only the overload the checker chose, when it did.
func narrowed(_ set: OverloadSet, _ overload: Int?) -> OverloadSet {
    guard let overload, set.candidates.indices.contains(overload) else { return set }
    return OverloadSet(name: set.name, candidates: [set.candidates[overload]])
}

enum Interpreter {
    /// A string literal, interpolated or not.
    static func isStringExpression(_ expr: Expr) -> Bool {
        switch expr {
        case .literal(.string), .string: true
        default: false
        }
    }
}

extension Value {
    var typeName: String {
        switch self {
        case .nothing: "Nothing"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .list: "List"
        case .record(let record): record.typeName ?? "Tuple"
        case .dictionary: "Dictionary"
        case .filesize: "FileSize"
        case .date: "Date"
        case .output: "Output"
        case .enumValue(let value): value.type.name
        case .object(let object): object.typeName
        case .function: "Function"
        @unknown default: "Value"
        }
    }

    var asDouble: Double? {
        switch self {
        case .int(let n): Double(n)
        case .double(let d): d
        default: nil
        }
    }

    /// `==` with Int and Double comparing numerically, as their literals
    /// would in Swift.
    func isEqual(to other: Value) -> Bool {
        switch (self, other) {
        case (.int, .double), (.double, .int):
            return asDouble == other.asDouble
        case (.list(let a), .list(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.isEqual(to: $1) }
        default:
            return self == other
        }
    }

    /// This value as `type`, or nil if it doesn't fit. An Int passes as a
    /// Double, as an integer literal would in Swift.
    func conforming(to type: TypeAnnotation) -> Value? {
        switch (type, self) {
        case (.output, .output):
            return self
        case (.string, .output(let output)):
            return .string(output.text)
        case (.list(.string), .output(let output)):
            return .list(output.lines.map(Value.string))
        // A key path is a function of one value, as in Swift, and no other kind.
        case (.functionType(let parameters, _, _), .function(is KeyPathValue)):
            return parameters.count == 1 ? self : nil
        case (.any, _), (.unknown, _), (.bool, .bool), (.int, .int), (.double, .double), (.string, .string),
             (.function, .function), (.functionType, .function), (.keyPath, .function), (.parameter, _),
             (.record, .record), (.filesize, .filesize),
             (.date, .date), (.void, .nothing):
            return self
        case (.tuple(let elements), .record(let record)):
            guard record.count == elements.count else { return nil }
            var converted = Record(typeName: record.typeName)
            for (index, (element, field)) in zip(elements, record).enumerated() {
                guard element.label == nil || element.label == field.key || field.key == String(index),
                      let value = field.value.conforming(to: element.type) else { return nil }
                converted[element.label ?? field.key] = value
            }
            return .record(converted)
        case (.dictionary(let keyType, let valueType), .dictionary(let dictionary)):
            var converted = ValueDictionary()
            for (key, value) in dictionary {
                guard let k = key.conforming(to: keyType), let v = value.conforming(to: valueType) else { return nil }
                converted[k] = v
            }
            return .dictionary(converted)
        case (.double, .int(let n)):
            return .double(Double(n))
        case (.optional, .nothing):
            return self
        case (.optional(let wrapped), _):
            return conforming(to: wrapped)
        case (.list(let element), .list(let values)):
            var converted: [Value] = []
            for value in values {
                guard let conforming = value.conforming(to: element) else { return nil }
                converted.append(conforming)
            }
            return .list(converted)
        default:
            return nil
        }
    }
}
