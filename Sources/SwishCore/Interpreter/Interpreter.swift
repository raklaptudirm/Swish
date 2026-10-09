import Foundation
import SwishKit

/// The language: its scopes, what the checker remembers between entries, and
/// the evaluator (the `Interpreter+…` files). It knows nothing of the
/// terminal, processes or jobs: it reaches the world through its `host`, and
/// the shell's constructs through a `shellLayer`, which is internal and
/// temporary (Docs/Design/boundaries.md). The shell owns one.
package final class Interpreter {
    /// How this interpreter is run: where its output goes, how to tell it to stop.
    package var host: SwishHost

    /// What the core still can't do without the shell: the environment,
    /// commands, jobs. Nil for an embedder, which is refused plainly.
    package var shellLayer: ShellLayer?
    /// What runs this interpreter, if it is more than an embedder's call: the
    /// shell, whose nodes reach it from here. Weak, as the owner holds the
    /// interpreter.
    package weak var owner: AnyObject?
    /// The members, by name, of the host's object types that Swift doesn't
    /// declare (the shell's `Job`), for the checker.
    package var objectMembers: [String: [String: TypeAnnotation]] = [:]

    /// Variable scopes, innermost last. The outermost holds the builtin
    /// functions, so a `func` at the prompt shadows one rather than
    /// overloading it.
    package var scopes = [Scope(), Scope()]
    /// How many Swish function calls are in progress.
    package var callDepth = 0
    /// Each enum's associated value types, by case, for checking them.
    package var enumPayloadTypes: [ObjectIdentifier: [String: [TypeAnnotation]]] = [:]
    /// The protocols each enum declares.
    package var enumConformances: [ObjectIdentifier: [String]] = [:]
    /// The return types of the functions being run, innermost last, so a
    /// returned `.case` knows its enum.
    package var returnTypes: [TypeAnnotation?] = []
    /// Methods every sequence has, like `sorted` and `filter`.
    package var sequenceMethods: [String: OverloadSet] = [:]
    /// The declared types of globals, from entries already checked, so a
    /// later one knows `let xs: [Int] = []` is an [Int].
    package var staticTypes: [String: TypeAnnotation] = [:]
    /// Per-item errors reported so far, like a file `ls` couldn't read.
    package var itemErrorCount = 0
    /// Syntax added to Swift's, which its owner supplies (the shell's). Nil is
    /// Swift alone.
    package var syntax: (any SyntaxPlugin)?
    /// The file being run, for `#filePath`; nil at the prompt.
    package var file: String?
    /// The status the last statement gave.
    package var lastStatus: Int32 = 0
    /// The status the last signal-killed command gave, to tell 130 from ^C
    /// apart from a command that exited with 130.
    package var lastSignalStatus: Int32?

    package init(host: SwishHost = SwishHost(), shellLayer: ShellLayer? = nil) {
        self.host = host
        self.shellLayer = shellLayer
    }
}

extension Interpreter {
    /// Reports an error, to wherever standard error is redirected.
    package func report(_ message: String) {
        let styled = host.error.traits().styled
        if message.hasPrefix("error: ") {
            host.error.write("swish: error:".styled(DisplayStyle.error, styled) + message.dropFirst(6) + "\n")
        } else {
            host.error.write("swish:".styled(DisplayStyle.error, styled) + " \(message)\n")
        }
    }

    /// Reports a problem with one item, like a file `ls` couldn't read,
    /// without stopping; the statement's status becomes a failure.
    package func reportItemError(_ message: String) {
        report(message)
        itemErrorCount += 1
    }
}

extension Interpreter {
    /// Parses a program, knowing the names already declared.
    package func parse(_ source: String) -> Result<Program, SyntaxError> {
        do {
            return .success(try Parser.parse(source, bound: globalNames(), plugin: syntax))
        } catch {
            return .failure(error)
        }
    }

    /// Names the parser should know: builtins and globals, as variables or functions.
    package func globalNames() -> [String: NameKind] {
        scopes[0].bindings.merging(scopes[1].bindings) { $1 }.mapValues { binding in
            if binding.isFunction { return .function }
            if case .object(is EnumType) = binding.value { return .type }
            if case .object(is StructType) = binding.value { return .type }
            if case .object(is BridgedTypeName) = binding.value { return .type }
            return .variable
        }
    }
}
