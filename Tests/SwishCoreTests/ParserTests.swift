@testable import SwishCore
import Testing

private func parse(_ source: String, bound: Set<String> = []) throws -> Program {
    try Parser.parse(source, bound: bound)
}

/// The kind of each top-level unit: "command", "expression" or "if".
private func modes(_ source: String, bound: Set<String> = []) throws -> [String] {
    try parse(source, bound: bound).statements.map { statement in
        guard case .chain(let chain) = statement else { return "declaration" }
        switch chain.first {
        case .pipeline: return "command"
        case .expression: return "expression"
        case .ifStatement: return "if"
        }
    }
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
        _ = try Parser.parse(source, bound: bound)
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
    for source in ["if true {", #"echo "abc"#, "echo 'abc", "ls |", "true &&", "let x =", #"echo \"#, "$(ls", "[1,", "(1 +"] {
        #expect(syntaxError(source)?.incomplete == true, "\(source)")
    }
}

@Test func realErrorsAreNotIncomplete() {
    for source in ["| ls", "ls )", "echo (x)", "ls &", "}", "else { }", "1 < 2 < 3", "let if = 1", "(undefined + 1)", "f(1)", "7zip"] {
        let error = syntaxError(source)
        #expect(error != nil && error?.incomplete == false, "\(source)")
    }
}
