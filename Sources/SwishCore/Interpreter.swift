import Foundation
import SwishKit

struct RuntimeError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

struct Binding {
    var value: Value
    let mutable: Bool
}

/// How a unit's result is used.
enum UnitContext {
    /// A whole statement: an expression's value is displayed.
    case statement
    /// Part of a chain: only the exit status matters.
    case operand
    /// An `if` condition: expressions must be Bool.
    case condition
}

extension Shell {
    // MARK: Statements

    func run(_ program: Program) throws -> Int32 {
        var status: Int32 = 0
        for statement in program.statements {
            status = try run(statement)
            lastStatus = status
        }
        return status
    }

    func runBlock(_ program: Program) throws -> Int32 {
        scopes.append([:])
        defer { scopes.removeLast() }
        return try run(program)
    }

    private func run(_ statement: Statement) throws -> Int32 {
        switch statement {
        case .declare(let name, let mutable, let expr):
            let value = try evaluate(expr)
            scopes[scopes.count - 1][name] = Binding(value: value, mutable: mutable)
            return 0
        case .assign(let name, let expr):
            let value = try evaluate(expr)
            guard let depth = scopes.lastIndex(where: { $0[name] != nil }) else {
                throw RuntimeError("no variable named '\(name)'")
            }
            guard scopes[depth][name]!.mutable else {
                throw RuntimeError("cannot assign to '\(name)': it's a 'let' constant")
            }
            scopes[depth][name]!.value = value
            return 0
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
                ResolvedCommand(argv: try command.words.map { try expand($0) }, external: command.external)
            }
            return runPipeline(commands, source: node.source)

        case .expression(let expr):
            let value = try evaluate(expr)
            // A bare `true`/`false` stands in for the Unix commands: status only.
            let isBoolLiteral = if case .literal(.bool) = expr { true } else { false }
            if context == .statement && value != .nothing && !isBoolLiteral {
                writeAll(stdoutFD, value.description + "\n")
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
        }
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
        case .unary(let op, let operand):
            return try apply(op, try evaluate(operand))
        case .binary(.and, let lhs, let rhs):
            return .bool(try truth(lhs, for: .and) && truth(rhs, for: .and))
        case .binary(.or, let lhs, let rhs):
            return .bool(try truth(lhs, for: .or) || truth(rhs, for: .or))
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
            if let binding = scope[name] { return binding }
        }
        return nil
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
}
