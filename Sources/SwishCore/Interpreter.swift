import CShim
import Foundation
import SwishKit

struct RuntimeError: Error, CustomStringConvertible {
    let description: String
    /// The status the failure gives: a failed command's own, for `$(…)`.
    var status: Int32 = 1

    init(_ description: String, status: Int32 = 1) {
        self.description = description
        self.status = status
    }
}

/// A runtime error under `try!`: it stops a script, not just the line.
struct FatalError: Error {
    let error: RuntimeError
}

/// ^C while the shell itself was running code.
struct Interrupted: Error {}

/// Non-local exits, thrown up to the loop or call that handles them. The
/// parser guarantees each one has a handler.
private enum ControlFlow: Error {
    case returned(Value)
    case breakLoop
    case continueLoop
}

struct Binding {
    var value: Value
    let mutable: Bool
    /// Declared with `func`, which makes it callable in command mode.
    var isFunction = false
}

/// A reference type so closures share variables with the scope they
/// captured, as in Swift.
final class Scope {
    var bindings: [String: Binding]

    init(_ bindings: [String: Binding] = [:]) {
        self.bindings = bindings
    }
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

    init(
        name: String?, parameters: [Parameter], returnType: TypeAnnotation?, body: FunctionBody,
        captured: [Scope] = [], documentation: Documentation? = nil
    ) {
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

    /// A body that is a single expression returns its value, as in Swift.
    var implicitReturn: Expr? {
        guard case .swish(let body) = body, body.statements.count == 1,
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
        for statement in program.statements {
            try checkInterrupt()
            status = try run(statement)
            lastStatus = status
        }
        return status
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
        case .declare(let name, let mutable, let expr):
            let value = try evaluate(expr)
            scopes[scopes.count - 1].bindings[name] = Binding(value: value, mutable: mutable)
            return 0
        case .assign(let name, let expr):
            let value = try evaluate(expr)
            guard let scope = scopes.last(where: { $0.bindings[name] != nil }) else {
                throw RuntimeError("no variable named '\(name)'")
            }
            guard scope.bindings[name]!.mutable else {
                throw RuntimeError("cannot assign to '\(name)': it's a 'let' constant")
            }
            scope.bindings[name]!.value = value
            return 0
        case .function(let decl):
            // Captures the scope it's bound in, so it can call itself.
            let function = Function(
                name: decl.name, parameters: decl.parameters, returnType: decl.returnType,
                body: .swish(decl.body), captured: scopes, documentation: decl.documentation
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
        case .returnStatement(let expr):
            throw ControlFlow.returned(try expr.map(evaluate) ?? .nothing)
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
            var stages: [Stage] = []
            if let input = node.input {
                stages.append(.value(try evaluate(input)))
            }
            for command in node.commands {
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
                let redirects = try command.redirects.map(resolve)
                if !command.external, let functions = commandFunctions(named: name) {
                    stages.append(.function(functions, Array(arguments.dropFirst()), redirects: redirects))
                } else {
                    let argv = try arguments.map { argument -> String in
                        guard case .text(let text) = argument else {
                            throw RuntimeError("\(name) is an external command, so it can't take a closure")
                        }
                        return text
                    }
                    stages.append(.external(argv, skipBuiltins: command.external, redirects: redirects))
                }
            }
            return try runPipeline(stages, source: node.source, display: context == .statement)

        case .expression(let expr):
            let value = try evaluate(expr)
            // A bare `true`/`false` stands in for the Unix commands: status only.
            let isBoolLiteral = if case .literal(.bool) = expr { true } else { false }
            if context == .statement && !isBoolLiteral {
                display(value)
            }
            if case .bool(let truth) = value { return truth ? 0 : 1 }
            // nil is a failure, so `try? $(…) != nil && …` and `if try? …` work.
            if value == .nothing { return 1 }
            if context == .condition {
                throw RuntimeError("condition must be a Bool, not \(value.typeName)")
            }
            return 0

        case .ifStatement(let node):
            switch node.condition {
            case .chain(let chain):
                if try run(chain, context: .condition) == 0 {
                    return try runBlock(node.then)
                }
            case .binding(let name, let mutable, let expr):
                let value = try evaluate(expr)
                if value != .nothing {
                    return try runBlock(node.then, declaring: [name: Binding(value: value, mutable: mutable)])
                }
            }
            if let otherwise = node.otherwise {
                return try runBlock(otherwise)
            }
            return 0

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
    /// builds the list), and strings by character, as in Swift; command
    /// output is iterated with `.lines`.
    private func forEachElement(of sequence: Expr, _ body: (Value) throws -> Bool) throws {
        if case .binary(let op, let lower, let upper) = sequence, op == .closedRange || op == .halfOpenRange {
            for i in try intRange(op, try evaluate(lower), try evaluate(upper)) {
                guard try body(.int(i)) else { return }
            }
            return
        }
        let value = try evaluate(sequence)
        let elements: [Value]
        switch value {
        case .list(let list):
            elements = list
        case .string(let text):
            elements = text.map { .string(String($0)) }
        default:
            throw RuntimeError("can't iterate over \(value.typeName)")
        }
        for element in elements {
            guard try body(element) else { return }
        }
    }

    private func display(_ value: Value) {
        guard callDepth == 0 else { return }
        show(value)
    }

    func checkInterrupt() throws {
        if swish_take_interrupt() != 0 { throw Interrupted() }
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
            return binding.value
        case .dollar(let name):
            if let binding = lookup(name) { return binding.value }
            if let value = env(name) { return .string(value) }
            throw RuntimeError("no variable or environment variable named '\(name)'")
        case .status:
            return .int(Int(lastStatus))
        case .substitution(let program):
            var status: Int32 = 0
            var output = try capturing { status = try runBlock(program) }
            guard status == 0 else {
                throw RuntimeError("$(…) failed with status \(status); write try? $(…) to get nil instead", status: status)
            }
            while output.last == "\n" { output.removeLast() }
            return .string(output)
        case .list(let elements):
            return .list(try elements.map(evaluate))
        case .record(let entries):
            var record = Record()
            for entry in entries {
                let key = try evaluate(entry.key)
                guard case .string(let name) = key else {
                    throw RuntimeError("record keys must be Strings, not \(key.typeName)")
                }
                record[name] = try evaluate(entry.value)
            }
            return .record(record)
        case .member(let base, let name):
            return try member(name, of: try evaluate(base))
        case .closure(let literal):
            return .function(Function(
                name: nil, parameters: literal.parameters, returnType: literal.returnType,
                body: .swish(literal.body), captured: scopes
            ))
        case .call(let callee, let arguments):
            let value = try evaluate(callee)
            let values = try arguments.map { Argument(label: $0.label, value: .literal(try evaluate($0.value))) }
            switch value {
            case .function(let set as OverloadSet):
                let (function, bindings) = try resolve(set) { try self.bind(values, to: $0) }
                return try invoke(function, with: bindings)
            case .function(let function as Function):
                return try invoke(function, with: try bind(values, to: function).bindings)
            default:
                throw RuntimeError("\(value.typeName) isn't a function")
            }
        case .unary(let op, let operand):
            return try apply(op, try evaluate(operand))
        case .binary(.and, let lhs, let rhs):
            return .bool(try truth(lhs, for: .and) && truth(rhs, for: .and))
        case .binary(.or, let lhs, let rhs):
            return .bool(try truth(lhs, for: .or) || truth(rhs, for: .or))
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
        case .binary(.coalesce, let lhs, let rhs):
            let value = try evaluate(lhs)
            return value == .nothing ? try evaluate(rhs) : value
        case .binary(let op, let lhs, let rhs) where op == .closedRange || op == .halfOpenRange:
            let range = try intRange(op, try evaluate(lhs), try evaluate(rhs))
            guard range.count <= 10_000_000 else {
                throw RuntimeError("range of \(range.count) elements is too large to make a list; loop over it directly")
            }
            return .list(range.map(Value.int))
        case .binary(let op, let lhs, let rhs):
            return try apply(op, try evaluate(lhs), try evaluate(rhs))
        case .index(let base, let index):
            return try element(of: try evaluate(base), at: try evaluate(index))
        }
    }

    /// Joins a string's parts into one string. Interpolation never splits.
    private func expand(_ parts: [StringPart]) throws -> String {
        try parts.map { part in
            switch part {
            case .literal(let text), .glob(let text): text
            case .expression(let expr): try evaluate(expr).description
            }
        }.joined()
    }

    /// A command word's arguments: one, unless it has an unquoted wildcard,
    /// when it's the matching paths. Interpolated values are literal in the
    /// pattern, so `"$dir"/*.txt` works whatever `$dir` holds. A pattern
    /// that matches nothing is an error, not passed on as it is.
    private func expandWord(_ parts: [StringPart]) throws -> [String] {
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
            case .expression(let expr):
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
        for scope in scopes.reversed() {
            if let binding = scope.bindings[name] { return binding }
        }
        return nil
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

    private func apply(_ op: BinaryOperator, _ lhs: Value, _ rhs: Value) throws -> Value {
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

    /// Record fields first, then the few members values have.
    func member(_ name: String, of value: Value) throws -> Value {
        switch (value, name) {
        case (.record(let record), _) where record[name] != nil: return record[name]!
        case (.record(let record), "count"): return .int(record.count)
        case (.record(let record), "isEmpty"): return .bool(record.count == 0)
        case (.record(let record), "keys"): return .list(record.keys.map(Value.string))
        case (.record(let record), "values"): return .list(record.map(\.value))
        case (.list(let list), "count"): return .int(list.count)
        case (.list(let list), "isEmpty"): return .bool(list.isEmpty)
        case (.list(let list), "first"): return list.first ?? .nothing
        case (.list(let list), "last"): return list.last ?? .nothing
        case (.string(let text), "count"): return .int(text.count)
        case (.string(let text), "isEmpty"): return .bool(text.isEmpty)
        case (.string(let text), "lines"):
            return .list(text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map { .string(String($0)) })
        case (.filesize(let bytes), "bytes"): return .int(Int(bytes))
        case (.record(let record), _):
            throw RuntimeError("\(record.typeName ?? "Record") has no field '\(name)'")
        default:
            throw RuntimeError("\(value.typeName) has no member '\(name)'")
        }
    }

    private func element(of base: Value, at index: Value) throws -> Value {
        if case .record(let record) = base, case .string(let key) = index {
            return record[key] ?? .nothing
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
    func invoke(_ function: Function, with arguments: [String: Value]) throws -> Value {
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
        scopes = function.captured + [Scope(arguments.mapValues { Binding(value: $0, mutable: false) })]
        callDepth += 1
        defer {
            scopes = savedScopes
            callDepth -= 1
        }

        let result: Value
        if let expr = function.implicitReturn {
            result = try evaluate(expr)
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
        guard let conforming = result.conforming(to: returnType) else {
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
        default:
            throw RuntimeError("\(value.typeName) isn't a function")
        }
    }

    /// Matches expression-mode arguments to parameters by Swift's rules:
    /// in order, labels must match, defaulted parameters may be skipped.
    ///
    /// The penalty counts conversions and untyped parameters, so overload
    /// resolution can prefer the most specific match.
    private func bind(_ arguments: [Argument], to function: Function) throws -> (bindings: [String: Value], penalty: Int) {
        let name = function.name ?? "closure"
        var bound: [String: Value] = [:]
        var penalty = 0
        func checked(_ value: Value, for parameter: Parameter) throws -> Value {
            let result = try self.checked(value, for: parameter, of: name)
            if parameter.type == .any || !result.isEqual(to: value) || result.typeName != value.typeName { penalty += 1 }
            return result
        }
        var index = 0
        for parameter in function.parameters {
            if index < arguments.count, arguments[index].label == parameter.label {
                if parameter.variadic {
                    var values: [Value] = []
                    repeat {
                        values.append(try evaluate(arguments[index].value))
                        index += 1
                    } while index < arguments.count && arguments[index].label == nil
                    bound[parameter.name] = try checked(.list(values), for: parameter)
                } else {
                    bound[parameter.name] = try checked(try evaluate(arguments[index].value), for: parameter)
                    index += 1
                }
            } else if parameter.variadic {
                bound[parameter.name] = .list([])
            } else if let defaultValue = parameter.defaultValue {
                bound[parameter.name] = try defaultArgument(defaultValue, for: parameter, of: function)
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
        return try checked(try evaluate(expr), for: parameter, of: function.name ?? "closure")
    }

    func checked(_ value: Value, for parameter: Parameter, of function: String) throws -> Value {
        let type = parameter.variadic ? TypeAnnotation.list(parameter.type) : parameter.type
        guard let conforming = value.conforming(to: type) else {
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

private final class OutputCollector: @unchecked Sendable {
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

extension Value {
    var typeName: String {
        switch self {
        case .nothing: "Nothing"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .list: "List"
        case .record: "Record"
        case .filesize: "FileSize"
        case .date: "Date"
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
        case (.any, _), (.bool, .bool), (.int, .int), (.double, .double), (.string, .string), (.function, .function),
             (.record, .record), (.filesize, .filesize), (.date, .date):
            return self
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
