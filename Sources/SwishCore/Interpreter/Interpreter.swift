import Foundation
import SwishKit

/// The language: its scopes, what the checker remembers between entries, and
/// the evaluator (the `Interpreter+…` files). It knows nothing of the
/// terminal, processes or jobs: it reaches the world through its `host`, and
/// the shell's constructs through a `shellLayer`, which is internal and
/// temporary (Docs/Design/boundaries.md). The shell owns one.
final class Interpreter {
    /// How this interpreter is run: where its output goes, how to tell it to stop.
    var host: SwishHost

    /// What the core still can't do without the shell: the environment,
    /// commands, jobs. Nil for an embedder, which is refused plainly.
    var shellLayer: ShellLayer?

    /// Variable scopes, innermost last. The outermost holds the builtin
    /// functions, so a `func` at the prompt shadows one rather than
    /// overloading it.
    var scopes = [Scope(), Scope()]
    /// How many Swish function calls are in progress.
    var callDepth = 0
    /// Each enum's associated value types, by case, for checking them.
    var enumPayloadTypes: [ObjectIdentifier: [String: [TypeAnnotation]]] = [:]
    /// The protocols each enum declares.
    var enumConformances: [ObjectIdentifier: [String]] = [:]
    /// The return types of the functions being run, innermost last, so a
    /// returned `.case` knows its enum.
    var returnTypes: [TypeAnnotation?] = []
    /// Methods every sequence has, like `sorted` and `filter`.
    var sequenceMethods: [String: OverloadSet] = [:]
    /// The declared types of globals, from entries already checked, so a
    /// later one knows `let xs: [Int] = []` is an [Int].
    var staticTypes: [String: TypeAnnotation] = [:]
    /// Per-item errors reported so far, like a file `ls` couldn't read.
    var itemErrorCount = 0
    /// The syntax it accepts. Swift only, unless its owner adds the shell's.
    var dialect = Parser.Dialect.swift
    /// The file being run, for `#filePath`; nil at the prompt.
    var file: String?
    /// The status the last statement gave.
    var lastStatus: Int32 = 0
    /// The status the last signal-killed command gave, to tell 130 from ^C
    /// apart from a command that exited with 130.
    var lastSignalStatus: Int32?

    init(host: SwishHost = SwishHost(), shellLayer: ShellLayer? = nil) {
        self.host = host
        self.shellLayer = shellLayer
    }
}

extension Interpreter {
    /// Reports an error, to wherever standard error is redirected.
    func report(_ message: String) {
        let styled = host.error.traits().styled
        if message.hasPrefix("error: ") {
            host.error.write("swish: error:".styled(DisplayStyle.error, styled) + message.dropFirst(6) + "\n")
        } else {
            host.error.write("swish:".styled(DisplayStyle.error, styled) + " \(message)\n")
        }
    }

    /// Reports a problem with one item, like a file `ls` couldn't read,
    /// without stopping; the statement's status becomes a failure.
    func reportItemError(_ message: String) {
        report(message)
        itemErrorCount += 1
    }
}

extension Interpreter {
    /// Parses a program, knowing the names already declared.
    func parse(_ source: String) -> Result<Program, SyntaxError> {
        do {
            return .success(try Parser.parse(source, bound: globalNames(), dialect: dialect))
        } catch {
            return .failure(error)
        }
    }

    /// Names the parser should know: builtins and globals, as variables or functions.
    func globalNames() -> [String: NameKind] {
        scopes[0].bindings.merging(scopes[1].bindings) { $1 }.mapValues { binding in
            if binding.isFunction { return .function }
            if case .object(is EnumType) = binding.value { return .type }
            if case .object(is StructType) = binding.value { return .type }
            if case .object(is BridgedTypeName) = binding.value { return .type }
            return .variable
        }
    }
}
