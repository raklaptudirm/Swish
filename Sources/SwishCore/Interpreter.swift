import CShim
import Foundation
import SwishKit

struct RuntimeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
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

/// A Swish function or closure.
final class Function: Callable, @unchecked Sendable {
    let name: String?
    let parameters: [Parameter]
    let returnType: TypeAnnotation?
    let body: Program
    let captured: [Scope]

    init(name: String?, parameters: [Parameter], returnType: TypeAnnotation?, body: Program, captured: [Scope]) {
        self.name = name
        self.parameters = parameters
        self.returnType = returnType
        self.body = body
        self.captured = captured
    }

    var description: String {
        guard let name else { return "<closure>" }
        let labels = parameters.map { ($0.label ?? "_") + ":" }.joined()
        return "<func \(name)(\(labels))>"
    }

    /// A body that is a single expression returns its value, as in Swift.
    var implicitReturn: Expr? {
        guard body.statements.count == 1,
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

    private func run(_ statement: Statement) throws -> Int32 {
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
                body: decl.body, captured: scopes
            )
            scopes[scopes.count - 1].bindings[decl.name] = Binding(
                value: .function(function), mutable: false, isFunction: true
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
            let commands = try node.commands.map { command in
                let argv = try command.words.map { try expand($0) }
                return ResolvedCommand(
                    argv: argv,
                    external: command.external,
                    function: command.external ? nil : commandFunction(named: argv[0])
                )
            }
            return try runPipeline(commands, source: node.source, display: context == .statement)

        case .expression(let expr):
            let value = try evaluate(expr)
            // A bare `true`/`false` stands in for the Unix commands: status only.
            let isBoolLiteral = if case .literal(.bool) = expr { true } else { false }
            if context == .statement && !isBoolLiteral {
                display(value)
            }
            if case .bool(let truth) = value { return truth ? 0 : 1 }
            if context == .condition {
                throw RuntimeError("condition must be a Bool, not \(value.typeName)")
            }
            return 0

        case .ifStatement(let node):
            if try run(node.condition, context: .condition) == 0 {
                return try runBlock(node.then)
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
    /// builds the list), and strings by line, so `for f in $(ls)` works.
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
            elements = text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map { .string(String($0)) }
        default:
            throw RuntimeError("can't iterate over \(value.typeName)")
        }
        for element in elements {
            guard try body(element) else { return }
        }
    }

    private func display(_ value: Value) {
        guard callDepth == 0, value != .nothing else { return }
        writeAll(stdoutFD, value.description + "\n")
    }

    private func checkInterrupt() throws {
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
            var output = try capturing { _ = try runBlock(program) }
            while output.last == "\n" { output.removeLast() }
            return .string(output)
        case .list(let elements):
            return .list(try elements.map(evaluate))
        case .closure(let literal):
            return .function(Function(
                name: nil, parameters: literal.parameters, returnType: literal.returnType,
                body: literal.body, captured: scopes
            ))
        case .call(let callee, let arguments):
            let value = try evaluate(callee)
            guard case .function(let callable) = value, let function = callable as? Function else {
                throw RuntimeError("\(value.typeName) isn't a function")
            }
            let values = try arguments.map { Argument(label: $0.label, value: .literal(try evaluate($0.value))) }
            return try invoke(function, with: try bind(values, to: function))
        case .unary(let op, let operand):
            return try apply(op, try evaluate(operand))
        case .binary(.and, let lhs, let rhs):
            return .bool(try truth(lhs, for: .and) && truth(rhs, for: .and))
        case .binary(.or, let lhs, let rhs):
            return .bool(try truth(lhs, for: .or) || truth(rhs, for: .or))
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

    /// Joins a word or string's parts into one string. Interpolation never
    /// splits: each word is exactly one argument.
    private func expand(_ parts: [StringPart]) throws -> String {
        try parts.map { part in
            switch part {
            case .literal(let text): text
            case .expression(let expr): try evaluate(expr).description
            }
        }.joined()
    }

    private func lookup(_ name: String) -> Binding? {
        for scope in scopes.reversed() {
            if let binding = scope.bindings[name] { return binding }
        }
        return nil
    }

    /// The function a command name refers to, if it was declared with `func`.
    private func commandFunction(named name: String) -> Function? {
        guard let binding = lookup(name), binding.isFunction,
              case .function(let callable) = binding.value else { return nil }
        return callable as? Function
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
        default:
            break
        }
        throw RuntimeError("'\(op.rawValue)' can't be applied to \(lhs.typeName) and \(rhs.typeName)")
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

    private func element(of base: Value, at index: Value) throws -> Value {
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
            do {
                _ = try run(function.body)
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

    /// Matches expression-mode arguments to parameters by Swift's rules:
    /// in order, labels must match, defaulted parameters may be skipped.
    private func bind(_ arguments: [Argument], to function: Function) throws -> [String: Value] {
        let name = function.name ?? "closure"
        var bound: [String: Value] = [:]
        var index = 0
        for parameter in function.parameters {
            if index < arguments.count, arguments[index].label == parameter.label {
                if parameter.variadic {
                    var values: [Value] = []
                    repeat {
                        values.append(try evaluate(arguments[index].value))
                        index += 1
                    } while index < arguments.count && arguments[index].label == nil
                    bound[parameter.name] = try checked(.list(values), for: parameter, of: name)
                } else {
                    bound[parameter.name] = try checked(try evaluate(arguments[index].value), for: parameter, of: name)
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
        return bound
    }

    /// Defaults are evaluated at call time, in the scope the function was defined in.
    private func defaultArgument(_ expr: Expr, for parameter: Parameter, of function: Function) throws -> Value {
        let savedScopes = scopes
        scopes = function.captured
        defer { scopes = savedScopes }
        return try checked(try evaluate(expr), for: parameter, of: function.name ?? "closure")
    }

    private func checked(_ value: Value, for parameter: Parameter, of function: String) throws -> Value {
        let type = parameter.variadic ? TypeAnnotation.list(parameter.type) : parameter.type
        guard let conforming = value.conforming(to: type) else {
            throw RuntimeError("\(function): '\(parameter.name)' must be \(type), not \(value.typeName)")
        }
        return conforming
    }

    // MARK: Command-mode calls

    /// Calls a function with command-line arguments, displaying its result if
    /// asked. The status is 1 for a false result and 0 otherwise.
    func callCommand(_ function: Function, _ args: [String], display shouldDisplay: Bool) throws -> Int32 {
        let result = try invoke(function, with: try bind(commandLine: args, to: function))
        if shouldDisplay && result != .nothing {
            writeAll(stdoutFD, result.description + "\n")
        }
        if case .bool(let truth) = result { return truth ? 0 : 1 }
        return 0
    }

    /// Derives a command-line interface from the signature (see
    /// docs/design/callables.md): unlabeled parameters are positional,
    /// labeled ones are `--kebab-case` flags, Bools are switches.
    private func bind(commandLine args: [String], to function: Function) throws -> [String: Value] {
        let name = function.name ?? "closure"
        var flags: [String: (parameter: Parameter, negated: Bool)] = [:]
        for parameter in function.parameters {
            guard let label = parameter.label else { continue }
            flags[kebabCase(label)] = (parameter, false)
            if parameter.type == .bool, case .literal(.bool(true)) = parameter.defaultValue {
                flags["no-" + kebabCase(label)] = (parameter, true)
            }
        }

        var bound: [String: Value] = [:]
        var positionals: [String] = []
        var index = 0
        var flagsEnded = false
        while index < args.count {
            let arg = args[index]
            index += 1
            if flagsEnded || !arg.hasPrefix("-") || arg == "-" || Double(arg) != nil {
                positionals.append(arg)
                continue
            }
            if arg == "--" {
                flagsEnded = true
                continue
            }
            guard arg.hasPrefix("--") else { throw RuntimeError("\(name): unknown option \(arg)") }

            let body = arg.dropFirst(2)
            let flagName = String(body.prefix { $0 != "=" })
            let inline = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
            guard let (parameter, negated) = flags[flagName] else {
                throw RuntimeError("\(name): unknown option --\(flagName)")
            }

            if parameter.type == .bool && (inline == nil || negated) {
                guard inline == nil else { throw RuntimeError("\(name): --\(flagName) doesn't take a value") }
                bound[parameter.name] = .bool(!negated)
                continue
            }
            let text: String
            if let inline {
                text = inline
            } else {
                guard index < args.count else { throw RuntimeError("\(name): --\(flagName) needs a value") }
                text = args[index]
                index += 1
            }
            if case .list(let elementType) = parameter.type {
                // Repeated flags accumulate: --include a --include b.
                let element = try converted(text, to: elementType, for: "--\(flagName)", of: name)
                if case .list(let existing) = bound[parameter.name] {
                    bound[parameter.name] = .list(existing + [element])
                } else {
                    bound[parameter.name] = .list([element])
                }
            } else {
                guard bound[parameter.name] == nil else { throw RuntimeError("\(name): --\(flagName) given twice") }
                bound[parameter.name] = try converted(text, to: parameter.type, for: "--\(flagName)", of: name)
            }
        }

        var remaining = positionals[...]
        for parameter in function.parameters where parameter.label == nil {
            let what = "<\(parameter.name)>"
            if parameter.variadic {
                bound[parameter.name] = .list(try remaining.map { try converted($0, to: parameter.type, for: what, of: name) })
                remaining = []
            } else if let text = remaining.popFirst() {
                bound[parameter.name] = try converted(text, to: parameter.type, for: what, of: name)
            }
        }
        if let extra = remaining.first {
            throw RuntimeError("\(name): unexpected argument '\(extra)'")
        }

        for parameter in function.parameters where bound[parameter.name] == nil {
            if let defaultValue = parameter.defaultValue {
                bound[parameter.name] = try defaultArgument(defaultValue, for: parameter, of: function)
            } else if parameter.type == .bool && parameter.label != nil {
                bound[parameter.name] = .bool(false)
            } else if case .list = parameter.type, parameter.label != nil {
                bound[parameter.name] = .list([])
            } else {
                let what = parameter.label.map { "--\(kebabCase($0))" } ?? "<\(parameter.name)>"
                throw RuntimeError("\(name): missing \(what)")
            }
        }
        return bound
    }

    private func converted(_ text: String, to type: TypeAnnotation, for what: String, of function: String) throws -> Value {
        let value: Value? = switch type {
        case .any, .string: .string(text)
        case .int: Int(text).map(Value.int)
        case .double: Double(text).map(Value.double)
        case .bool: ["true": true, "false": false][text].map(Value.bool)
        case .list, .function: nil
        }
        guard let value else {
            throw RuntimeError("\(function): \(what) must be \(type), got '\(text)'")
        }
        return value
    }

    private func kebabCase(_ label: String) -> String {
        label.reduce(into: "") { result, c in
            if c.isUppercase {
                result += "-" + c.lowercased()
            } else {
                result.append(c)
            }
        }
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
        case (.any, _), (.bool, .bool), (.int, .int), (.double, .double), (.string, .string), (.function, .function):
            return self
        case (.double, .int(let n)):
            return .double(Double(n))
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
