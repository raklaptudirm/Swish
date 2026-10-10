@_spi(Shell) import Swiit
@_spi(Shell) @testable import SwishShell
import SwishKit
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

/// The syntax or type error that stops `source` before it runs, or nil.
private func checkError(_ source: String) -> String? {
    let shell = Shell()
    let program: Program
    do {
        program = try Parser.parse(source, bound: shell.interpreter.globalNames(), plugin: shell.interpreter.syntax)
    } catch {
        return "syntax error: \(error)"
    }
    do {
        _ = try TypeChecker(interpreter: shell.interpreter).check(program)
        return nil
    } catch {
        return "error: \(error.message)"
    }
}

@Test func functionsAndTypesCanBeUsedBeforeTheirDeclarations() throws {
    // At the top, calling before the declaration too, as in Swift's main.swift.
    #expect(try output("""
    a()
    func a() -> Int { b() + 1 }
    func b() -> Int { 41 }
    hello Rak
    func hello(_ name: String) { echo "hi \\(name)" }
    Point(x: 2).x
    struct Point { let x: Int }
    Kind.b
    enum Kind { case a, b }
    """) == "42\nhi Rak\n2\nKind.b\n")
    // In a function body, and after its return.
    #expect(try output("""
    func outer() -> Int {
        return inner() * 2
        func inner() -> Int { 21 }
    }
    outer()
    """) == "42\n")
    // Only at the start of a statement: here `func` is just a word.
    #expect(try output("echo func x") == "func x\n")
}

@Test func unquotedListsSpreadIntoArguments() throws {
    let xs = #"let xs = ["-n", "a b"]; "#
    #expect(try output(xs + #"printf "%s|" $xs; echo"#) == "-n|a b|\n")
    #expect(try output(xs + #"printf "%s|" \(xs); echo"#) == "-n|a b|\n")
    // Quoted, or part of a longer word, it's one argument as it's written.
    #expect(try output(xs + #"printf "%s|" "$xs"; echo"#) == "[-n, a b]|\n")
    #expect(try output(xs + #"printf "%s|" x$xs; echo"#) == "x[-n, a b]|\n")
    // An empty list is no arguments at all.
    #expect(try output(#"let none: [String] = []; printf "%s|" a $none b; echo"#) == "a|b|\n")
    // Into a function's command line, filling its parameters in turn.
    #expect(try output(#"func two(_ a: String, _ b: String) { echo "\(a)+\(b)" }; let ab = ["p", "q"]; two $ab"#) == "p+q\n")
}

@Test func conditionalExpressions() throws {
    #expect(try output(#"let n = 5; n > 3 ? "big" : "small"; let s = n > 9 ? "big" : "small"; s"#) == "\"big\"\n\"small\"\n")
    // Right-associative, and inside other expressions.
    #expect(try output(#"true ? false ? "a" : "b" : "c"; [1, 2].map { $0 == 1 ? "one" : "more" }"#)
        == "\"b\"\n[\"one\", \"more\"]\n")
    #expect(try output(#"echo "\(1 < 2 ? "yes" : "no")""#) == "yes\n")
    // `if` as an expression, with else if, if let, and as a function's body.
    #expect(try output("""
    let n = 5
    let parity = if n % 2 == 0 { "even" } else if n > 4 { "odd, big" } else { "odd" }
    parity
    let missing: Int? = nil
    let got = if let v = missing { v } else { -1 }
    got
    func sign(_ x: Int) -> String {
        if x < 0 { "negative" } else if x == 0 { "zero" } else { "positive" }
    }
    sign(-2); sign(3)
    """) == "\"odd, big\"\n-1\n\"negative\"\n\"positive\"\n")
    // The type is both branches': nil makes an optional, a context gives Double or an enum.
    #expect(try output("let m = 1 > 2 ? 1 : nil; m ?? 0; let d: Double = true ? 1 : 2.5; d") == "0\n1.0\n")
    // A `?` without space around it is still optional chaining, try? and Int?.
    #expect(try output("let o: Int? = 3; o?.description; let t = try? $(true); t != nil") == "\"3\"\ntrue\n")

    #expect(checkError(#"let z = true ? 1 : "a""#) == "error: an if expression's branches must have one type, not Int and String")
    #expect(checkError("let z = 3 ? 1 : 2") == "error: a condition must be a Bool, not Int")
    #expect(checkError("let z = if true { 1 }") == "syntax error: an if expression needs an else")
    // A command is an expression too, whose value is how it ended.
    #expect(checkError("let z = if true { ls } else { 2 }") == "error: an if expression's branches must have one type, not Status and Int")
}

@Test func guardStatements() throws {
    #expect(try output("""
    func tilde(_ path: String, _ home: String?) -> String {
        guard let home = home else { return path }
        guard path.hasPrefix(home) else { return path }
        return "~" + String(path.dropFirst(home.count))
    }
    tilde("/u/me/src", "/u/me"); tilde("/u/me/src", nil); tilde("/opt", "/u/me")
    enum R { case ok(Int), failed }
    func doubled(_ r: R) -> Int {
        guard case .ok(let n) = r else { return -1 }
        return n * 2
    }
    doubled(.ok(21)); doubled(.failed)
    for x in [1, 2, 3, 4] {
        guard x % 2 == 0 else { continue }
        echo $x
    }
    guard test -d / else { exit 1 }
    let maybe: Int? = 5
    guard let m = maybe else { exit 1 }
    m + 1
    """) == "\"~/src\"\n\"/u/me/src\"\n\"/opt\"\n42\n-1\n2\n4\n6\n")
    // The else must leave; what it binds must be an optional.
    #expect(checkError("guard true else { echo no }") == "error: guard's else must not carry on: end it with return, break, continue or exit")
    #expect(checkError("guard let q = 5 else { exit 1 }") == "error: 'let' in a condition unwraps an optional, but this is Int")
    #expect(checkError("guard true { exit 1 }") == "syntax error: expected 'else' after guard's condition, found '{'")
}

@Test func aWordThatIsNeitherSaysWhy() throws {
    // No program by that name, and it was only a command because it isn't an expression.
    let shell = Shell()
    _ = try output("1...2...3", in: shell)
    #expect(shell.lastStatus != 0)
    // Quoted, or starting with a digit, a program still runs.
    #expect(try output(#""/bin/echo" quoted; ^echo plain"#) == "quoted\nplain\n")
}
