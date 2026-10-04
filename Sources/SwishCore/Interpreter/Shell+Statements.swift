import Foundation
import SwishKit

/// How a unit's result is used.
enum UnitContext {
    /// A whole statement: an expression's value is displayed.
    case statement
    /// Part of a chain: only the exit status matters.
    case operand
    /// An `if` or `while` condition: expressions must be Bool.
    case condition
}

let maxCallDepth = 10_000

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
    func chooseBranch(_ node: IfStatement) throws -> (Program?, [String: Binding]) {
        if let bindings = try holds(node.condition) { return (node.then, bindings) }
        return (node.otherwise, [:])
    }

    /// What an `if` or `guard` condition binds when it holds; nil when it doesn't.
    func holds(_ condition: IfStatement.Condition) throws -> [String: Binding]? {
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
    func run(_ statement: Statement) throws -> Int32 {
        let errorsBefore = itemErrorCount
        let status = try runReportedErrorsAside(statement)
        return itemErrorCount > errorsBefore && status == 0 ? 1 : status
    }

    func runReportedErrorsAside(_ statement: Statement) throws -> Int32 {
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
            scopes[scopes.count - 1].declare(function, named: decl.name)
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

    func run(_ chain: Chain, context: UnitContext) throws -> Int32 {
        let unitContext = chain.links.isEmpty || context == .condition ? context : .operand
        var status = try run(chain.first, context: unitContext)
        for link in chain.links where (link.op == .and) == (status == 0) {
            status = try run(link.unit, context: unitContext)
        }
        return status
    }

    func run(_ unit: Unit, context: UnitContext) throws -> Int32 {
        switch unit {
        case .pipeline(let node):
            let stages = try stages(for: node)
            let status = try runPipeline(stages, source: node.source, display: context == .statement)
            // `try make`: failing throws, with the status in the error.
            if case .some(let kind) = node.throwing, status != 0 {
                let (code, signal) = exitCode(status)
                let error = RuntimeError("\(node.source) failed with status \(status)", status: status,
                                         output: Output(text: "", code: code, signal: signal))
                throw kind == .forced ? FatalError(error: error) : error
            }
            return status

        case .expression(let expr):
            let value = try evaluate(expr)
            // A bare `true`/`false` stands in for the Unix commands: status only.
            let isBoolLiteral = if case .literal(.bool) = expr { true } else { false }
            // `await build`: the job wrote to the terminal; its Output has
            // nothing more to show.
            let awaitedToTerminal = expr.isAwait && value.showsNothing
            // `xs.removeLast()` alone: Swift's @discardableResult.
            let discarded = if case .bridged(let type, let member, _, _) = expr {
                Bridge.types[type]?.members[member].discardableResult == true
            } else { false }
            if context == .statement && !isBoolLiteral && !awaitedToTerminal && !discarded {
                display(value)
            }
            if case .bool(let truth) = value { return truth ? 0 : 1 }
            // `await build && echo ok`: an Output's status is its command's.
            if let output = value.commandOutput, !output.succeeded {
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
    func runLoopBody(_ body: Program, declaring bindings: [String: Binding], status: inout Int32) throws -> Bool {
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
    func forEachElement(of sequence: Expr, _ body: (Value) throws -> Bool) throws {
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
    func display(_ value: Value) {
        guard callDepth == 0 else { return }
        show(value, debug: true)
    }

    func checkInterrupt() throws {
        if let signal = takeInterruptSignal() { throw Interrupted(signal: signal) }
    }
}
