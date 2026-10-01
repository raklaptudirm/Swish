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
        case .switchStatement: return "switch"
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
    return pipeline.commands[0].words.map { word in
        guard case .text(let parts) = word else { return [] }
        return parts
    }
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
    #expect(program.statements == [.assign(Assignment(root: "i", value: .literal(.int(2))))])
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
    echo unrelated // not documentation

    /// Greets someone.
    ///
    /// Politely.
    /// - Parameter name: who to greet
      func greet(_ name: String) {}
    // An ordinary comment isn't documentation.
    func other() {}
    """
    let functions = try parse(source).statements.compactMap { statement -> FunctionDecl? in
        if case .function(let decl) = statement { decl } else { nil }
    }
    #expect(functions[0].documentation == Documentation(summary: "Greets someone.\n\nPolitely.", parameters: ["name": "who to greet"]))
    #expect(functions[1].documentation == nil)
}

@Test func valuesCanFeedPipelines() throws {
    guard case .chain(let chain) = try parse("[1, 2] | sorted | head -1").statements[0],
          case .pipeline(let pipeline) = chain.first else { Issue.record(); return }
    #expect(pipeline.input == .list([.literal(.int(1)), .literal(.int(2))]))
    #expect(pipeline.commands.map { $0.words.count } == [1, 2])
    #expect(pipeline.source == "[1, 2] | sorted | head -1")
    #expect(try modes("false || true") == ["expression"]) // `||` is still a chain
    #expect(syntaxError("[1] |")?.incomplete == true)
}

@Test func logicalOperatorsBindTighterThanChains() throws {
    // All expressions: one expression, with && tighter than ||.
    let program = try parse("a || b && c", bound: ["a", "b", "c"])
    #expect(program.statements == [.chain(Chain(first: .expression(
        .binary(.or, .variable("a"), .binary(.and, .variable("b"), .variable("c")))
    )))])
    // A command operand makes it a chain of units instead.
    guard case .chain(let chain) = try parse("a && echo hi", bound: ["a"]).statements[0] else { Issue.record(); return }
    #expect(chain.first == .expression(.variable("a")))
    #expect(chain.links.count == 1)
}

// MARK: Structured data

@Test func membersRecordsAndFileSizes() throws {
    let program = try parse(#"let r = ["name": "x", "size": 1.5.kb]; r.size; [:]"#)
    #expect(program.statements[0] == .declare(name: "r", mutable: false, value: .record([
        RecordEntry(key: .literal(.string("name")), value: .literal(.string("x"))),
        RecordEntry(key: .literal(.string("size")), value: .literal(.filesize(1500))),
    ])))
    #expect(program.statements[1] == .chain(Chain(first: .expression(.member(.variable("r"), "size")))))
    #expect(program.statements[2] == .chain(Chain(first: .expression(.record([])))))
    #expect(try parse("2.kib; 1...3").statements.count == 2) // ranges still work
    // Not a file size, so a command, which says why it isn't one if no program has the name.
    #expect(try command("1.parsecs")?.notAnExpression == "unknown unit 'parsecs'; file sizes use b, kb, mb, gb, tb, or kib, mib, gib, tib")
    #expect(syntaxError(#"["a": 1, 2]"#) != nil)
}

@Test func closuresAsCommandArguments() throws {
    guard case .chain(let chain) = try parse("ls | filter { $0.size > 1.mb }").statements[0],
          case .pipeline(let pipeline) = chain.first,
          case .closure(let closure) = pipeline.commands[1].words[1] else { Issue.record(); return }
    #expect(closure.parameters.map(\.name) == ["$0"])
}

@Test func braceEndsACommandInAConditionOnly() throws {
    guard case .chain(let chain) = try parse("if grep -q x f { echo yes }").statements[0],
          case .ifStatement(let node) = chain.first,
          case .chain(let conditionChain) = node.condition,
          case .pipeline(let condition) = conditionChain.first else { Issue.record(); return }
    #expect(condition.commands[0].words.count == 4)
    #expect(node.then.statements.count == 1)
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
    // Unquoted, a value can spread (a list alone in its word); quoted, it can't.
    #expect(try words(#"echo \(n)px "$HOME/x" $n"#, bound: ["n"]).dropFirst() == [
        [.spread(.variable("n")), .literal("px")],
        [.expression(.dollar("HOME")), .literal("/x")],
        [.spread(.dollar("n"))],
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
    #expect(program.statements == [.chain(Chain(first: .expression(expected)))])
    // Inside a declaration too.
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
    for source in ["| ls", "ls )", "echo (x)", "ls &", "}", "else { }", "1 < 2 < 3", "let if = 1", "(undefined + 1)", "(f(1))"] {
        let error = syntaxError(source)
        #expect(error != nil && error?.incomplete == false, "\(source)")
    }
}

// MARK: Redirects and globs

private func command(_ source: String) throws -> CommandNode? {
    guard case .chain(let chain) = try parse(source).statements.first,
          case .pipeline(let pipeline) = chain.first else { return nil }
    return pipeline.commands.first
}

@Test func redirectsInOrder() throws {
    let node = try command("cmd > out e>o < in >> log e>> err o+e> all o+e>> more o>e e> e")
    #expect(node?.redirects == [
        Redirect(fd: 1, target: .file([.literal("out")], .write)),
        Redirect(fd: 2, target: .descriptor(1)),
        Redirect(fd: 0, target: .file([.literal("in")], .read)),
        Redirect(fd: 1, target: .file([.literal("log")], .append)),
        Redirect(fd: 2, target: .file([.literal("err")], .append)),
        Redirect(fd: 1, target: .file([.literal("all")], .write)),
        Redirect(fd: 2, target: .descriptor(1)),
        Redirect(fd: 1, target: .file([.literal("more")], .append)),
        Redirect(fd: 2, target: .descriptor(1)),
        Redirect(fd: 1, target: .descriptor(2)),
        Redirect(fd: 2, target: .file([.literal("e")], .write)),
    ])
    #expect(node?.words.count == 1)
}

@Test func redirectSpellingDetails() throws {
    #expect(try command("echo 2 > f")?.words.count == 2) // a number is just an argument
    #expect(try command("echo a>b")?.words.count == 2) // `>` ends a word
    #expect(try command("> out echo hi")?.words.count == 2) // redirects can come first
    // `e>o` merges only when it stands alone; `e>output` is a file.
    #expect(try command("cmd e>output")?.redirects == [Redirect(fd: 2, target: .file([.literal("output")], .write))])
    #expect(try command("cmd e>o|x")?.redirects == [Redirect(fd: 2, target: .descriptor(1))])
}

@Test func posixRedirectsNameTheSwishSpelling() {
    for (posix, swish) in [("2>f", "e>"), ("2>>f", "e>>"), ("2>&1", "e>o"), (">&2", "o>e"), ("&> f", "o+e>"), ("&>> f", "o+e>>"), ("1> f", ">")] {
        #expect(syntaxError("echo x \(posix)")?.description.hasSuffix(swish) == true, "\(posix)")
    }
    #expect(syntaxError("echo x 3> f")?.description.contains("numbered descriptors") == true)
}

@Test func redirectErrors() {
    #expect(syntaxError("echo >")?.incomplete == true)
    #expect(syntaxError("echo > | cat")?.incomplete == false)
    #expect(syntaxError("echo & x")?.description.contains("async") == true)
}

@Test func commentsAreSlashes() throws {
    #expect(try words("echo hi // note").count == 2)
    #expect(try words("echo #tag http://x//y") == [[.literal("echo")], [.literal("#tag")], [.literal("http://x//y")]])
    #expect(try parse("#!/usr/bin/env swish\necho hi").statements.count == 1)
    #expect(syntaxError("let x = 1 # not a comment") != nil)
}

@Test func dollarStatusIsGone() {
    #expect(syntaxError("echo $?")?.description.contains(".status") == true)
}

@Test func foreignMarksExternal() throws {
    #expect(try command("foreign ls -la")?.external == true)
    #expect(try command("foreign ls -la")?.words.count == 2)
    #expect(try command("^ls")?.external == true)
    #expect(try command("foreigner x")?.external == false) // only the whole word
}

@Test func environmentPrefixesAndAssignments() throws {
    let node = try command(#"EDITOR=vim MSG="a b" EMPTY= git commit"#)
    #expect(node?.environment == [
        EnvironmentAssignment(name: "EDITOR", value: [.literal("vim")]),
        EnvironmentAssignment(name: "MSG", value: [.literal("a b")]),
        EnvironmentAssignment(name: "EMPTY", value: [.literal("")]),
    ])
    #expect(node?.words.count == 2)
    #expect(syntaxError("FOO=bar")?.description.contains("env.FOO") == true)
    #expect(try parse(#"env.EDITOR = "vim"; env["X"] = nil"#).statements == [
        .setEnvironment(name: .literal(.string("EDITOR")), value: .literal(.string("vim"))),
        .setEnvironment(name: .literal(.string("X")), value: .literal(.nothing)),
    ])
}

@Test func dollarNamesInterpolateOnlyInCommands() throws {
    #expect(try parse(#"let s = "costs $5 and $HOME""#).statements == [
        .declare(name: "s", mutable: false, value: .literal(.string("costs $5 and $HOME"))),
    ])
    #expect(try words(#"echo "$HOME""#).last == [.expression(.dollar("HOME"))])
}

@Test func trailingClosures() throws {
    guard case .declare(_, _, .call(_, let arguments)) = try parse("let r = with(env: e) { x }", bound: ["with", "e", "x"]).statements[0] else {
        Issue.record()
        return
    }
    #expect(arguments.count == 2)
    #expect(arguments[1].label == nil)
    // After `if` and `for … in`, `{` is the body.
    guard case .chain(let chain) = try parse("if f(1) { echo }", bound: ["f"]).statements[0],
          case .ifStatement(let node) = chain.first else { Issue.record(); return }
    #expect(node.then.statements.count == 1)
}

@Test func onlyUnquotedWildcardsGlob() throws {
    #expect(try words(#"ls *.swift "*.txt" \*.md a[bc] '?'"#).dropFirst() == [
        [.glob("*.swift")],
        [.literal("*.txt")],
        [.literal("*"), .literal(".md")],
        [.glob("a[bc]")],
        [.literal("?")],
    ])
}

// MARK: Optionals

@Test func ifLetBindsInItsBodyOnly() throws {
    let program = try parse("if let x = try? $(cmd) { x } else { x }")
    guard case .chain(let chain) = program.statements[0], case .ifStatement(let node) = chain.first else {
        Issue.record()
        return
    }
    guard case .binding("x", false, .attempt(.substitution, .optional)) = node.condition else {
        Issue.record("not an optional binding: \(node.condition)")
        return
    }
    // In the body `x` is the variable; in the else branch it's a command.
    guard case .chain(let then) = node.then.statements[0], case .expression = then.first,
          case .chain(let otherwise) = node.otherwise!.statements[0], case .pipeline = otherwise.first else {
        Issue.record()
        return
    }
}

@Test func coalescingSitsBetweenComparisonAndRanges() throws {
    // Swift's precedence: `??` binds tighter than `==` and looser than `+`.
    let program = try parse("let v = a ?? b + 1 == c", bound: ["a", "b", "c"])
    #expect(program.statements == [.declare(name: "v", mutable: false, value: .binary(
        .equal,
        .binary(.coalesce, .variable("a"), .binary(.add, .variable("b"), .literal(.int(1)))),
        .variable("c")
    ))])
}

@Test func substitutionStartsAnExpressionButDollarNameACommand() throws {
    #expect(try modes("$(cmd) == \"x\"; $EDITOR notes; try? $(cmd)") == ["expression", "command", "expression"])
}

@Test func tryCoversTheRestOfTheExpression() throws {
    let program = try parse("let a = try? $(x) ?? 1; let b = (try? $(x)) ?? 1; let c = try $(x); let d = $(x)")
    // `try?` covers the `??` too, as in Swift, and marks the $(…) under it.
    guard case .declare(_, _, .attempt(.binary(.coalesce, .substitution(_, throwing: true), _), .optional)) = program.statements[0],
          case .declare(_, _, .binary(.coalesce, .attempt(.substitution(_, throwing: true), .optional), _)) = program.statements[1],
          case .declare(_, _, .attempt(.substitution(_, throwing: true), .plain)) = program.statements[2],
          case .declare(_, _, .substitution(_, throwing: false)) = program.statements[3] else {
        Issue.record("\(program.statements)")
        return
    }
    // The old postfix form is gone: a word after an expression makes a command.
    #expect(try command("$(x)?")?.notAnExpression == "unexpected '?'")
}

@Test func tryDoesNotReachIntoClosures() throws {
    guard case .declare(_, _, .attempt(.call(_, let arguments), .optional)) = try parse("let r = try? f({ $(x) })", bound: ["f"]).statements[0],
          case .closure(let closure) = arguments[0].value,
          case .chain(let chain) = closure.body.statements[0],
          case .expression(.substitution(_, throwing: false)) = chain.first else {
        Issue.record()
        return
    }
}

// MARK: do/catch and throwing commands

@Test func doCatchForms() throws {
    let program = try parse("do { a } catch { error }\ndo { b } catch let e { e }\ndo { c }")
    guard case .doCatch(_, "error", .some) = program.statements[0],
          case .doCatch(_, "e", .some) = program.statements[1],
          case .doCatch(_, _, nil) = program.statements[2] else {
        Issue.record("\(program.statements)")
        return
    }
    // `error` is bound in the handler: an expression there, a command outside.
    #expect(try modes("do { } catch { error }; error") == ["declaration", "command"])
}

@Test func tryBeforeACommand() throws {
    guard case .chain(let chain) = try parse("try make -j4").statements[0],
          case .pipeline(let pipeline) = chain.first else { Issue.record(); return }
    #expect(pipeline.throwing == .some(nil))
    #expect(pipeline.commands[0].words.count == 2)
    guard case .chain(let forced) = try parse("try! false").statements[0],
          case .pipeline(let bang) = forced.first else { Issue.record(); return }
    #expect(bang.throwing == .some(.forced))
    // An expression after `try` is still an expression.
    #expect(try modes("try $(x); try? false") == ["expression", "expression"])
}

// MARK: async and await

@Test func asyncAndAwaitForms() throws {
    let program = try parse("let j = async make -j4 | tee log; let p = async $(curl x); await j; await; try await p")
    guard case .declare(_, _, .async(.command(let command))) = program.statements[0],
          case .declare(_, _, .async(.capture(let capture))) = program.statements[1],
          case .chain(let a) = program.statements[2], case .expression(.await(.variable("j"), throwing: false)) = a.first,
          case .chain(let b) = program.statements[3], case .expression(.await(nil, throwing: false)) = b.first,
          case .chain(let c) = program.statements[4], case .expression(.attempt(.await(.variable("p"), throwing: true), .plain)) = c.first else {
        Issue.record("\(program.statements)")
        return
    }
    #expect(command.commands.count == 2)
    #expect(capture.source == "curl x")
    #expect(syntaxError("async $(a; b)") != nil) // one pipeline
}

// MARK: Enums and switch

@Test func enumDeclarations() throws {
    let program = try parse(#"enum Result: String { case ok = "OK", bad }; enum Shape { case circle(radius: Double), rect(Double, Double) }"#)
    guard case .enumDecl(let result) = program.statements[0], case .enumDecl(let shape) = program.statements[1] else {
        Issue.record()
        return
    }
    #expect(result.rawType == .string)
    #expect(result.cases.map(\.name) == ["ok", "bad"])
    #expect(result.cases[0].rawValue == .literal(.string("OK")))
    #expect(shape.cases[0].associated == [AssociatedValue(label: "radius", type: .double)])
    #expect(shape.cases[1].associated == [AssociatedValue(label: nil, type: .double), AssociatedValue(label: nil, type: .double)])
    // The name is a type from then on: it starts an expression, and types parameters.
    #expect(try modes("enum K { case a }; K.a; func f(_ k: K) {}") == ["declaration", "expression", "declaration"])
    #expect(syntaxError("enum K: Bool { case a }") != nil)
}

@Test func switchAndPatterns() throws {
    let program = try parse("switch x { case .a(let n), .b(let n, _) where n > 1: y\ncase let .c(m): z\ncase 1...9: w\ndefault: break }", bound: ["x", "y", "z", "w"])
    guard case .chain(let chain) = program.statements[0], case .switchStatement(let node) = chain.first else {
        Issue.record()
        return
    }
    #expect(node.cases.count == 4)
    #expect(node.cases[0].patterns == [
        .enumCase(type: nil, name: "a", arguments: [PatternArgument(label: nil, pattern: .binding(name: "n", mutable: false))]),
        .enumCase(type: nil, name: "b", arguments: [
            PatternArgument(label: nil, pattern: .binding(name: "n", mutable: false)),
            PatternArgument(label: nil, pattern: .wildcard),
        ]),
    ])
    #expect(node.cases[0].guardExpr != nil)
    #expect(node.cases[1].patterns == [.enumCase(type: nil, name: "c", arguments: [PatternArgument(label: nil, pattern: .binding(name: "m", mutable: false))])])
    #expect(node.cases[3].patterns.isEmpty) // default
}

@Test func switchErrors() {
    #expect(syntaxError("switch x { case 1: }", bound: ["x"])?.description.contains("at least one statement") == true)
    #expect(syntaxError("switch x { case .a(let n), .b: y }", bound: ["x", "y"])?.description.contains("same names") == true)
    #expect(syntaxError("fallthrough") != nil)
    #expect(syntaxError("case 1: x") != nil)
    #expect(syntaxError("switch x {", bound: ["x"])?.incomplete == true)
}

@Test func whatParsesDecidesTheMode() throws {
    // A program whose name doesn't start like one: quoted, or with a digit.
    #expect(try modes(#""/opt/My App/run" x; 2to3 x; 7zip a; ./run"#) == ["command", "command", "command", "command"])
    // A name that isn't bound, even when its start is: `git-lfs` is one word.
    #expect(try modes("ls -la; git-lfs version", bound: ["git"]) == ["command", "command"])
    // Expressions parse, and nothing but the end of the unit follows them.
    #expect(try modes(#""text"; 1 + 2; x -1; .directory; !x; [1, 2]"#, bound: ["x"]) == Array(repeating: "expression", count: 6))
    // A function's name is a command unless it's called or read.
    #expect(try modes("greet Rak; greet; greet(); greet.self", functions: ["greet"]) == ["command", "command", "expression", "expression"])
    // Shell syntax always starts a command.
    #expect(try modes("$EDITOR notes; ^ls") == ["command", "command"])
    // Only a word that starts like an expression says why it isn't one.
    #expect(try command("1...2...3")?.notAnExpression == "'...' can't be chained; use parentheses or '&&'")
    #expect(try command(#""text" nonsense"#)?.notAnExpression == "unexpected 'nonsense'")
    #expect(try command("nosuchcommand")?.notAnExpression == nil)
}
