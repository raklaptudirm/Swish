import Foundation
import SwishKit

// MARK: - AST

struct Program: Equatable, Sendable {
    var statements: [Statement]
    /// Each statement's line in the source, 1-based, for error messages.
    var lines: [Int] = []

    /// Programs are equal by what they say, wherever it was written.
    static func == (lhs: Program, rhs: Program) -> Bool {
        lhs.statements == rhs.statements
    }
}

enum Statement: Equatable, Sendable {
    case declare(name: String, mutable: Bool, value: Expr)
    /// `x = v`, `p.x += 1`, `xs[0] = v`.
    case assign(Assignment)
    case function(FunctionDecl)
    /// `env.NAME = value` or `env["NAME"] = value`; nil unsets it.
    case setEnvironment(name: Expr, value: Expr)
    /// `do { … } catch { … }`: a runtime error in the body runs the
    /// handler with `error` (or the name given) bound to it.
    case doCatch(body: Program, errorName: String, handler: Program?)
    case enumDecl(EnumDecl)
    case structDecl(StructDecl)
    /// `extension Sequence { func filter(…) … }`: the prelude's methods of
    /// every sequence.
    case extensionDecl(name: String, methods: [FunctionDecl])
    /// `import Tools from "./Tools"`: builds a Swift package and loads the
    /// functions it exports.
    case importPlugin(name: String, path: Expr)
    /// `defer { … }`: runs when the block it's in ends, however it ends,
    /// last deferred first. At a script's top level, when the script ends.
    case deferBlock(Program)
    /// Carries on into the next case of a switch.
    case fallthroughStatement
    case returnStatement(Expr?)
    case breakStatement
    case continueStatement
    case chain(Chain)
}

/// Units joined by `&&`/`||`, evaluated left to right on exit status.
struct Chain: Equatable, Sendable {
    var first: Unit
    var links: [Link] = []
}

struct Link: Equatable, Sendable {
    var op: ChainOperator
    var unit: Unit
}

enum ChainOperator: Equatable, Sendable {
    case and, or
}

indirect enum Unit: Equatable, Sendable {
    case pipeline(PipelineNode)
    case expression(Expr)
    case ifStatement(IfStatement)
    case switchStatement(SwitchStatement)
    case forLoop(ForLoop)
    case whileLoop(WhileLoop)
}

struct IfStatement: Equatable, Sendable {
    enum Condition: Equatable, Sendable {
        case chain(Chain)
        /// `if let name = value`: runs the body with `name` bound when the
        /// value isn't nil.
        case binding(name: String, mutable: Bool, value: Expr)
        /// `if case .failed(let code) = result`.
        case pattern(Pattern, Expr)
    }

    var condition: Condition
    var then: Program
    var otherwise: Program?
}

/// `enum Name: RawType { case a, b(label: Type) = raw }`
struct EnumDecl: Equatable, Sendable {
    var name: String
    var rawType: TypeAnnotation?
    var cases: [EnumCaseDecl]
    /// `enum Level: Int, Comparable`: the protocols after any raw type.
    var conformances: [String] = []
}

struct EnumCaseDecl: Equatable, Sendable {
    var name: String
    var rawValue: Expr?
    var associated: [AssociatedValue]
}

struct AssociatedValue: Equatable, Sendable {
    var label: String?
    var type: TypeAnnotation
}

struct SwitchStatement: Equatable, Sendable {
    var subject: Expr
    var cases: [SwitchCase]
}

/// `case p1, p2 where guard: body`; no patterns is `default:`.
struct SwitchCase: Equatable, Sendable {
    var patterns: [Pattern]
    var guardExpr: Expr?
    var body: Program
}

indirect enum Pattern: Equatable, Sendable {
    /// `_`
    case wildcard
    /// `let x`: matches anything, binding it.
    case binding(name: String, mutable: Bool)
    /// `.failed(code: let c)`, or `Result.failed(…)`; nil arguments match
    /// whatever associated values the case has.
    case enumCase(type: String?, name: String, arguments: [PatternArgument]?)
    /// A value to compare with, or a range to be in: `3`, `"a"`, `1...9`.
    case expression(Expr)
}

struct PatternArgument: Equatable, Sendable {
    var label: String?
    var pattern: Pattern
}

struct ForLoop: Equatable, Sendable {
    var variable: String
    var sequence: Expr
    var body: Program
}

struct WhileLoop: Equatable, Sendable {
    var condition: Chain
    var body: Program
}

struct FunctionDecl: Equatable, Sendable {
    var name: String
    var parameters: [Parameter]
    var returnType: TypeAnnotation?
    var body: Program
    var documentation: Documentation?
    /// A struct's `mutating func`, which may change `self`.
    var isMutating = false
    /// `throws`: calling it needs `try`.
    var isThrowing = false
    /// `rethrows`: it throws only if a closure passed to it does.
    var isRethrowing = false
    /// `<T, V: Comparable>` and `where` clauses: each type parameter, and
    /// the protocols it must conform to. Only the prelude has these, for now.
    var generics: [String: [String]] = [:]
    var names = NamesUsed()
}

/// Assigning to a variable, or to part of one: `p.x`, `xs[0]`, `r["k"]`.
struct Assignment: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        case member(String)
        case index(Expr)
    }

    var root: String
    var path: [Step] = []
    /// `+=` and the like: the operator applied to the current value.
    var op: BinaryOperator?
    var value: Expr
}

/// `struct Name { var x: Int; func f() {…}; init(…) {…} }`.
struct StructDecl: Equatable, Sendable {
    var name: String
    var properties: [PropertyDecl]
    var methods: [FunctionDecl]
    var initializers: [FunctionDecl]
    /// `struct Point: Equatable, Hashable`.
    var conformances: [String] = []
}

struct PropertyDecl: Equatable, Sendable {
    var name: String
    var mutable: Bool
    var type: TypeAnnotation? = nil
    var defaultValue: Expr? = nil
    /// A computed property's body; nil for a stored one.
    var getter: Program? = nil
    var getterNames = NamesUsed()
}

/// The `#` comment block directly above a `func`, for `--help`.
struct Documentation: Equatable, Sendable {
    var summary: String
    /// From `- Parameter name: description` lines.
    var parameters: [String: String]
}

struct ClosureLiteral: Equatable, Sendable {
    /// For `{ $0 * 2 }`, the implicit `$0`, `$1`, … parameters.
    var parameters: [Parameter]
    var returnType: TypeAnnotation?
    var body: Program
    var names = NamesUsed()
}

/// The names a body mentions, so a closure keeps only the variables it
/// uses rather than every scope around it (which would keep the scope it's
/// stored in, and leak). Not part of what the code says, so it doesn't
/// count toward equality.
struct NamesUsed: Equatable, Sendable {
    var names: Set<String> = []

    static func == (lhs: NamesUsed, rhs: NamesUsed) -> Bool { true }
}

struct Parameter: Equatable, Sendable {
    /// The argument label; nil for `_` (positional in command mode).
    var label: String?
    var name: String
    var type: TypeAnnotation = .any
    var variadic = false
    var defaultValue: Expr?
    /// `@input`: receives pipeline input; per item, or the whole stream
    /// if its type is a list.
    var isInput = false
    /// `@flag("n")`: a short flag in command mode.
    var shortFlag: Character?
    /// A plugin's default only Swift can compute, like `Date()`: the
    /// argument is left out for the plugin to fill in. Its source, for help.
    var externalDefault: String?

    var hasDefault: Bool { defaultValue != nil || externalDefault != nil }
}

/// A type, as written in a declaration and as the checker works it out.
indirect enum TypeAnnotation: Hashable, Sendable, CustomStringConvertible {
    case any, bool, int, double, string
    /// A record whose fields aren't known: a builtin's row, until the
    /// builtins declare their types.
    case record
    case filesize, date, output
    /// `()`: what a function without `->` returns.
    case void
    /// A struct or enum, declared in Swish or by the shell, like `FileType`.
    case named(String)
    case list(TypeAnnotation)
    /// `[K: V]`.
    case dictionary(TypeAnnotation, TypeAnnotation)
    /// `(name: String, Int)`.
    case tuple([TupleElement])
    /// A generic parameter, like `Element` or `T` in a builtin's signature.
    case parameter(String)
    /// `KeyPath<Root, Value>`, what `\.size` is.
    case keyPath(TypeAnnotation, TypeAnnotation)
    /// Any function: a closure whose signature isn't known yet.
    case function
    /// `(Int, String) -> Bool`, or `(Int) throws -> Bool`.
    case functionType([TypeAnnotation], TypeAnnotation, throws: Bool = false)
    /// `T?`: a T, or nil.
    case optional(TypeAnnotation)
    /// A generic Swift type Swish holds as it is: `Set<Int>`, `ClosedRange<Int>`.
    case generic(String, [TypeAnnotation])
    /// What a Swift parameter `S: Sequence` with `S.Element == E` takes:
    /// any sequence of E, as `some Sequence<E>` says.
    case someSequence(TypeAnnotation)
    /// Not known yet: what a program prints, or a builtin that hasn't
    /// declared its type. It fits anywhere, and anything fits it.
    case unknown

    struct TupleElement: Hashable, Sendable {
        var label: String?
        var type: TypeAnnotation
    }

    var description: String {
        switch self {
        case .any: "Any"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .record: "Record"
        case .filesize: "FileSize"
        case .date: "Date"
        case .output: "Output"
        case .void: "Void"
        case .list(let element): "[\(element)]"
        case .dictionary(let key, let value): "[\(key): \(value)]"
        case .tuple(let elements):
            "(" + elements.map { ($0.label.map { "\($0): " } ?? "") + $0.type.description }.joined(separator: ", ") + ")"
        case .function: "function"
        case .functionType(let parameters, let result, let throwing):
            "(" + parameters.map(\.description).joined(separator: ", ") + ")" + (throwing ? " throws" : "") + " -> \(result)"
        case .named(let name), .parameter(let name): name
        case .generic(let name, let arguments): "\(name)<\(arguments.map(\.description).joined(separator: ", "))>"
        case .someSequence(let element): "some Sequence<\(element)>"
        case .keyPath(let root, let value): "KeyPath<\(root), \(value)>"
        case .optional(let wrapped):
            if case .functionType = wrapped { "(\(wrapped))?" } else { "\(wrapped)?" }
        case .unknown: "_"
        }
    }
}

struct PipelineNode: Equatable, Sendable {
    var commands: [CommandNode]
    /// The pipeline as typed, for job messages like "Stopped".
    var source: String
    /// A value feeding the pipeline, as in `[3, 1, 2] | sort`.
    var input: Expr?
    /// `try make` (`.some(nil)`) or `try! make`: failing throws, rather than
    /// only setting the status.
    var throwing: TryKind?? = nil
}

struct CommandNode: Equatable, Sendable {
    var words: [Word]
    /// `^name`: skip functions and builtins, and run the external program.
    var external = false
    /// In the order written, which matters: `> out e>o` sends both to
    /// `out`, `e>o > out` only standard output.
    var redirects: [Redirect] = []
    /// `EDITOR=vim git commit`: environment variables for this command only.
    var environment: [EnvironmentAssignment] = []
    /// `sorted(by: "size")` after a `|`: arguments written as a call.
    var call: [Argument]? = nil
    /// What the checker found the name to be, from the type of what's piped
    /// in; nil when it couldn't tell, and the interpreter looks.
    var resolution: StageResolution? = nil
    /// For a stage written as a call, the overload the checker chose.
    var overload: Int? = nil
}

/// What a pipeline stage's name is, given what flows into it.
enum StageResolution: Equatable, Sendable {
    /// A method of the sequence: `ls | sorted`.
    case sequenceMethod
    /// A method of each item: `points | describe`.
    case itemMethod
    /// Neither: a function or a program, looked up as for the first command.
    case other
}

struct EnvironmentAssignment: Equatable, Sendable {
    var name: String
    var value: [StringPart]
}

/// `> file`, `e>> file`, `< file`, `e>o` and the like.
struct Redirect: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case file([StringPart], Mode)
        /// Another of the command's descriptors, as in `e>o`.
        case descriptor(Int32)
    }

    enum Mode: Equatable, Sendable {
        case read, write, append
    }

    var fd: Int32
    var target: Target
}

enum Word: Equatable, Sendable {
    case text([StringPart])
    /// `where { $0.size > 1.mb }`: a closure passed as an argument.
    case closure(ClosureLiteral)
}

enum StringPart: Equatable, Sendable {
    case literal(String)
    case expression(Expr)
    /// Unquoted text with a wildcard, like `*.swift`; only unquoted
    /// wildcards expand to file names.
    case glob(String)
}

struct RecordEntry: Equatable, Sendable {
    var key: Expr
    var value: Expr
}

struct Argument: Equatable, Sendable {
    var label: String?
    var value: Expr
}

indirect enum Expr: Equatable, Sendable {
    /// `await j`, or `try await j`.
    var isAwait: Bool {
        switch self {
        case .await: true
        case .attempt(let inner, _): inner.isAwait
        default: false
        }
    }

    case literal(Value)
    case string([StringPart])
    case variable(String)
    /// `$name`: a Swish variable, falling back to the environment.
    case dollar(String)
    /// `$(…)`: the command's Output, whatever its status. Under `try`
    /// (`throwing`), a non-zero status throws instead.
    case substitution(Program, throwing: Bool = false)
    /// `try expr`, `try? expr` or `try! expr`.
    case attempt(Expr, TryKind)
    /// `async swift build` or `async $(curl …)`: starts it in the background.
    case async(AsyncTarget)
    /// `await job`, or a bare `await` for the most recent job. Under `try`
    /// (`throwing`), a job that failed throws.
    case await(Expr?, throwing: Bool)
    case list([Expr])
    case record([RecordEntry])
    case closure(ClosureLiteral)
    case call(Expr, [Argument])
    /// `value.name`: a record field, or a member like `count`.
    case member(Expr, String)
    /// `.directory` or `.failed(code: 2)`: a case whose enum comes from
    /// context, like the other side of `==` or a parameter's type.
    case caseLiteral(String, [Argument]?)
    case unary(UnaryOperator, Expr)
    case binary(BinaryOperator, Expr, Expr)
    case index(Expr, Expr)
    /// `(name: "x", 2)`: a tuple, labeled or not.
    case tuple([Argument])
    /// `let x: T = e`: the value, of the type written.
    case annotated(Expr, TypeAnnotation)
    /// `x!`: the optional's value; nil stops with an error.
    case forceUnwrap(Expr)
    /// `x?.name`: nil if `x` is, and its member otherwise.
    case optionalMember(Expr, String)
    /// `x?[i]`: nil if `x` is, and its element otherwise.
    case optionalIndex(Expr, Expr)
    /// A function, method or initializer, with the overload the checker
    /// chose: the candidate at that position. Only the checker makes these.
    case chosen(Expr, overload: Int)
    /// A member of a Swift type, bridged (Bridge.swift): the member the
    /// checker chose, by its position among its type's, with `self` if it
    /// isn't static. Only the checker makes these.
    case bridged(type: String, member: Int, receiver: Expr?, arguments: [Argument])
    /// `x as? T`, `x as! T`, `x is T`, or `x as T`.
    case cast(Expr, TypeAnnotation, CastKind)
    /// `#filePath`: the path of the script it's in.
    case filePath
    /// `\.size` or `\FileEntry.size`: a key path, its root type given or
    /// taken from context.
    case keyPath(root: String?, path: [String])
    /// A call returning Void, as a value: `()` once it's run, so `try?`
    /// can tell success (`()`) from failure (nil). Only the checker makes these.
    case voidValue(Expr)
}

indirect enum AsyncTarget: Equatable, Sendable {
    case command(PipelineNode)
    /// `async $(…)`: its output is kept, for `await` to give.
    case capture(PipelineNode)
}

enum TryKind: Equatable, Sendable {
    /// `try`: an error goes on to whatever handles it.
    case plain
    /// `try?`: nil instead of a runtime error.
    case optional
    /// `try!`: a runtime error stops the whole script, not just the line.
    case forced
}

enum CastKind: Equatable, Sendable {
    /// `as?`: the value as that type, or nil.
    case conditional
    /// `as!`: the value as that type, or an error.
    case forced
    /// `is`: whether it's that type.
    case check
    /// `as`: the same value, seen as a type it already fits.
    case upcast
}

enum UnaryOperator: String, Sendable {
    case not = "!"
    case negate = "-"
}

enum BinaryOperator: String, Sendable {
    case or = "||", and = "&&"
    case coalesce = "??"
    case equal = "==", notEqual = "!="
    case lessEqual = "<=", greaterEqual = ">=", less = "<", greater = ">"
    case closedRange = "...", halfOpenRange = "..<"
    case add = "+", subtract = "-"
    case multiply = "*", divide = "/", remainder = "%"
}

/// What a name refers to, which decides the mode of a statement starting
/// with it: a variable starts an expression, a function starts a command
/// unless it's followed by `(`.
enum NameKind: Equatable, Sendable {
    /// `type`: an enum's or struct's name, as in `FileType.directory`.
    /// `member`: a property or method of the struct whose body this is,
    /// read through `self`.
    case variable, function, type, member
}

public struct SyntaxError: Error, Equatable, CustomStringConvertible {
    public let description: String
    /// The input ended in the middle of a construct, so more lines could complete it.
    public let incomplete: Bool

    init(_ description: String, incomplete: Bool = false) {
        self.description = description
        self.incomplete = incomplete
    }

    static func incomplete(_ description: String) -> SyntaxError {
        SyntaxError(description, incomplete: true)
    }
}

/// What a stretch of source is, for syntax highlighting. The parser
/// records these as it goes, so the colors always agree with how the line
/// will actually be read.
enum SpanKind: Equatable, Sendable {
    case keyword, command, flag, string, number, constant, variable, comment, type, punctuation
}

struct Span: Equatable, Sendable {
    var range: Range<Int>
    var kind: SpanKind
}

// MARK: - Parser

/// A recursive-descent parser over characters rather than tokens, because
/// command mode and expression mode split text differently: `-la` is a word
/// in one and a negation in the other.
///
/// Mode is decided per unit, from its first token (see `startsExpression`).
/// Deciding it needs to know which names exist and what they are, so the
/// parser tracks declarations lexically, seeded with the shell's globals.
struct Parser {
    private static let keywords: Set = [
        "let", "var", "if", "else", "true", "false", "nil",
        "for", "in", "while", "func", "return", "break", "continue", "try", "do", "catch",
        "async", "await", "enum", "switch", "case", "default", "fallthrough", "import", "struct", "throws",
        "as", "is", "defer",
    ]
    private static let statementKeywords: Set = ["let", "var", "func", "return", "break", "continue", "do", "catch", "enum", "fallthrough", "import", "struct", "defer"]
    private static let precedence: [[BinaryOperator]] = [
        [.or],
        [.and],
        // Two-character operators first, so `<=` isn't read as `<`.
        [.equal, .notEqual, .lessEqual, .greaterEqual, .less, .greater],
        [.coalesce],
        [.closedRange, .halfOpenRange],
        [.add, .subtract],
        [.multiply, .divide, .remainder],
    ]
    private static let comparisonLevel = 2
    static let fileSizeUnits: [String: Int64] = [
        "b": 1, "kb": 1_000, "mb": 1_000_000, "gb": 1_000_000_000, "tb": 1_000_000_000_000,
        "kib": 1 << 10, "mib": 1 << 20, "gib": 1 << 30, "tib": 1 << 40,
    ]
    /// Levels whose operators can't be chained, like `a < b < c`.
    private static let nonAssociativeLevels: Set = [2, 4]

    private let chars: [Character]
    private var pos = 0
    private var scopes: [[String: NameKind]]
    /// Parsing the prelude: builtins' declarations, which may be generic and
    /// have no bodies (their bodies are in Swift).
    private var prelude = false
    /// Type parameters in scope, innermost last: `T`, or `Element`.
    private var typeParameters: [Set<String>] = []
    /// The names each body being parsed mentions, innermost last.
    private var namesUsed: [Set<String>] = []
    /// What the body just parsed mentioned.
    private var lastBodyNames = NamesUsed()

    /// A name the body being parsed refers to.
    private mutating func use(_ name: String) {
        guard !namesUsed.isEmpty else { return }
        namesUsed[namesUsed.count - 1].insert(name)
    }
    /// An `import` came earlier: the functions it brings aren't known until
    /// it runs, so calling an unknown name is left for then.
    private var sawImport = false
    /// Where each line starts, for `line(at:)`.
    private var lineStarts: [Int] = [0]
    /// Inside (), [] and \( ), newlines don't end an expression.
    private var bracketDepth = 0
    private var loopDepth = 0
    private var functionDepth = 0
    /// Inside a switch's cases, where `fallthrough` and `break` make sense.
    private var switchDepth = 0
    /// Inside an `if`/`while` condition, `{` after a command starts the body
    /// rather than a closure argument.
    private var conditionDepth = 0
    /// Inside the operand of `try`, `try?` or `try!`, where `$(…)` throws
    /// when its command fails. Closures and function bodies start afresh:
    /// they decide for themselves whether to throw, as in Swift.
    private var tryDepth = 0
    /// One entry per enclosing function or closure: how many `$n`
    /// parameters a closure without named parameters uses, or nil if its
    /// parameters are named.
    private var anonymousArity: [Int?] = []

    /// Highlight spans, in the order recorded; inner spans (like an
    /// interpolation inside a string) are shorter than what contains them.
    /// Input that doesn't parse yet, as while typing, still gets the spans
    /// found before the problem.
    private(set) var spans: [Span] = []

    static func parse(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program {
        var parser = Parser(source, bound: bound)
        return try parser.parseProgram(until: nil)
    }

    /// The prelude: builtins' types and signatures (see Prelude.swift).
    static func parsePrelude(_ source: String, bound: [String: NameKind]) throws(SyntaxError) -> Program {
        var parser = Parser(source, bound: bound)
        parser.prelude = true
        return try parser.parseProgram(until: nil)
    }

    static func highlight(_ source: String, bound: [String: NameKind]) -> [Span] {
        var parser = Parser(source, bound: bound)
        _ = try? parser.parseProgram(until: nil)
        return parser.spans
    }

    private mutating func mark(_ kind: SpanKind, from start: Int, to end: Int? = nil) {
        let end = min(end ?? pos, chars.count)
        if start < end { spans.append(Span(range: start..<end, kind: kind)) }
    }

    /// Backs up after looking ahead, dropping spans recorded on the way.
    private mutating func rewind(to state: (position: Int, spans: Int)) {
        pos = state.position
        spans.removeSubrange(state.spans...)
    }

    /// Consumes a keyword known to be at the current position.
    private mutating func keyword(_ word: String) {
        mark(.keyword, from: pos, to: pos + word.count)
        pos += word.count
    }

    private init(_ source: String, bound: [String: NameKind]) {
        chars = Array(source.replacingOccurrences(of: "\r\n", with: "\n"))
        scopes = [bound]
        for (index, c) in chars.enumerated() where c == "\n" { lineStarts.append(index + 1) }
    }

    // MARK: Statements

    private mutating func parseProgram(until terminator: Character?) throws(SyntaxError) -> Program {
        var statements: [Statement] = []
        var lines: [Int] = []
        while true {
            skipSeparators()
            guard let c = peek() else {
                if let terminator { throw .incomplete("expected '\(terminator)'") }
                break
            }
            if c == terminator { break }
            lines.append(line(at: pos))
            statements.append(try parseStatement())
            skipSpaces()
            guard let next = peek(), next != terminator else { continue }
            guard next == ";" || next == "\n" else { throw unexpected(next) }
        }
        return Program(statements: statements, lines: lines)
    }

    /// The 1-based line `index` is on.
    private func line(at index: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= index { low = middle } else { high = middle }
        }
        return low + 1
    }

    private mutating func parseStatement() throws(SyntaxError) -> Statement {
        switch identifier() {
        case "let", "var":
            return try parseDeclaration()
        case "func":
            return .function(try parseFunction())
        case "return":
            guard functionDepth > 0 else { throw SyntaxError("'return' outside a function") }
            keyword("return")
            skipSpaces()
            guard let c = peek(), c != ";" && c != "\n" && c != "}" else { return .returnStatement(nil) }
            return .returnStatement(try parseExpression())
        case "do":
            return try parseDoCatch()
        case "break":
            guard loopDepth > 0 || switchDepth > 0 else { throw SyntaxError("'break' outside a loop or switch") }
            keyword("break")
            return .breakStatement
        case "continue":
            guard loopDepth > 0 else { throw SyntaxError("'continue' outside a loop") }
            keyword("continue")
            return .continueStatement
        case "enum":
            return .enumDecl(try parseEnum())
        case "import":
            return try parseImport()
        case "struct":
            return .structDecl(try parseStruct())
        case "defer":
            keyword("defer")
            skipSpaces()
            // Nothing leaves a `defer`: it can't return, break or continue.
            let saved = (functionDepth, loopDepth, switchDepth)
            (functionDepth, loopDepth, switchDepth) = (0, 0, 0)
            defer { (functionDepth, loopDepth, switchDepth) = saved }
            return .deferBlock(try parseBlock())
        case "extension" where prelude:
            return try parseExtension()
        case "fallthrough":
            guard switchDepth > 0 else { throw SyntaxError("'fallthrough' outside a switch") }
            keyword("fallthrough")
            return .fallthroughStatement
        default:
            break
        }

        if identifier() == "env", let assignment = try parseEnvironmentAssignment() {
            return assignment
        }

        if let name = identifier(), kind(of: name) == .variable || kind(of: name) == .member,
           let assignment = try parseAssignment(name) {
            return .assign(assignment)
        }

        return .chain(try parseChain())
    }

    /// `name = v`, `name.a[i] += v`, …, or nil (having looked ahead) if the
    /// statement isn't an assignment. In a struct's body, a member's name
    /// assigns through `self`.
    private mutating func parseAssignment(_ name: String) throws(SyntaxError) -> Assignment? {
        let start = (pos, spans.count)
        mark(.variable, from: pos, to: pos + name.count)
        pos += name.count
        var assignment = Assignment(root: name, value: .literal(.nothing))
        if kind(of: name) == .member {
            assignment.root = "self"
            assignment.path = [.member(name)]
        }
        use(assignment.root)
        while true {
            if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
                pos += 1
                let member = identifier()!
                pos += member.count
                assignment.path.append(.member(member))
            } else if peek() == "[" {
                pos += 1
                bracketDepth += 1
                skipSpaces()
                let index = try parseExpression()
                skipSpaces()
                bracketDepth -= 1
                guard consume("]") else { throw expected("']'") }
                assignment.path.append(.index(index))
            } else {
                break
            }
        }
        skipSpaces()
        let compound: [(String, BinaryOperator)] = [("+=", .add), ("-=", .subtract), ("*=", .multiply), ("/=", .divide)]
        if let (text, op) = compound.first(where: { matches($0.0) }) {
            mark(.punctuation, from: pos, to: pos + text.count)
            pos += text.count
            assignment.op = op
        } else if peek() == "=" && peek(1) != "=" {
            pos += 1
        } else {
            rewind(to: start)
            return nil
        }
        assignment.value = try parseExpression()
        return assignment
    }

    private func matches(_ text: String) -> Bool {
        text.enumerated().allSatisfy { peek($0.offset) == $0.element }
    }

    /// `env.NAME = value` or `env[name] = value`, or nil (having looked
    /// ahead) if this is some other statement starting with `env`.
    private mutating func parseEnvironmentAssignment() throws(SyntaxError) -> Statement? {
        let start = (pos, spans.count)
        mark(.variable, from: pos, to: pos + 3)
        pos += 3
        let name: Expr
        if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
            pos += 1
            let key = identifier()!
            pos += key.count
            name = .literal(.string(key))
        } else if consume("[") {
            bracketDepth += 1
            skipSpaces()
            name = try parseExpression()
            skipSpaces()
            bracketDepth -= 1
            guard consume("]") else { throw expected("']'") }
        } else {
            rewind(to: start)
            return nil
        }
        skipSpaces()
        guard peek() == "=" && peek(1) != "=" else {
            rewind(to: start)
            return nil
        }
        pos += 1
        return .setEnvironment(name: name, value: try parseExpression())
    }

    /// `do { … }`, optionally `catch { … }` or `catch let name { … }`.
    private mutating func parseDoCatch() throws(SyntaxError) -> Statement {
        keyword("do")
        skipSpaces()
        let body = try parseBlock()
        let afterBody = (pos, spans.count)
        skipSpaces(newlines: true)
        guard identifier() == "catch" else {
            rewind(to: afterBody)
            return .doCatch(body: body, errorName: "error", handler: nil)
        }
        keyword("catch")
        skipSpaces()
        var name = "error"
        if identifier() == "let" {
            keyword("let")
            skipSpaces()
            let nameStart = pos
            name = try parseName(after: "'let'")
            mark(.variable, from: nameStart)
            skipSpaces()
        }
        let handler = try parseBlock(declaring: [name: .variable])
        return .doCatch(body: body, errorName: name, handler: handler)
    }

    /// `enum Name[: RawType] { case a, b = raw; case c(label: Type, Type) }`
    private mutating func parseEnum() throws(SyntaxError) -> EnumDecl {
        keyword("enum")
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'enum'")
        mark(.type, from: nameStart)
        skipSpaces()
        var rawType: TypeAnnotation?
        var conformances: [String] = []
        if consume(":") {
            // A raw type first, if any, then protocols.
            skipSpaces()
            if let word = identifier(), !Parser.protocols.contains(word) {
                rawType = try parseType()
                guard [.int, .string, .double].contains(rawType!) else {
                    throw SyntaxError("an enum's raw values can be Int, String or Double, not \(rawType!)")
                }
                skipSpaces()
                if consume(",") { conformances = try parseConformances() }
            } else {
                conformances = try parseConformances()
            }
            skipSpaces()
        }
        guard consume("{") else { throw expected("'{'") }

        var cases: [EnumCaseDecl] = []
        while true {
            skipSeparators()
            skipSpaces(newlines: true)
            guard peek() != nil else { throw .incomplete("expected '}'") }
            if consume("}") { break }
            guard identifier() == "case" else { throw expected("'case'") }
            keyword("case")
            repeat {
                skipSpaces()
                let caseStart = pos
                let caseName = try parseName(after: "'case'")
                mark(.constant, from: caseStart)
                var associated: [AssociatedValue] = []
                if consume("(") {
                    bracketDepth += 1
                    defer { bracketDepth -= 1 }
                    skipSpaces()
                    while !consume(")") {
                        // `code: Int` has a label; a bare `Int` doesn't.
                        var label: String?
                        if let word = identifier() {
                            var after = pos + word.count
                            while after < chars.count && chars[after] == " " { after += 1 }
                            if after < chars.count && chars[after] == ":" {
                                label = word
                                pos = after + 1
                                skipSpaces()
                            }
                        }
                        associated.append(AssociatedValue(label: label, type: try parseType()))
                        skipSpaces()
                        if consume(",") { skipSpaces() } else if peek() != ")" { throw expected("',' or ')'") }
                    }
                }
                skipSpaces()
                var rawValue: Expr?
                if peek() == "=" && peek(1) != "=" {
                    pos += 1
                    skipSpaces()
                    rawValue = try parseUnary()
                }
                cases.append(EnumCaseDecl(name: caseName, rawValue: rawValue, associated: associated))
                skipSpaces()
            } while consume(",")
        }
        var seen: Set<String> = []
        for enumCase in cases where !seen.insert(enumCase.name).inserted {
            throw SyntaxError("duplicate case '\(enumCase.name)' in enum \(name)")
        }
        scopes[scopes.count - 1][name] = .type
        return EnumDecl(name: name, rawType: rawType, cases: cases, conformances: conformances)
    }

    /// `import Name from "path"`. The functions it brings aren't known until
    /// it runs; the module's name is, for `Tools.greet(…)`.
    private mutating func parseImport() throws(SyntaxError) -> Statement {
        keyword("import")
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'import'")
        mark(.type, from: nameStart)
        skipSpaces()
        guard identifier() == "from" else {
            throw SyntaxError("import needs where the package is: import \(name) from \"path/to/\(name)\"")
        }
        keyword("from")
        skipSpaces()
        let path = try parsePrimary()
        scopes[scopes.count - 1][name] = .variable
        sawImport = true
        return .importPlugin(name: name, path: path)
    }

    /// `struct Name { … }`: properties, methods and initializers. In their
    /// bodies, members are in scope and go through `self`, as in Swift.
    private mutating func parseStruct() throws(SyntaxError) -> StructDecl {
        keyword("struct")
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'struct'")
        mark(.type, from: nameStart)
        skipSpaces()
        var conformances: [String] = []
        if consume(":") {
            conformances = try parseConformances()
            skipSpaces()
        }
        guard consume("{") else { throw expected("'{'") }
        // Bound first, so members can use the type.
        scopes[scopes.count - 1][name] = .type
        var members: [String: NameKind] = ["self": .variable]
        for member in memberNames() { members[member] = .member }
        scopes.append(members)
        defer { scopes.removeLast() }

        var decl = StructDecl(name: name, properties: [], methods: [], initializers: [], conformances: conformances)
        while true {
            skipSeparators()
            skipSpaces(newlines: true)
            guard peek() != nil else { throw .incomplete("expected '}'") }
            if consume("}") { break }
            switch identifier() {
            case "var", "let":
                decl.properties.append(try parseProperty())
            case "func":
                decl.methods.append(try parseFunction(method: true))
            case "mutating":
                keyword("mutating")
                skipSpaces()
                guard identifier() == "func" else { throw expected("'func' after 'mutating'") }
                var method = try parseFunction(method: true)
                method.isMutating = true
                decl.methods.append(method)
            case "init":
                decl.initializers.append(try parseInitializer())
            default:
                throw SyntaxError("a struct holds properties (var, let), methods (func) and initializers (init)")
            }
        }
        var seen: Set<String> = []
        for member in decl.properties.map(\.name) + Set(decl.methods.map(\.name)) where !seen.insert(member).inserted {
            throw SyntaxError("\(name) declares '\(member)' twice")
        }
        return decl
    }

    /// `var x: Int`, `let y = 2`, or a computed `var z: Int { … }`.
    private mutating func parseProperty() throws(SyntaxError) -> PropertyDecl {
        let word = identifier()!
        keyword(word)
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'\(word)'")
        mark(.variable, from: nameStart)
        skipSpaces()
        var property = PropertyDecl(name: name, mutable: word == "var")
        if consume(":") {
            property.type = try parseType()
            skipSpaces()
        }
        if consume("{") {
            guard property.mutable else { throw SyntaxError("computed property '\(name)' must be declared with 'var'") }
            guard property.type != nil else { throw SyntaxError("computed property '\(name)' needs a type") }
            property.getter = try parseFunctionBody(parameters: [], anonymous: false).0
            property.getterNames = lastBodyNames
        } else if peek() == "=" && peek(1) != "=" {
            pos += 1
            property.defaultValue = try parseExpression()
        } else if property.type == nil {
            throw SyntaxError("property '\(name)' needs a type or a value")
        }
        return property
    }

    /// `init(x: Int) { self.x = x }`.
    private mutating func parseInitializer() throws(SyntaxError) -> FunctionDecl {
        let documentation = documentation(before: pos)
        keyword("init")
        skipSpaces()
        guard peek() == "(" else { throw expected("'(' after 'init'") }
        let parameters = try parseParameters(named: true)
        skipSpaces()
        let throwing = parseThrows()
        guard consume("{") else { throw expected("'{'") }
        let (body, _) = try parseFunctionBody(parameters: parameters, anonymous: false)
        return FunctionDecl(name: "init", parameters: parameters, returnType: nil, body: body,
                            documentation: documentation, isMutating: true, isThrowing: throwing, names: lastBodyNames)
    }

    /// The names a struct's body declares, found before parsing it so a
    /// member can use one declared further down.
    private func memberNames() -> [String] {
        var names: [String] = []
        var depth = 0
        var index = pos
        var nameFollows = false
        while index < chars.count {
            let c = chars[index]
            if c == "\"" || c == "'" {
                index += 1
                while index < chars.count && chars[index] != c {
                    if chars[index] == "\\" && c == "\"" { index += 1 }
                    index += 1
                }
            } else if c == "/" && index + 1 < chars.count && chars[index + 1] == "/" {
                while index < chars.count && chars[index] != "\n" { index += 1 }
            } else if "{([".contains(c) {
                depth += 1
            } else if "})]".contains(c) {
                if depth == 0 { break }
                depth -= 1
            } else if depth == 0, Parser.isIdentifierStart(c), index == 0 || !Parser.isIdentifierPart(chars[index - 1]) {
                var end = index
                while end < chars.count && Parser.isIdentifierPart(chars[end]) { end += 1 }
                let word = String(chars[index..<end])
                if nameFollows {
                    names.append(word)
                    nameFollows = false
                } else {
                    nameFollows = ["var", "let", "func"].contains(word)
                }
                index = end
                continue
            }
            index += 1
        }
        return names
    }

    /// The protocols a type can conform to, for now all builtin.
    static let protocols: Set = ["Equatable", "Hashable", "Comparable", "CustomStringConvertible", "Encodable", "Sequence"]

    /// `Equatable, Hashable` after a type's `:`.
    private mutating func parseConformances() throws(SyntaxError) -> [String] {
        var names: [String] = []
        repeat {
            skipSpaces()
            let start = pos
            guard let name = identifier() else { throw expected("a protocol") }
            guard Parser.protocols.contains(name) else {
                throw SyntaxError("unknown protocol '\(name)'; Swish has \(Parser.protocols.sorted().joined(separator: ", "))")
            }
            pos += name.count
            mark(.type, from: start)
            names.append(name)
            skipSpaces()
        } while consume(",")
        return names
    }

    /// `switch subject { case …: … default: … }`
    private mutating func parseSwitch() throws(SyntaxError) -> SwitchStatement {
        keyword("switch")
        skipSpaces()
        conditionDepth += 1
        let subject = try parseExpression()
        conditionDepth -= 1
        skipSpaces()
        guard consume("{") else { throw expected("'{'") }
        switchDepth += 1
        defer { switchDepth -= 1 }

        var cases: [SwitchCase] = []
        while true {
            skipSeparators()
            skipSpaces(newlines: true)
            guard peek() != nil else { throw .incomplete("expected '}'") }
            if consume("}") { break }
            if identifier() == "default" {
                keyword("default")
                skipSpaces()
                guard consume(":") else { throw expected("':' after 'default'") }
                cases.append(SwitchCase(patterns: [], body: try parseCaseBody(declaring: [:])))
                continue
            }
            guard identifier() == "case" else { throw expected("'case' or 'default'") }
            keyword("case")
            var patterns = [try parsePattern()]
            skipSpaces()
            while consume(",") {
                skipSpaces(newlines: true)
                patterns.append(try parsePattern())
                skipSpaces()
            }
            // Every pattern must bind the same names, for the body to use.
            let names = Set(Parser.names(boundBy: patterns[0]))
            guard patterns.allSatisfy({ Set(Parser.names(boundBy: $0)) == names }) else {
                throw SyntaxError("each pattern in a case must bind the same names")
            }
            var bound: [String: NameKind] = [:]
            for name in names { bound[name] = .variable }
            scopes.append(bound)
            defer { scopes.removeLast() }
            var guardExpr: Expr?
            if identifier() == "where" {
                keyword("where")
                guardExpr = try parseExpression()
                skipSpaces()
            }
            guard consume(":") else { throw expected("':' after the case") }
            cases.append(SwitchCase(patterns: patterns, guardExpr: guardExpr, body: try parseCaseBody(declaring: [:])))
        }
        return SwitchStatement(subject: subject, cases: cases)
    }

    /// The statements after `case …:`, up to the next case or the `}`.
    private mutating func parseCaseBody(declaring names: [String: NameKind]) throws(SyntaxError) -> Program {
        scopes.append(names)
        defer { scopes.removeLast() }
        var statements: [Statement] = []
        while true {
            skipSeparators()
            guard let c = peek() else { throw .incomplete("expected '}'") }
            if c == "}" || identifier() == "case" || identifier() == "default" { break }
            statements.append(try parseStatement())
            skipSpaces()
            guard let next = peek() else { continue }
            guard next == ";" || next == "\n" || next == "}" else { throw unexpected(next) }
        }
        guard !statements.isEmpty else {
            throw SyntaxError("a case needs at least one statement; write `break` to do nothing")
        }
        return Program(statements: statements)
    }

    /// A pattern: `_`, `let x`, `.name(…)`, `Type.name(…)`, or an
    /// expression to compare with. Under `let`/`var` (`binding`), names in
    /// it bind rather than refer: `let .failed(code)`.
    private mutating func parsePattern(binding: Bool = false, mutable: Bool = false) throws(SyntaxError) -> Pattern {
        skipSpaces()
        if let word = identifier(), word == "let" || word == "var" {
            keyword(word)
            return try parsePattern(binding: true, mutable: word == "var")
        }
        if identifier() == "_" {
            pos += 1
            return .wildcard
        }
        if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
            let start = pos
            pos += 1
            let name = identifier()!
            pos += name.count
            mark(.constant, from: start)
            return .enumCase(type: nil, name: name, arguments: peek() == "(" ? try parsePatternArguments(binding: binding, mutable: mutable) : nil)
        }
        if let word = identifier(), kind(of: word) == .type, peek(word.count) == "." {
            mark(.type, from: pos, to: pos + word.count)
            pos += word.count + 1
            let name = try parseName(after: "'.'")
            return .enumCase(type: word, name: name, arguments: peek() == "(" ? try parsePatternArguments(binding: binding, mutable: mutable) : nil)
        }
        if binding, let word = identifier(), !Parser.keywords.contains(word) {
            mark(.variable, from: pos, to: pos + word.count)
            pos += word.count
            return .binding(name: word, mutable: mutable)
        }
        return .expression(try parseExpression(logical: false))
    }

    private mutating func parsePatternArguments(binding: Bool, mutable: Bool) throws(SyntaxError) -> [PatternArgument] {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var arguments: [PatternArgument] = []
        skipSpaces()
        while !consume(")") {
            var label: String?
            if let word = identifier(), word != "let", word != "var", peek(word.count) == ":" {
                label = word
                pos += word.count + 1
                skipSpaces()
            }
            arguments.append(PatternArgument(label: label, pattern: try parsePattern(binding: binding, mutable: mutable)))
            skipSpaces()
            if consume(",") { skipSpaces() } else if peek() != ")" { throw expected("',' or ')'") }
        }
        return arguments
    }

    /// The names a pattern binds.
    static func names(boundBy pattern: Pattern) -> [String] {
        switch pattern {
        case .binding(let name, _): [name]
        case .enumCase(_, _, let arguments): (arguments ?? []).flatMap { names(boundBy: $0.pattern) }
        case .wildcard, .expression: []
        }
    }

    private mutating func parseDeclaration() throws(SyntaxError) -> Statement {
        let keyword = identifier()!
        self.keyword(keyword)
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'\(keyword)'")
        mark(.variable, from: nameStart)
        skipSpaces()
        var type: TypeAnnotation?
        if consume(":") {
            type = try parseType()
            skipSpaces()
        }
        guard peek() == "=" && peek(1) != "=" else { throw expected("'=' after '\(name)'") }
        pos += 1
        var value = try parseExpression()
        if let type { value = .annotated(value, type) }
        scopes[scopes.count - 1][name] = .variable
        return .declare(name: name, mutable: keyword == "var", value: value)
    }

    private mutating func parseChain() throws(SyntaxError) -> Chain {
        var chain = Chain(first: try parseUnit())
        while true {
            skipSpaces()
            let op: ChainOperator
            if consume("&&") {
                op = .and
            } else if consume("||") {
                op = .or
            } else {
                return chain
            }
            skipSpaces(newlines: true)
            chain.links.append(Link(op: op, unit: try parseUnit()))
        }
    }

    private mutating func parseUnit() throws(SyntaxError) -> Unit {
        skipSpaces()
        guard let c = peek() else { throw .incomplete("expected a command") }
        switch identifier() {
        case "if":
            return .ifStatement(try parseIf())
        case "for":
            return .forLoop(try parseFor())
        case "while":
            return .whileLoop(try parseWhile())
        case "switch":
            return .switchStatement(try parseSwitch())
        case "case", "default":
            throw SyntaxError("'\(identifier()!)' outside a switch")
        case "else":
            throw SyntaxError("'else' without a matching 'if'")
        case "in":
            throw SyntaxError("unexpected 'in'")
        case let word? where Parser.statementKeywords.contains(word):
            throw SyntaxError("'\(word)' must start a statement")
        default:
            break
        }
        // `try make` or `try! make`: a command whose failure throws.
        if identifier() == "try", let command = try parseThrowingCommand() {
            return .pipeline(command)
        }
        if startsExpression(c) {
            let start = pos
            // `a < 1 || b > 2` is one expression, with Swift's precedence, so
            // `{ $0.a < 1 || $0.b > 2 }` returns it. Only when an operand
            // isn't an expression, as in `x > 1 && echo big`, do `&&`/`||`
            // chain units by exit status instead.
            let beforeExpression = self
            var expr: Expr
            do {
                expr = try parseExpression(logical: true)
            } catch {
                self = beforeExpression
                expr = try parseExpression(logical: false)
            }
            skipSpaces()
            guard peek() == "|", peek(1) != "|" else { return .expression(expr) }
            pos += 1
            skipSpaces(newlines: true)
            return .pipeline(try parsePipeline(from: start, input: expr))
        }
        return .pipeline(try parsePipeline())
    }

    /// `try cmd …` or `try! cmd …`, or nil (having looked ahead) when what
    /// follows the `try` is an expression, as in `try? $(cmd)`.
    private mutating func parseThrowingCommand() throws(SyntaxError) -> PipelineNode? {
        let before = (pos, spans.count)
        guard let kind = try parseTry() else { return nil }
        skipSpaces()
        // `try false` is the command: a Bool literal can't throw.
        let boolCommand = kind != .optional && ["true", "false"].contains(identifier() ?? "")
            && peek(identifier()!.count).map(isWordBoundary) ?? true
        guard let next = peek(), boolCommand || !startsExpression(next) else {
            rewind(to: before)
            return nil
        }
        if kind == .optional {
            throw SyntaxError("try? needs a value; capture the command with try? $(…)")
        }
        tryDepth += 1
        defer { tryDepth -= 1 }
        var pipeline = try parsePipeline()
        pipeline.throwing = .some(kind)
        return pipeline
    }

    /// Whether a unit starting at `c` is an expression rather than a command:
    /// a literal, a bracket, `!` or `-`, a variable, or a call.
    ///
    /// A function name without `(` starts a command (`greet Rak --loud`).
    /// `$name` starts a command, as in `$EDITOR notes.txt`, but `$(…)` an
    /// expression, as in `$(cmd).count`, and so does a closure's `$0`;
    /// `^` always starts a command.
    private func startsExpression(_ c: Character) -> Bool {
        if Parser.isDigit(c) || "\"'([!-".contains(c) { return true }
        if c == "$" && peek(1) == "(" { return true }
        if c == "#" && startsWith("#filePath") { return true }
        // `.directory`, a case; `./script` is still a command.
        if c == ".", let next = peek(1), Parser.isIdentifierStart(next) { return true }
        if c == "$", let next = peek(1), Parser.isDigit(next), anonymousArity.last ?? nil != nil { return true }
        guard let word = identifier() else { return false }
        if ["true", "false", "nil", "try", "async", "await"].contains(word) { return true }
        return [.variable, .type, .member].contains(kind(of: word)) || peek(word.count) == "("
    }

    private mutating func parseIf() throws(SyntaxError) -> IfStatement {
        keyword("if")
        skipSpaces()
        let condition: IfStatement.Condition
        var bound: [String: NameKind] = [:]
        if identifier() == "case" {
            keyword("case")
            let pattern = try parsePattern()
            skipSpaces()
            guard peek() == "=" && peek(1) != "=" else { throw expected("'=' after the pattern") }
            pos += 1
            conditionDepth += 1
            defer { conditionDepth -= 1 }
            condition = .pattern(pattern, try parseExpression())
            for name in Parser.names(boundBy: pattern) { bound[name] = .variable }
        } else if let word = identifier(), word == "let" || word == "var" {
            keyword(word)
            skipSpaces()
            let nameStart = pos
            let name = try parseName(after: "'\(word)'")
            mark(.variable, from: nameStart)
            skipSpaces()
            guard peek() == "=" && peek(1) != "=" else { throw expected("'=' after '\(name)'") }
            pos += 1
            conditionDepth += 1
            defer { conditionDepth -= 1 }
            condition = .binding(name: name, mutable: word == "var", value: try parseExpression())
            bound[name] = .variable
        } else {
            condition = .chain(try parseCondition())
        }
        skipSpaces()
        let then = try parseBlock(declaring: bound)

        let afterBlock = (pos, spans.count)
        skipSpaces(newlines: true)
        guard identifier() == "else" else {
            rewind(to: afterBlock)
            return IfStatement(condition: condition, then: then)
        }
        keyword("else")
        skipSpaces()
        if identifier() == "if" {
            let elseIf = Statement.chain(Chain(first: .ifStatement(try parseIf())))
            return IfStatement(condition: condition, then: then, otherwise: Program(statements: [elseIf]))
        }
        return IfStatement(condition: condition, then: then, otherwise: try parseBlock())
    }

    private mutating func parseCondition() throws(SyntaxError) -> Chain {
        conditionDepth += 1
        defer { conditionDepth -= 1 }
        return try parseChain()
    }

    private mutating func parseFor() throws(SyntaxError) -> ForLoop {
        keyword("for")
        skipSpaces()
        let variableStart = pos
        let variable = try parseName(after: "'for'")
        mark(.variable, from: variableStart)
        skipSpaces()
        guard identifier() == "in" else { throw expected("'in'") }
        keyword("in")
        conditionDepth += 1
        let sequence = try parseExpression()
        conditionDepth -= 1
        skipSpaces()
        loopDepth += 1
        defer { loopDepth -= 1 }
        let body = try parseBlock(declaring: variable == "_" ? [:] : [variable: .variable])
        return ForLoop(variable: variable, sequence: sequence, body: body)
    }

    private mutating func parseWhile() throws(SyntaxError) -> WhileLoop {
        keyword("while")
        let condition = try parseCondition()
        skipSpaces()
        loopDepth += 1
        defer { loopDepth -= 1 }
        return WhileLoop(condition: condition, body: try parseBlock())
    }

    private mutating func parseBlock(declaring names: [String: NameKind] = [:]) throws(SyntaxError) -> Program {
        guard peek() == "{" else { throw expected("'{'") }
        pos += 1
        let savedCondition = conditionDepth
        conditionDepth = 0
        scopes.append(names)
        defer {
            scopes.removeLast()
            conditionDepth = savedCondition
        }
        let body = try parseProgram(until: "}")
        pos += 1 // parseProgram only returns at the closing brace.
        return body
    }

    // MARK: Functions and closures

    /// `method`: a struct's, which is reached through `self` rather than
    /// bound as a function.
    private mutating func parseFunction(method: Bool = false) throws(SyntaxError) -> FunctionDecl {
        let documentation = documentation(before: pos)
        keyword("func")
        skipSpaces()
        let nameStart = pos
        let name = try parseName(after: "'func'")
        mark(.command, from: nameStart)
        guard name != "_" else { throw SyntaxError("a function needs a name") }
        skipSpaces()
        var generics: [String: [String]] = [:]
        if peek() == "<" {
            guard prelude else { throw SyntaxError("generic functions of your own come later; Swish's builtins are generic for now") }
            generics = try parseGenericParameters()
        }
        typeParameters.append(Set(generics.keys))
        defer { typeParameters.removeLast() }
        guard peek() == "(" else { throw expected("'(' after '\(name)'") }
        let parameters = try parseParameters(named: true)
        skipSpaces()
        let throwing = parseThrows()
        var rethrowing = false
        if prelude && identifier() == "rethrows" {
            keyword("rethrows")
            skipSpaces()
            rethrowing = true
        }
        var returnType: TypeAnnotation?
        if consume("->") {
            returnType = try parseType()
            skipSpaces()
        }
        if prelude && identifier() == "where" {
            // `where Element: Comparable`
            keyword("where")
            repeat {
                skipSpaces()
                let parameter = try parseName(after: "'where'")
                skipSpaces()
                guard consume(":") else { throw expected("':' in a where clause") }
                generics[parameter, default: []] += try parseConformances()
                skipSpaces()
            } while consume(",")
        }
        // In the prelude, a builtin's body is in Swift.
        if prelude && peek() != "{" {
            return FunctionDecl(
                name: name, parameters: parameters, returnType: returnType, body: Program(statements: []),
                documentation: documentation, isThrowing: throwing, isRethrowing: rethrowing, generics: generics
            )
        }
        guard consume("{") else { throw expected("'{'") }
        // Bound before the body is parsed, so the function can call itself.
        if !method { scopes[scopes.count - 1][name] = .function }
        let (body, _) = try parseFunctionBody(parameters: parameters, anonymous: false)
        return FunctionDecl(
            name: name, parameters: parameters, returnType: returnType, body: body, documentation: documentation,
            isThrowing: throwing, names: lastBodyNames
        )
    }

    /// `<T, V: Comparable>`: type parameters and their constraints.
    private mutating func parseGenericParameters() throws(SyntaxError) -> [String: [String]] {
        pos += 1
        var generics: [String: [String]] = [:]
        repeat {
            skipSpaces()
            let start = pos
            let name = try parseName(after: "'<'")
            mark(.type, from: start)
            skipSpaces()
            generics[name] = consume(":") ? try parseConformances() : []
            skipSpaces()
        } while consume(",")
        guard consume(">") else { throw expected("'>'") }
        skipSpaces()
        return generics
    }

    /// `extension Sequence { … }`: methods every sequence has, with its
    /// items' type as `Element`.
    private mutating func parseExtension() throws(SyntaxError) -> Statement {
        keyword("extension")
        skipSpaces()
        let name = try parseName(after: "'extension'")
        guard name == "Sequence" else { throw SyntaxError("only Sequence can be extended, for now") }
        skipSpaces()
        guard consume("{") else { throw expected("'{'") }
        typeParameters.append(["Element"])
        defer { typeParameters.removeLast() }
        var methods: [FunctionDecl] = []
        while true {
            skipSeparators()
            skipSpaces(newlines: true)
            guard peek() != nil else { throw .incomplete("expected '}'") }
            if consume("}") { break }
            guard identifier() == "func" else { throw expected("'func'") }
            var method = try parseFunction(method: true)
            method.generics["Element", default: []] += []
            methods.append(method)
        }
        return .extensionDecl(name: name, methods: methods)
    }

    /// `throws` after a signature's parameters.
    private mutating func parseThrows() -> Bool {
        guard identifier() == "throws" else { return false }
        keyword("throws")
        skipSpaces()
        return true
    }

    /// The `///` comment lines directly above the line starting at `index`.
    private func documentation(before index: Int) -> Documentation? {
        var lineStart = index
        while lineStart > 0 && (chars[lineStart - 1] == " " || chars[lineStart - 1] == "\t") { lineStart -= 1 }
        guard lineStart > 0 && chars[lineStart - 1] == "\n" else { return nil }

        var lines: [String] = []
        var end = lineStart - 1 // The newline ending the line above.
        while end >= 0 {
            var start = end
            while start > 0 && chars[start - 1] != "\n" { start -= 1 }
            let line = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("///") else { break }
            var text = line.dropFirst(3)
            if text.first == " " { text = text.dropFirst() }
            lines.insert(String(text), at: 0)
            end = start - 1
        }
        guard !lines.isEmpty else { return nil }

        var summary: [String] = []
        var parameters: [String: String] = [:]
        for line in lines {
            if line.hasPrefix("- Parameter "), let colon = line.firstIndex(of: ":") {
                let name = line[line.index(line.startIndex, offsetBy: 12)..<colon].trimmingCharacters(in: .whitespaces)
                parameters[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                summary.append(line)
            }
        }
        return Documentation(
            summary: summary.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            parameters: parameters
        )
    }

    /// A closure, positioned after its opening brace: `{ x, y in … }`,
    /// `{ (x: Int) -> Int in … }`, or `{ $0 * 2 }`.
    private mutating func parseClosure() throws(SyntaxError) -> ClosureLiteral {
        var named: (parameters: [Parameter], returnType: TypeAnnotation?)?
        let beforeHead = self
        do {
            named = try parseClosureHead()
        } catch {
            self = beforeHead
        }
        let (body, arity) = try parseFunctionBody(parameters: named?.parameters ?? [], anonymous: named == nil)
        let parameters = named?.parameters ?? (0..<arity).map { Parameter(label: nil, name: "$\($0)") }
        return ClosureLiteral(parameters: parameters, returnType: named?.returnType, body: body, names: lastBodyNames)
    }

    private mutating func parseClosureHead() throws(SyntaxError) -> ([Parameter], TypeAnnotation?) {
        skipSpaces(newlines: true)
        var parameters: [Parameter] = []
        if peek() == "(" {
            parameters = try parseParameters(named: false)
        } else {
            while true {
                parameters.append(Parameter(label: nil, name: try parseName(after: "'{'")))
                skipSpaces()
                guard consume(",") else { break }
                skipSpaces()
            }
            try validate(parameters)
        }
        skipSpaces()
        var returnType: TypeAnnotation?
        if consume("->") {
            returnType = try parseType()
            skipSpaces()
        }
        guard identifier() == "in" else { throw expected("'in'") }
        keyword("in")
        return (parameters, returnType)
    }

    /// Statements up to the closing brace, whose opening brace is already
    /// consumed, in a new function scope. Returns the `$n` arity for
    /// anonymous closures.
    private mutating func parseFunctionBody(
        parameters: [Parameter], anonymous: Bool
    ) throws(SyntaxError) -> (Program, Int) {
        let saved = (loopDepth, bracketDepth, conditionDepth, tryDepth, switchDepth)
        loopDepth = 0
        bracketDepth = 0
        conditionDepth = 0
        tryDepth = 0
        switchDepth = 0
        functionDepth += 1
        var names: [String: NameKind] = [:]
        for parameter in parameters where parameter.name != "_" {
            names[parameter.name] = .variable
        }
        scopes.append(names)
        anonymousArity.append(anonymous ? 0 : nil)
        defer {
            (loopDepth, bracketDepth, conditionDepth, tryDepth, switchDepth) = saved
            functionDepth -= 1
            scopes.removeLast()
            anonymousArity.removeLast()
        }
        namesUsed.append([])
        let body: Program
        do {
            body = try parseProgram(until: "}")
        } catch {
            namesUsed.removeLast()
            throw error
        }
        // What an inner body mentions, the outer one must keep too.
        let mentioned = namesUsed.removeLast()
        if !namesUsed.isEmpty { namesUsed[namesUsed.count - 1].formUnion(mentioned) }
        lastBodyNames = NamesUsed(names: mentioned)
        pos += 1
        return (body, anonymousArity.last! ?? 0)
    }

    /// `(label name: Type = default, …)` for functions (`named`), or
    /// `(name: Type, …)` for closures, where types are optional.
    private mutating func parseParameters(named: Bool) throws(SyntaxError) -> [Parameter] {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var parameters: [Parameter] = []
        skipSpaces()
        if !consume(")") {
            while true {
                parameters.append(try parseParameter(named: named))
                skipSpaces()
                if consume(")") { break }
                guard consume(",") else { throw expected("',' or ')'") }
                skipSpaces()
            }
        }
        try validate(parameters)
        return parameters
    }

    private mutating func parseParameter(named: Bool) throws(SyntaxError) -> Parameter {
        var isInput = false
        var shortFlag: Character?
        while named && peek() == "@" {
            let attributeStart = pos
            pos += 1
            guard let attribute = identifier() else { throw expected("an attribute name after '@'") }
            pos += attribute.count
            mark(.keyword, from: attributeStart)
            switch attribute {
            case "input":
                isInput = true
            case "flag":
                skipSpaces()
                guard consume("(") else { throw expected("'(' after '@flag'") }
                skipSpaces()
                guard peek() == "\"", let letter = peek(1), letter.isLetter || Parser.isDigit(letter), peek(2) == "\"" else {
                    throw SyntaxError("@flag needs a single letter or digit, like @flag(\"n\")")
                }
                mark(.string, from: pos, to: pos + 3)
                pos += 3
                skipSpaces()
                guard consume(")") else { throw expected("')'") }
                shortFlag = letter
            default:
                throw SyntaxError("unknown attribute '@\(attribute)'")
            }
            skipSpaces()
        }

        let first = try parseName(after: "'('")
        skipSpaces()
        var parameter = Parameter(label: first == "_" ? nil : first, name: first, isInput: isInput, shortFlag: shortFlag)
        if named {
            if let second = identifier() {
                pos += second.count
                skipSpaces()
                guard !Parser.keywords.contains(second) else { throw SyntaxError("'\(second)' is a keyword") }
                parameter.name = second
            } else if first == "_" {
                throw expected("a parameter name after '_'")
            }
        } else {
            parameter.label = nil
        }

        if consume(":") {
            parameter.type = try parseType()
            parameter.variadic = consume("...")
            skipSpaces()
        } else if named {
            throw expected("':' and a type for '\(parameter.name)'")
        }

        if named && peek() == "=" && peek(1) != "=" {
            pos += 1
            parameter.defaultValue = try parseExpression()
        }
        return parameter
    }

    private func validate(_ parameters: [Parameter]) throws(SyntaxError) {
        var seen: Set<String> = []
        var shortFlags: Set<Character> = []
        if parameters.filter(\.isInput).count > 1 {
            throw SyntaxError("only one parameter can be @input")
        }
        for (index, parameter) in parameters.enumerated() {
            if parameter.isInput && parameter.variadic {
                throw SyntaxError("an @input parameter can't be variadic; use a list type for the whole stream")
            }
            if let flag = parameter.shortFlag {
                guard parameter.label != nil else { throw SyntaxError("@flag needs a labeled parameter") }
                guard shortFlags.insert(flag).inserted else { throw SyntaxError("duplicate short flag -\(flag)") }
            }
            if parameter.name != "_" && !seen.insert(parameter.name).inserted {
                throw SyntaxError("duplicate parameter '\(parameter.name)'")
            }
            // As in Swift, what follows a variadic must have a label, so it's
            // clear where the variadic ends.
            if parameter.variadic && index + 1 < parameters.count && parameters[index + 1].label == nil {
                throw SyntaxError("the parameter after a variadic needs a label")
            }
            if parameter.variadic && parameter.defaultValue != nil {
                throw SyntaxError("a variadic parameter can't have a default value")
            }
        }
    }

    private mutating func parseType() throws(SyntaxError) -> TypeAnnotation {
        let type = try parseNonOptionalType()
        return consume("?") ? .optional(type) : type
    }

    private mutating func parseNonOptionalType() throws(SyntaxError) -> TypeAnnotation {
        skipSpaces()
        if consume("[") {
            let element = try parseType()
            skipSpaces()
            if consume(":") {
                let value = try parseType()
                skipSpaces()
                guard consume("]") else { throw expected("']'") }
                return .dictionary(element, value)
            }
            guard consume("]") else { throw expected("']'") }
            return .list(element)
        }
        if consume("(") {
            // A tuple, `(name: String, Int)`; or a function's parameters,
            // `(Int) -> Bool`; or just parentheses, `(Int)`.
            var elements: [TypeAnnotation.TupleElement] = []
            skipSpaces()
            if !consume(")") {
                while true {
                    skipSpaces()
                    var label: String?
                    if let word = identifier(), peek(word.count) == ":" {
                        label = word
                        pos += word.count + 1
                    }
                    elements.append(.init(label: label, type: try parseType()))
                    skipSpaces()
                    if consume(")") { break }
                    guard consume(",") else { throw expected("',' or ')'") }
                }
            }
            let afterParentheses = (pos, spans.count)
            skipSpaces()
            var throwing = false
            if identifier() == "throws" {
                keyword("throws")
                throwing = true
                skipSpaces()
            }
            if consume("->") {
                guard elements.allSatisfy({ $0.label == nil }) else {
                    throw SyntaxError("a function type's parameters have no labels")
                }
                return .functionType(elements.map(\.type), try parseType(), throws: throwing)
            }
            if throwing { throw expected("'->' after 'throws'") }
            rewind(to: afterParentheses)
            if elements.isEmpty { return .void }
            if elements.count == 1 && elements[0].label == nil { return elements[0].type }
            return .tuple(elements)
        }
        guard let name = identifier() else { throw expected("a type") }
        mark(.type, from: pos, to: pos + name.count)
        pos += name.count
        if typeParameters.contains(where: { $0.contains(name) }) { return .parameter(name) }
        if name == "KeyPath" && consume("<") {
            let root = try parseType()
            skipSpaces()
            guard consume(",") else { throw expected("',' in KeyPath<Root, Value>") }
            let value = try parseType()
            skipSpaces()
            guard consume(">") else { throw expected("'>'") }
            return .keyPath(root, value)
        }
        if peek() == "<", let generic = Bridge.types[name], !generic.genericParameters.isEmpty {
            // `Set<Int>`, `Array<Int>`, `Dictionary<String, Int>`.
            pos += 1
            var arguments: [TypeAnnotation] = []
            repeat {
                arguments.append(try parseType())
                skipSpaces()
            } while consume(",")
            guard consume(">") else { throw expected("'>'") }
            guard arguments.count == generic.genericParameters.count else {
                throw SyntaxError("\(name) takes \(generic.genericParameters.count) generic argument\(generic.genericParameters.count == 1 ? "" : "s")")
            }
            switch name {
            case "Array": return .list(arguments[0])
            case "Optional": return .optional(arguments[0])
            case "Dictionary": return .dictionary(arguments[0], arguments[1])
            default: return .generic(name, arguments)
            }
        }
        let type: TypeAnnotation
        switch name {
        case "Int": type = .int
        case "Double": type = .double
        case "String": type = .string
        case "Bool": type = .bool
        case "Record": type = .record
        case "FileSize": type = .filesize
        case "Date": type = .date
        case "Output": type = .output
        case "Any", "Value": type = .any
        case "Void": type = .void
        default:
            guard kind(of: name) == .type else { throw SyntaxError("unknown type '\(name)'") }
            type = .named(name)
        }
        return type
    }

    /// An identifier that isn't a keyword; `_` is allowed.
    private mutating func parseName(after context: String) throws(SyntaxError) -> String {
        guard let name = identifier() else { throw expected("a name after \(context)") }
        guard !Parser.keywords.contains(name) else { throw SyntaxError("'\(name)' is a keyword") }
        pos += name.count
        return name
    }

    // MARK: Command mode

    private mutating func parsePipeline(from start: Int? = nil, input: Expr? = nil) throws(SyntaxError) -> PipelineNode {
        let start = start ?? pos
        var commands = [try parseCommand()]
        var end = pos
        while true {
            skipSpaces()
            guard peek() == "|", peek(1) != "|" else { break }
            pos += 1
            skipSpaces(newlines: true)
            commands.append(try parseCommand())
            end = pos
        }
        let source = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return PipelineNode(commands: commands, source: source, input: input)
    }

    private mutating func parseCommand() throws(SyntaxError) -> CommandNode {
        skipSpaces()
        let nameStart = pos
        // `foreign ls` (or `^ls`): the program, never a function or builtin.
        var external = consume("^")
        // Where the command name's highlight starts: at a `^` touching it.
        let caretStart: Int? = external ? nameStart : nil
        if !external, identifier() == "foreign", peek(7) == " " || peek(7) == "\t" {
            keyword("foreign")
            skipSpaces()
            external = true
        }
        var words: [Word] = []
        var redirects: [Redirect] = []
        var environment: [EnvironmentAssignment] = []
        var call: [Argument]?
        while true {
            skipSpaces()
            guard let c = peek(), !endsCommand(c) else { break }
            if let redirect = try parseRedirect() {
                redirects += redirect
                continue
            }
            if c == "{" && peek(1) != "}" {
                pos += 1
                words.append(.closure(try parseClosure()))
                continue
            }
            // `sorted(by: "size")`: a name touching its arguments is a call,
            // as in Swift; a trailing closure may follow.
            if c == "(", words.count == 1, call == nil, !external, pos > 0, Parser.isIdentifierPart(chars[pos - 1]) {
                call = try parseArguments()
                skipSpaces()
                if peek() == "{" {
                    pos += 1
                    call!.append(Argument(label: nil, value: .closure(try parseClosure())))
                }
                continue
            }
            if c == "(" {
                throw SyntaxError("unexpected '(' in a command; quote it, or use \\(…) to interpolate an expression")
            }
            if call != nil {
                throw SyntaxError("a command written as a call takes all its arguments in the parentheses")
            }
            if c == "&" {
                throw SyntaxError("'&' isn't Swish; background jobs will be `async command`")
            }
            // `NAME=value` before the command sets it for the command.
            if words.isEmpty, let name = identifier(), peek(name.count) == "=", peek(name.count + 1) != "=" {
                mark(.variable, from: pos, to: pos + name.count)
                pos += name.count + 1
                let value = peek().map(isWordBoundary) ?? true ? [.literal("")] : try parseWord()
                environment.append(EnvironmentAssignment(name: name, value: value))
                continue
            }
            let wordStart = pos
            let word = try parseWord()
            if words.isEmpty {
                // A command's name may be a function the body calls.
                if word.count == 1, case .literal(let name) = word[0] { use(name) }
                mark(.command, from: redirects.isEmpty && environment.isEmpty ? caretStart ?? wordStart : wordStart)
            } else if chars[wordStart] == "-" {
                mark(.flag, from: wordStart)
            }
            words.append(.text(word))
        }
        guard !words.isEmpty else {
            if let assignment = environment.first {
                throw SyntaxError("\(assignment.name)=… sets a variable for one command; use env.\(assignment.name) = … to set it for the session")
            }
            if let c = peek() { throw unexpected(c) }
            throw .incomplete("expected a command")
        }
        return CommandNode(words: words, external: external, redirects: redirects, environment: environment, call: call)
    }

    /// A redirect at the current position, or nil if there isn't one:
    /// `> file`, `>> file` and `< file` for standard output and input;
    /// `e>` and `e>>` for standard error; `o+e>` and `o+e>>` for both; `e>o`
    /// sends standard error wherever standard output goes, and `o>e` the
    /// other way. POSIX forms like `2>&1` are an error naming the new one.
    private mutating func parseRedirect() throws(SyntaxError) -> [Redirect]? {
        let start = pos
        try rejectPosixRedirect()

        func touchesBoundary(after count: Int) -> Bool {
            peek(count).map(isWordBoundary) ?? true
        }
        if startsWith("e>o") && touchesBoundary(after: 3) {
            pos += 3
            mark(.punctuation, from: start)
            return [Redirect(fd: 2, target: .descriptor(1))]
        }
        if startsWith("o>e") && touchesBoundary(after: 3) {
            pos += 3
            mark(.punctuation, from: start)
            return [Redirect(fd: 1, target: .descriptor(2))]
        }

        let fds: [Int32]
        if consume("o+e>") {
            fds = [1, 2]
        } else if consume("e>") {
            fds = [2]
        } else if consume(">") {
            fds = [1]
        } else if consume("<") {
            fds = [0]
        } else {
            return nil
        }
        let append = fds != [0] && consume(">")
        mark(.punctuation, from: start)

        skipSpaces()
        guard let c = peek(), !isWordBoundary(c) else {
            if peek() == nil { throw .incomplete("expected a file to redirect to") }
            throw expected("a file to redirect to")
        }
        let file = try parseWord()
        let mode: Redirect.Mode = fds == [0] ? .read : append ? .append : .write
        if fds == [1, 2] {
            return [Redirect(fd: 1, target: .file(file, mode)), Redirect(fd: 2, target: .descriptor(1))]
        }
        return [Redirect(fd: fds[0], target: .file(file, mode))]
    }

    /// POSIX redirects, which would otherwise read as a word and a redirect,
    /// with the Swish spelling in the error.
    private func rejectPosixRedirect() throws(SyntaxError) {
        var digits = ""
        while let c = peek(digits.count), Parser.isDigit(c) { digits.append(c) }
        let rest = String(chars[(pos + digits.count)...].prefix(4))
        let swish: String?
        switch (digits, rest) {
        case (_, _) where startsWith("&>>"): swish = "o+e>>"
        case (_, _) where startsWith("&>"): swish = "o+e>"
        case ("", _) where rest.hasPrefix(">&2"): swish = "o>e"
        case ("2", _) where rest.hasPrefix(">&1"): swish = "e>o"
        case ("2", _) where rest.hasPrefix(">>"): swish = "e>>"
        case ("2", _) where rest.hasPrefix(">"): swish = "e>"
        case ("1", _) where rest.hasPrefix(">"): swish = rest.hasPrefix(">>") ? ">>" : ">"
        case ("0", _) where rest.hasPrefix("<"): swish = "<"
        case let (number, _) where !number.isEmpty && (rest.hasPrefix(">") || rest.hasPrefix("<")):
            throw SyntaxError("numbered descriptors like \(number)\(rest.prefix(1)) aren't part of Swish; redirect with >, e>, e>o, o>e or o+e>")
        default: swish = nil
        }
        if let swish {
            throw SyntaxError("that's a POSIX redirect; in Swish it's \(swish)")
        }
    }

    private func endsCommand(_ c: Character) -> Bool {
        switch c {
        case "|", ";", "\n", ")", "}": true
        case "&": peek(1) == "&"
        case "{": peek(1) != "}" && conditionDepth > 0
        default: false
        }
    }

    private func isWordBoundary(_ c: Character) -> Bool {
        c == " " || c == "\t" || c == "\n" || "|;&(){}<>".contains(c)
    }

    private mutating func parseWord() throws(SyntaxError) -> [StringPart] {
        var parts: [StringPart] = []
        var literal = ""
        // Whether the unquoted text in `literal` has a wildcard in it.
        var wildcard = false
        func flush() {
            if !literal.isEmpty { parts.append(wildcard ? .glob(literal) : .literal(literal)) }
            literal = ""
            wildcard = false
        }

        if peek() == "~", peek(1).map({ $0 == "/" || isWordBoundary($0) }) ?? true {
            parts.append(.expression(.dollar("HOME")))
            pos += 1
        }

        while let c = peek() {
            // `{}` is a word (as in `find -exec … {} \;`), not a block.
            if c == "{" && peek(1) == "}" {
                literal += "{}"
                pos += 2
                continue
            }
            if isWordBoundary(c) { break }
            switch c {
            case "'":
                flush()
                parts.append(.literal(try parseRawString()))
            case "\"":
                flush()
                parts += try parseInterpolatedString(dollar: true)
            case "\\":
                guard let next = peek(1) else { throw .incomplete("expected a character after '\\'") }
                if next == "(" {
                    flush()
                    parts.append(.expression(try parseInterpolation()))
                } else if next == "\n" {
                    pos += 2
                } else if "*[".contains(next) {
                    // An escaped wildcard is literal, even next to real ones.
                    flush()
                    parts.append(.literal(String(next)))
                    pos += 2
                } else {
                    literal.append(next)
                    pos += 2
                }
            case "$":
                if let expr = try parseDollar() {
                    flush()
                    parts.append(.expression(expr))
                } else {
                    literal.append(c)
                    pos += 1
                }
            default:
                if "*[".contains(c) { wildcard = true }
                literal.append(c)
                pos += 1
            }
        }
        flush()
        return parts
    }

    // MARK: Strings and interpolation

    private mutating func parseRawString() throws(SyntaxError) -> String {
        guard let end = chars[(pos + 1)...].firstIndex(of: "'") else {
            mark(.string, from: pos, to: chars.count)
            throw .incomplete("unterminated string")
        }
        let text = String(chars[(pos + 1)..<end])
        mark(.string, from: pos, to: end + 1)
        pos = end + 1
        return text
    }

    /// A double-quoted string: Swift escapes and `\(…)`, and in commands
    /// (`dollar`) also `$name` and `$(…)`. In expressions it's pure Swift,
    /// so `"costs $5"` and `"$HOME"` are literal there.
    private mutating func parseInterpolatedString(dollar: Bool) throws(SyntaxError) -> [StringPart] {
        let start = pos
        pos += 1
        var parts: [StringPart] = []
        var literal = ""
        while true {
            guard let c = peek() else {
                mark(.string, from: start, to: chars.count)
                throw .incomplete("unterminated string")
            }
            switch c {
            case "\"":
                pos += 1
                mark(.string, from: start)
                if !literal.isEmpty || parts.isEmpty { parts.append(.literal(literal)) }
                return parts
            case "\\":
                guard let next = peek(1) else {
                    mark(.string, from: start, to: chars.count)
                    throw .incomplete("unterminated string")
                }
                if next == "(" {
                    if !literal.isEmpty { parts.append(.literal(literal)) }
                    literal = ""
                    parts.append(.expression(try parseInterpolation()))
                    continue
                }
                pos += 2
                switch next {
                case "n": literal.append("\n")
                case "t": literal.append("\t")
                case "r": literal.append("\r")
                case "0": literal.append("\0")
                case "\\", "\"", "'", "$": literal.append(next)
                case "u": literal.append(try parseUnicodeEscape())
                default: throw SyntaxError("invalid escape '\\\(next)' in string")
                }
            case "$" where dollar:
                if let expr = try parseDollar() {
                    if !literal.isEmpty { parts.append(.literal(literal)) }
                    literal = ""
                    parts.append(.expression(expr))
                } else {
                    literal.append(c)
                    pos += 1
                }
            default:
                literal.append(c)
                pos += 1
            }
        }
    }

    /// `\u{1F600}`, positioned after the `u`.
    private mutating func parseUnicodeEscape() throws(SyntaxError) -> Character {
        guard consume("{") else { throw SyntaxError("expected '{' after '\\u'") }
        var hex = ""
        while let c = peek(), c.isHexDigit {
            hex.append(c)
            pos += 1
        }
        guard consume("}"), let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) else {
            throw SyntaxError("invalid unicode escape '\\u{\(hex)'")
        }
        return Character(scalar)
    }

    /// `\(expression)`, positioned at the backslash.
    private mutating func parseInterpolation() throws(SyntaxError) -> Expr {
        mark(.punctuation, from: pos, to: pos + 2)
        pos += 2
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        skipSpaces()
        let expr = try parseExpression()
        skipSpaces()
        guard consume(")") else { throw expected("')'") }
        mark(.punctuation, from: pos - 1)
        return expr
    }

    /// `$(…)`, `$?`, `$name`, or `$0` in a closure, positioned at the dollar
    /// sign; nil if the dollar is just a character.
    private mutating func parseDollar() throws(SyntaxError) -> Expr? {
        switch peek(1) {
        case "(":
            mark(.punctuation, from: pos, to: pos + 2)
            pos += 2
            // A substitution is its own little program: newlines separate
            // statements again, and it can't break or return out of its host.
            // Whether this one throws is decided out here; the commands
            // inside are a program of their own.
            let throwing = tryDepth > 0
            let saved = (bracketDepth, loopDepth, functionDepth, conditionDepth, tryDepth, switchDepth)
            (bracketDepth, loopDepth, functionDepth, conditionDepth, tryDepth, switchDepth) = (0, 0, 0, 0, 0, 0)
            scopes.append([:])
            defer {
                (bracketDepth, loopDepth, functionDepth, conditionDepth, tryDepth, switchDepth) = saved
                scopes.removeLast()
            }
            let program = try parseProgram(until: ")")
            mark(.punctuation, from: pos, to: pos + 1)
            pos += 1
            return .substitution(program, throwing: throwing)
        case "?":
            throw SyntaxError("$? isn't Swish: a captured command has its own .status, and `try` makes a failure throw")
        case let c? where Parser.isDigit(c):
            // Only special in a closure without named parameters; elsewhere,
            // as in "costs $5", it's just text.
            guard let arity = anonymousArity.last ?? nil else { return nil }
            let start = pos
            pos += 1
            guard let index = Int(readDigits()) else { throw SyntaxError("closure parameter number is too large") }
            mark(.variable, from: start)
            anonymousArity[anonymousArity.count - 1] = max(arity, index + 1)
            return .variable("$\(index)")
        case let c? where Parser.isIdentifierStart(c):
            let start = pos
            pos += 1
            let name = identifier()!
            pos += name.count
            mark(.variable, from: start)
            use(name)
            return .dollar(name)
        default:
            return nil
        }
    }

    // MARK: Expression mode

    /// `logical` is false for an expression that is a whole unit, so that
    /// `&&` and `||` are left to join it with commands in a chain.
    /// `try`, `try?` and `try!` cover everything to their right, as in
    /// Swift: `(try? $(cmd)) ?? "default"` needs its parentheses.
    private mutating func parseExpression(logical: Bool = true) throws(SyntaxError) -> Expr {
        skipSpaces()
        if let kind = try parseTry() {
            tryDepth += 1
            defer { tryDepth -= 1 }
            let operand = try parseExpression(logical: logical)
            return .attempt(operand, kind ?? .plain)
        }
        return try parseBinary(level: logical ? 0 : Parser.comparisonLevel)
    }

    /// `try` (.some(nil)), `try?` or `try!` at the current position; nil if none.
    private mutating func parseTry() throws(SyntaxError) -> TryKind?? {
        guard identifier() == "try" else { return nil }
        let start = pos
        pos += "try".count
        var kind: TryKind?
        if consume("?") {
            kind = .optional
        } else if consume("!") {
            kind = .forced
        }
        mark(.keyword, from: start)
        return .some(kind)
    }

    private mutating func parseBinary(level: Int) throws(SyntaxError) -> Expr {
        guard level < Parser.precedence.count else { return try parseUnary() }
        var lhs = try parseOperand(level: level)
        var chained = false
        while true {
            skipSpaces()
            guard let op = Parser.precedence[level].first(where: { startsWith($0.rawValue) }) else {
                return lhs
            }
            if Parser.nonAssociativeLevels.contains(level) {
                if chained { throw SyntaxError("'\(op.rawValue)' can't be chained; use parentheses or '&&'") }
                chained = true
            }
            pos += op.rawValue.count
            skipSpaces(newlines: true)
            lhs = .binary(op, lhs, try parseOperand(level: level))
        }
    }

    /// An operand of `level`'s operators. `??`'s may be cast, as Swift's
    /// precedence has it: `x ?? y as? Int` is `x ?? (y as? Int)`.
    private mutating func parseOperand(level: Int) throws(SyntaxError) -> Expr {
        var expr = try parseBinary(level: level + 1)
        guard Parser.precedence[level] == [.coalesce] else { return expr }
        while true {
            let before = (pos, spans.count)
            skipSpaces()
            let start = pos
            let kind: CastKind
            switch identifier() {
            case "as":
                pos += 2
                kind = consume("?") ? .conditional : consume("!") ? .forced : .upcast
            case "is":
                pos += 2
                kind = .check
            default:
                rewind(to: before)
                return expr
            }
            mark(.keyword, from: start)
            skipSpaces()
            expr = .cast(expr, try parseType(), kind)
        }
    }

    private mutating func parseUnary() throws(SyntaxError) -> Expr {
        skipSpaces()
        if consume("!") { return .unary(.not, try parseUnary()) }
        if consume("-") { return .unary(.negate, try parseUnary()) }
        // After an operator, as in `x + try? f()`, it covers the rest.
        if identifier() == "try" {
            return try parseExpression()
        }
        if identifier() == "async" {
            return try parseAsync()
        }
        if identifier() == "await" {
            keyword("await")
            skipSpaces()
            // A bare `await` brings back the most recent job.
            let ends = peek().map { ";\n)}],".contains($0) } ?? true || startsWith("&&") || startsWith("||")
            return .await(ends ? nil : try parseUnary(), throwing: tryDepth > 0)
        }
        var expr = try parsePrimary()
        // Postfix operators bind only without a space: `f(x)`, `xs[0]`.
        while true {
            if peek() == "[" {
                pos += 1
                bracketDepth += 1
                skipSpaces()
                let index = try parseExpression()
                skipSpaces()
                guard consume("]") else { throw expected("']'") }
                bracketDepth -= 1
                expr = .index(expr, index)
            } else if peek() == "(" {
                var arguments = try parseArguments()
                // A trailing closure, as in `with(env: e) { … }`; not where
                // `{` starts a body, as after `if` or `for … in`.
                let beforeClosure = (pos, spans.count)
                skipSpaces()
                if peek() == "{" && conditionDepth == 0 {
                    pos += 1
                    arguments.append(Argument(label: nil, value: .closure(try parseClosure())))
                } else {
                    rewind(to: beforeClosure)
                }
                expr = .call(expr, arguments)
            } else if peek() == "!", peek(1) != "=" {
                pos += 1
                expr = .forceUnwrap(expr)
            } else if peek() == "?", peek(1) == "[" {
                pos += 2
                bracketDepth += 1
                skipSpaces()
                let index = try parseExpression()
                skipSpaces()
                guard consume("]") else { throw expected("']'") }
                bracketDepth -= 1
                expr = .optionalIndex(expr, index)
            } else if peek() == "?", peek(1) == ".", let next = peek(2), Parser.isIdentifierStart(next) {
                pos += 2
                let name = identifier()!
                pos += name.count
                expr = .optionalMember(expr, name)
            } else if peek() == ".", let next = peek(1), Parser.isDigit(next) {
                // `pair.0`: a tuple's element by position.
                pos += 1
                var digits = ""
                while let c = peek(), Parser.isDigit(c) {
                    digits.append(c)
                    pos += 1
                }
                expr = .member(expr, digits)
            } else if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
                pos += 1
                let name = identifier()!
                pos += name.count
                expr = .member(expr, name)
                // `xs.filter { … }`: a call with only a trailing closure.
                let beforeClosure = (pos, spans.count)
                skipSpaces()
                if peek() == "{" && peek(1) != "}" && conditionDepth == 0 {
                    pos += 1
                    expr = .call(expr, [Argument(label: nil, value: .closure(try parseClosure()))])
                } else {
                    rewind(to: beforeClosure)
                }
            } else {
                return expr
            }
        }
    }

    /// `async cmd …` or `async $(cmd …)`: a pipeline of programs to start in
    /// the background.
    private mutating func parseAsync() throws(SyntaxError) -> Expr {
        keyword("async")
        skipSpaces()
        if peek() == "$" && peek(1) == "(" {
            guard case .substitution(let program, _)? = try parseDollar(),
                  program.statements.count == 1, case .chain(let chain) = program.statements[0],
                  chain.links.isEmpty, case .pipeline(let pipeline) = chain.first else {
                throw SyntaxError("async $(…) runs one pipeline of commands")
            }
            return .async(.capture(pipeline))
        }
        guard let c = peek() else { throw .incomplete("expected a command after 'async'") }
        // `async false` is the command: a Bool literal can't run.
        let boolCommand = ["true", "false"].contains(identifier() ?? "") && peek(identifier()!.count).map(isWordBoundary) ?? true
        if startsExpression(c) && !boolCommand {
            throw SyntaxError("async runs a command, as in `async swift build` or `async $(curl …)`")
        }
        return .async(.command(try parsePipeline()))
    }

    private mutating func parseArguments() throws(SyntaxError) -> [Argument] {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        var arguments: [Argument] = []
        skipSpaces()
        if consume(")") { return arguments }
        while true {
            var label: String?
            if let name = identifier(), peek(name.count) == ":" {
                label = name
                pos += name.count + 1
            }
            arguments.append(Argument(label: label, value: try parseExpression()))
            skipSpaces()
            if consume(")") { return arguments }
            guard consume(",") else { throw expected("',' or ')'") }
            skipSpaces()
        }
    }

    private mutating func parsePrimary() throws(SyntaxError) -> Expr {
        skipSpaces()
        guard let c = peek() else { throw .incomplete("expected an expression") }
        if Parser.isDigit(c) { return try parseNumber() }

        switch c {
        case "\"":
            let parts = try parseInterpolatedString(dollar: false)
            if parts.count == 1, case .literal(let text) = parts[0] { return .literal(.string(text)) }
            return .string(parts)
        case "'":
            return .literal(.string(try parseRawString()))
        case "(":
            // `(x)` groups; `(a, b)` and `(name: x)` are tuples; `()` is Void.
            pos += 1
            bracketDepth += 1
            defer { bracketDepth -= 1 }
            skipSpaces()
            if consume(")") { return .tuple([]) }
            var elements: [Argument] = []
            while true {
                skipSpaces()
                var label: String?
                if let word = identifier(), peek(word.count) == ":", peek(word.count + 1) != ":" {
                    label = word
                    pos += word.count + 1
                }
                elements.append(Argument(label: label, value: try parseExpression()))
                skipSpaces()
                if consume(")") { break }
                guard consume(",") else { throw expected("',' or ')'") }
            }
            if elements.count == 1 && elements[0].label == nil { return elements[0].value }
            return .tuple(elements)
        case "[":
            return try parseList()
        case "{":
            pos += 1
            return .closure(try parseClosure())
        case "." where peek(1).map(Parser.isIdentifierStart) ?? false:
            let start = pos
            pos += 1
            let name = identifier()!
            pos += name.count
            mark(.constant, from: start)
            return .caseLiteral(name, peek() == "(" ? try parseArguments() : nil)
        case "$":
            guard let expr = try parseDollar() else { throw unexpected(c) }
            return expr
        case "#" where startsWith("#filePath"):
            mark(.keyword, from: pos, to: pos + 9)
            pos += 9
            return .filePath
        case "\\" where peek(1) == "." || peek(1).map(Parser.isIdentifierStart) ?? false:
            // `\.size.bytes`, or with its root, `\FileEntry.size`.
            let start = pos
            pos += 1
            var root: String?
            if let name = identifier() {
                root = name
                pos += name.count
            }
            var path: [String] = []
            while peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) || Parser.isDigit(next) {
                pos += 1
                var name = identifier() ?? ""
                if name.isEmpty { while let d = peek(), Parser.isDigit(d) { name.append(d); pos += 1 } } else { pos += name.count }
                path.append(name)
            }
            guard !path.isEmpty else { throw expected("a member after '\\'") }
            mark(.variable, from: start)
            return .keyPath(root: root, path: path)
        default:
            break
        }

        guard let name = identifier() else { throw unexpected(c) }
        let nameStart = pos
        pos += name.count
        switch name {
        case "true", "false", "nil": mark(.constant, from: nameStart)
        default: mark(.variable, from: nameStart)
        }
        switch name {
        case "true": return .literal(.bool(true))
        case "false": return .literal(.bool(false))
        case "nil": return .literal(.nothing)
        default: break
        }
        if Parser.keywords.contains(name) {
            throw SyntaxError("expected an expression, found '\(name)'")
        }
        guard kind(of: name) != nil || (sawImport && peek() == "(") else {
            throw SyntaxError(peek() == "(" ? "no function named '\(name)'" : "no variable named '\(name)'")
        }
        if kind(of: name) == .member {
            use("self")
            return .member(.variable("self"), name)
        }
        use(name)
        return .variable(name)
    }

    /// `[1, 2]`, or a record like `["name": "x", "size": 1.kb]` or `[:]`.
    private mutating func parseList() throws(SyntaxError) -> Expr {
        pos += 1
        bracketDepth += 1
        defer { bracketDepth -= 1 }
        skipSpaces()
        if consume(":") {
            skipSpaces()
            guard consume("]") else { throw expected("']'") }
            return .record([])
        }
        var elements: [Expr] = []
        var entries: [RecordEntry] = []
        // Decided by the first element: a colon after it makes a record.
        var isRecord: Bool?
        while peek() != "]" {
            let element = try parseExpression()
            skipSpaces()
            if isRecord == nil {
                isRecord = consume(":")
            } else if isRecord == true {
                guard consume(":") else { throw expected("':' in a record literal") }
            }
            if isRecord == true {
                entries.append(RecordEntry(key: element, value: try parseExpression()))
            } else {
                elements.append(element)
            }
            skipSpaces()
            guard consume(",") else { break }
            skipSpaces()
        }
        guard consume("]") else { throw expected("']'") }
        return isRecord == true ? .record(entries) : .list(elements)
    }

    private mutating func parseNumber() throws(SyntaxError) -> Expr {
        let start = pos
        defer { mark(.number, from: start) }
        var text = readDigits()
        var isDouble = false
        if peek() == ".", let next = peek(1), Parser.isDigit(next) {
            isDouble = true
            pos += 1
            text += "." + readDigits()
        }
        if peek() == ".", let next = peek(1), Parser.isIdentifierStart(next) {
            pos += 1
            let unit = identifier()!
            guard let multiplier = Parser.fileSizeUnits[unit] else {
                throw SyntaxError("unknown unit '\(unit)'; file sizes use b, kb, mb, gb, tb, or kib, mib, gib, tib")
            }
            pos += unit.count
            let bytes = Double(text)! * Double(multiplier)
            guard bytes.magnitude < Double(Int64.max) else { throw SyntaxError("file size \(text).\(unit) is too large") }
            return .literal(.filesize(Int64(bytes)))
        }
        if let c = peek(), Parser.isIdentifierPart(c) {
            throw SyntaxError("unexpected '\(c)' after a number (use ^ to run a command whose name starts with a digit)")
        }
        if isDouble { return .literal(.double(Double(text)!)) }
        guard let value = Int(text) else { throw SyntaxError("integer literal \(text) is too large") }
        return .literal(.int(value))
    }

    // MARK: Scanning

    /// Digits with optional `_` separators, which are dropped.
    private mutating func readDigits() -> String {
        var digits = ""
        while let c = peek(), Parser.isDigit(c) || c == "_" {
            if c != "_" { digits.append(c) }
            pos += 1
        }
        return digits
    }

    private func peek(_ offset: Int = 0) -> Character? {
        let index = pos + offset
        return index < chars.count ? chars[index] : nil
    }

    private func startsWith(_ text: String) -> Bool {
        var index = pos
        for c in text {
            guard index < chars.count, chars[index] == c else { return false }
            index += 1
        }
        return true
    }

    private mutating func consume(_ text: String) -> Bool {
        guard startsWith(text) else { return false }
        pos += text.count
        return true
    }

    /// The identifier starting at the current position, without consuming it.
    private func identifier() -> String? {
        guard let first = peek(), Parser.isIdentifierStart(first) else { return nil }
        var name = String(first)
        while let c = peek(name.count), Parser.isIdentifierPart(c) {
            name.append(c)
        }
        return name
    }

    private func kind(of name: String) -> NameKind? {
        for scope in scopes.reversed() {
            if let kind = scope[name] { return kind }
        }
        return nil
    }

    /// Skips blanks, line continuations and comments; newlines too when
    /// asked or inside brackets.
    private mutating func skipSpaces(newlines: Bool = false) {
        while let c = peek() {
            if c == " " || c == "\t" {
                pos += 1
            } else if c == "\\" && peek(1) == "\n" {
                pos += 2
            } else if c == "\n" && (newlines || bracketDepth > 0) {
                pos += 1
            } else if (c == "/" && peek(1) == "/") || (c == "#" && pos == 0 && peek(1) == "!") {
                // `//` and `///` comments, as in Swift; `#!` only as a shebang.
                let start = pos
                while let d = peek(), d != "\n" { pos += 1 }
                mark(.comment, from: start)
            } else {
                return
            }
        }
    }

    private mutating func skipSeparators() {
        while true {
            skipSpaces()
            guard peek() == ";" || peek() == "\n" else { return }
            pos += 1
        }
    }

    private func unexpected(_ c: Character) -> SyntaxError {
        SyntaxError(c == "\n" ? "unexpected newline" : "unexpected '\(c)'")
    }

    private func expected(_ what: String) -> SyntaxError {
        guard let c = peek() else { return .incomplete("expected \(what)") }
        return SyntaxError("expected \(what), found \(c == "\n" ? "newline" : "'\(c)'")")
    }

    private static func isDigit(_ c: Character) -> Bool {
        c.isASCII && c.isNumber
    }

    private static func isIdentifierStart(_ c: Character) -> Bool {
        c == "_" || c.isLetter
    }

    private static func isIdentifierPart(_ c: Character) -> Bool {
        isIdentifierStart(c) || isDigit(c)
    }
}
