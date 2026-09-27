@testable import SwishCore
import Testing

private func names(_ variables: Set<String>, functions: Set<String> = []) -> [String: NameKind] {
    var names: [String: NameKind] = [:]
    for name in variables { names[name] = .variable }
    for name in functions { names[name] = .function }
    return names
}

private func parse(_ source: String, bound: Set<String> = [], functions: Set<String> = []) throws -> Program {
    try Parser.parse(source, bound: names(bound, functions: functions))
}

/// The kind of each top-level unit: "command", "expression", "if" or "loop".
private func modes(_ source: String, bound: Set<String> = [], functions: Set<String> = []) throws -> [String] {
    try parse(source, bound: bound, functions: functions).statements.map { statement in
        guard case .chain(let chain) = statement else { return "declaration" }
        switch chain.first {
        case .pipeline: return "command"
        case .expression: return "expression"
        case .ifStatement: return "if"
        case .forLoop, .whileLoop: return "loop"
        }
    }
}

/// The parameter names of the closure in `let f = <closure>`.
private func closureParameters(_ source: String) throws -> [String] {
    guard case .declare(_, _, .closure(let closure)) = try parse(source).statements.first else {
        Issue.record("not a closure declaration: \(source)")
        return []
    }
    return closure.parameters.map(\.name)
}

private func words(_ source: String, bound: Set<String> = []) throws -> [[StringPart]] {
    guard case .chain(let chain) = try parse(source, bound: bound).statements.first,
          case .pipeline(let pipeline) = chain.first else {
        Issue.record("not a command: \(source)")
        return []
    }
    return pipeline.commands[0].words
}

private func syntaxError(_ source: String, bound: Set<String> = []) -> SyntaxError? {
    do {
        _ = try Parser.parse(source, bound: names(bound))
        return nil
    } catch {
        return error
    }
}

// MARK: Mode detection

@Test func bareWordsAreCommands() throws {
    #expect(try modes("ls -la; git status; ./run.sh; ~/bin/x; $EDITOR notes") == Array(repeating: "command", count: 5))
}

@Test func literalsAndBracketsAreExpressions() throws {
    #expect(try modes(#"1 + 2; "hi"; 'raw'; (1); [1]; !true; -1; true; nil"#) == Array(repeating: "expression", count: 9))
}

@Test func unknownNamesAreCommandsNotErrors() throws {
    #expect(try modes("undefined + 1; Int.max") == ["command", "command"])
}

@Test func boundVariablesAreExpressions() throws {
    #expect(try modes("n > 2", bound: ["n"]) == ["expression"])
    #expect(try modes("n > 2") == ["command"])
}

@Test func declarationsBindForLaterStatements() throws {
    #expect(try modes("let n = 1; n > 0") == ["declaration", "expression"])
}

@Test func blockDeclarationsDontEscape() throws {
    #expect(try modes("if true { let y = 1 }; y") == ["if", "command"])
}

@Test func caretForcesCommandMode() throws {
    #expect(try modes("^n -la", bound: ["n"]) == ["command"])
}

@Test func assignmentNeedsABoundName() throws {
    let program = try parse("i = 2", bound: ["i"])
    #expect(program.statements == [.assign(name: "i", value: .literal(.int(2)))])
    #expect(try modes("i = 2") == ["command"]) // runs a command named `i`
}

@Test func functionNamesStartCommandsUnlessCalled() throws {
    #expect(try modes("greet Rak --loud; greet(\"Rak\")", functions: ["greet"]) == ["command", "expression"])
    #expect(try modes("func greet() {}; greet Rak") == ["declaration", "command"])
}

@Test func loopsAreUnits() throws {
    #expect(try modes("for x in [1] {}; while false {}; true && for x in [1] {}") == ["loop", "loop", "expression"])
}

// MARK: Functions and closures

@Test func functionSignatures() throws {
    let program = try parse("func greet(_ name: String, times: Int = 1, to recipients: [String]...) -> Bool { true }")
    guard case .function(let decl) = program.statements[0] else { Issue.record(); return }
    #expect(decl.parameters == [
        Parameter(label: nil, name: "name", type: .string),
        Parameter(label: "times", name: "times", type: .int, defaultValue: .literal(.int(1))),
        Parameter(label: "to", name: "recipients", type: .list(.string), variadic: true),
    ])
    #expect(decl.returnType == .bool)
}

@Test func closureParameterForms() throws {
    #expect(try closureParameters("let f = { $0 + $1 }") == ["$0", "$1"])
    #expect(try closureParameters("let f = { a, b in a }") == ["a", "b"])
    #expect(try closureParameters("let f = { (a: Int) -> Int in a }") == ["a"])
    #expect(try closureParameters("let f = { echo hi }") == [])
}

@Test func dollarDigitsOutsideClosuresAreText() throws {
    #expect(try words("echo costs $5").last == [.literal("$5")])
}

@Test func controlFlowNeedsAnEnclosingConstruct() {
    for source in ["return", "break", "continue", "if true { break }", "func f() { $(return) }", "for x in [1] { func g() { break } }"] {
        #expect(syntaxError(source) != nil, "\(source)")
    }
    for source in ["func f() { return }", "func f() -> Int { return 1 }", "for x in [1] { if true { continue } }", "while true { break }"] {
        #expect(syntaxError(source) == nil, "\(source)")
    }
}

@Test func invalidSignatures() {
    for source in ["func f(x) {}", "func f(_ a: Int, _ a: Int) {}", "func f(_ a: Int..., _ b: Int) {}", "func f(_ a: Foo) {}", "func (_ a: Int) {}",
                   "func f(@input _ a: Int, @input _ b: Int) {}", "func f(@input _ a: Int...) {}",
                   "func f(@flag(\"n\") _ a: Int) {}", "func f(@flag(\"n\") a: Int, @flag(\"n\") b: Int) {}",
                   "func f(@flag(\"no\") a: Int) {}", "func f(@bogus a: Int) {}", "let f = { (@input x) in x }"] {
        #expect(syntaxError(source)?.incomplete == false, "\(source)")
    }
}

@Test func parameterAttributesAndOptionals() throws {
    let program = try parse(#"func f(@input _ item: Int?, @flag("n") times: Int = 1) {}"#)
    guard case .function(let decl) = program.statements[0] else { Issue.record(); return }
    #expect(decl.parameters == [
        Parameter(label: nil, name: "item", type: .optional(.int), isInput: true),
        Parameter(label: "times", name: "times", type: .int, defaultValue: .literal(.int(1)), shortFlag: "n"),
    ])
}

@Test func docCommentsAboveFunctions() throws {
    let source = """
    echo unrelated # not documentation

    # Greets someone.
    #
    # Politely.
    # - Parameter name: who to greet
      func greet(_ name: String) {}
    # A stray comment
    ; func other() {}
    """
    let functions = try parse(source).statements.compactMap { statement -> FunctionDecl? in
        if case .function(let decl) = statement { decl } else { nil }
    }
    #expect(functions[0].documentation == Documentation(summary: "Greets someone.\n\nPolitely.", parameters: ["name": "who to greet"]))
    #expect(functions[1].documentation == nil)
}

@Test func valuesCanFeedPipelines() throws {
    guard case .chain(let chain) = try parse("[1, 2] | sort | head -1").statements[0],
          case .pipeline(let pipeline) = chain.first else { Issue.record(); return }
    #expect(pipeline.input == .list([.literal(.int(1)), .literal(.int(2))]))
    #expect(pipeline.commands.map { $0.words.count } == [1, 2])
    #expect(pipeline.source == "[1, 2] | sort | head -1")
    #expect(try modes("false || true") == ["expression"]) // `||` is still a chain
    #expect(syntaxError("[1] |")?.incomplete == true)
}

// MARK: Words

@Test func quotingAndEscapes() throws {
    #expect(try words(#"echo 'a  b' "c \"d\"" x\ y"#) == [
        [.literal("echo")], [.literal("a  b")], [.literal(#"c "d""#)], [.literal("x y")],
    ])
}

@Test func emptyQuotesMakeAnEmptyWord() throws {
    #expect(try words(#"printf '' """#) == [[.literal("printf")], [.literal("")], [.literal("")]])
}

@Test func interpolationInWords() throws {
    #expect(try words(#"echo \(n)px "$HOME/x" $?"#, bound: ["n"]).dropFirst() == [
        [.expression(.variable("n")), .literal("px")],
        [.expression(.dollar("HOME")), .literal("/x")],
        [.expression(.status)],
    ])
}

@Test func tildeOnlyAtWordStart() throws {
    #expect(try words("cd ~ ~/src a~ '~'").dropFirst() == [
        [.expression(.dollar("HOME"))],
        [.expression(.dollar("HOME")), .literal("/src")],
        [.literal("a~")],
        [.literal("~")],
    ])
}

@Test func emptyBracesAreAWord() throws {
    #expect(try words(#"find . -exec rm {} \;"#).last == [.literal(";")])
    #expect(try words(#"find . -exec rm {} \;"#).dropLast().last == [.literal("{}")])
}

@Test func dollarWithoutANameIsLiteral() throws {
    #expect(try words("echo $ a$").dropFirst() == [[.literal("$")], [.literal("a$")]])
}

// MARK: Expressions

@Test func precedence() throws {
    let program = try parse("1 + 2 * 3 == 7 && !false")
    let expected = Expr.binary(
        .and,
        .binary(.equal, .binary(.add, .literal(.int(1)), .binary(.multiply, .literal(.int(2)), .literal(.int(3)))), .literal(.int(7))),
        .unary(.not, .literal(.bool(false)))
    )
    // A whole-unit expression leaves && to the chain, so compare the parts.
    guard case .chain(let chain) = program.statements[0] else { Issue.record(); return }
    #expect(chain.first == .expression(.binary(.equal, .binary(.add, .literal(.int(1)), .binary(.multiply, .literal(.int(2)), .literal(.int(3)))), .literal(.int(7)))))
    #expect(chain.links == [Link(op: .and, unit: .expression(.unary(.not, .literal(.bool(false)))))])
    // Inside a declaration, && is an ordinary operator.
    #expect(try parse("let x = 1 + 2 * 3 == 7 && !false").statements == [.declare(name: "x", mutable: false, value: expected)])
}

@Test func numbers() throws {
    #expect(try parse("1_000; 2.5").statements == [
        .chain(Chain(first: .expression(.literal(.int(1000))))),
        .chain(Chain(first: .expression(.literal(.double(2.5))))),
    ])
}

// MARK: Errors

@Test func incompleteInputAsksForMore() {
    for source in ["if true {", #"echo "abc"#, "echo 'abc", "ls |", "true &&", "let x =", #"echo \"#, "$(ls", "[1,", "(1 +",
                   "func f() {", "for x in [1] {", "while true {", "let f = { $0", "func f(_ a: Int,"] {
        #expect(syntaxError(source)?.incomplete == true, "\(source)")
    }
}

@Test func realErrorsAreNotIncomplete() {
    for source in ["| ls", "ls )", "echo (x)", "ls &", "}", "else { }", "1 < 2 < 3", "let if = 1", "(undefined + 1)", "(f(1))", "7zip", "1...2...3"] {
        let error = syntaxError(source)
        #expect(error != nil && error?.incomplete == false, "\(source)")
    }
}
