import Swiit
import Testing

@testable import SwishEngine

// Statements, loops, functions and closures: the language itself, as a script or the prompt takes it.

/// Runs `source` in `shell`, returning what it wrote to standard output.
private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.runner.capturing { shell.enter(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.runner.capturing { shell.execute(source) } }
    return shell.lastStatus.number
}

private func withVariable(_ name: String, _ value: Any) -> Shell {
    let shell = Shell()
    let literal = value is String ? "\"\(value)\"" : "\(value)"
    shell.execute("let \(name) = \(literal)")
    return shell
}

private let greet =
    #"func greet(_ name: String, times: Int = 1, loud: Bool = false) { var word = "hi"; if loud { word = "HI" }; for _ in 1...times { echo "\(word) \(name)" } };"#

@Test func arithmeticAndDisplay() throws {
    #expect(try output("let n = 3; n * 2 + 1") == "7\n")
    #expect(try output("7 / 2; 7 % 2; 7.0 / 2; -n", in: withVariable("n", 4)) == "3\n1\n3.5\n-4\n")
    #expect(try output(#""a" + "b"; [1, 2] + [3]"#) == "\"ab\"\n[1, 2, 3]\n")
    #expect(try output("1 < 2; 1 == 1.0; [1, 2][1]") == "true\ntrue\n2\n")
}

@Test func boolLiteralsActLikeTheCommands() throws {
    #expect(try output("true; false; nil") == "")
    #expect(status("false") == 1)
    #expect(status("true") == 0)
}

@Test func interpolation() throws {
    let shell = withVariable("name", "Swish")
    #expect(try output(#"echo "hi \(name)!" \(1 + 2)px"#, in: shell) == "hi Swish! 3px\n")
    #expect(try output(#"echo "$name" $name"#, in: shell) == "Swish Swish\n")
}

@Test func interpolationNeverSplitsWords() throws {
    let shell = withVariable("s", "a  b")
    #expect(try output(#"printf '[%s]' $s \(s)"#, in: shell) == "[a  b][a  b]")
}

@Test func ifElse() throws {
    #expect(try output("let n = 3; if n > 2 { echo big } else { echo small }") == "big\n")
    #expect(try output("if false { echo 1 } else if true { echo 2 } else { echo 3 }") == "2\n")
    #expect(try output("if grep -q nope /dev/null { echo found } else { echo none }") == "none\n")
    #expect(try output("if true && 1 < 2 { echo both }") == "both\n")
    #expect(try output("if true {\n  echo a\n  echo b\n}\nelse { echo c }") == "a\nb\n")
}

@Test func conditionsMustBeBool() {
    #expect(status("if 1 { echo x }") == 2)
}

@Test func variablesAndScopes() throws {
    #expect(try output("var i = 1; i = i + 1; i") == "2\n")
    #expect(try output("let x = 1; if true { let x = 2; print(x) }; x") == "2\n1\n")
    #expect(try output("var x = 1; if true { x = 5 }; x") == "5\n")
}

@Test func globalsPersistAcrossInputs() throws {
    let shell = Shell()
    _ = try output("let n = 41", in: shell)
    #expect(try output("n + 1", in: shell) == "42\n")
}

@Test func forLoops() throws {
    #expect(try output("for i in 1...3 { print(i) }") == "1\n2\n3\n")
    #expect(
        try output("for i in 0..<2 { print(i) }; for x in [\"a\", \"b\"] { print(x) }")
            == "0\n1\na\nb\n"
    )
    // Strings iterate by character, as in Swift; command output by `.lines`.
    #expect(try output(#"for c in "héy" { print(c) }"#) == "h\né\ny\n")
    #expect(
        try output(#"for line in $(printf 'a b\nc').lines { echo "<\(line)>" }"#) == "<a b>\n<c>\n"
    )
    #expect(try output(#"for line in "" { echo never }"#) == "")
    #expect(try output("for _ in 1...2 { echo x }") == "x\nx\n")
}

@Test func rangesAreLazyInLoops() throws {
    #expect(
        try output("for i in 1...9_000_000_000_000 { if i == 2 { break } }; echo done") == "done\n"
    )
    // A range is a ClosedRange, not a list, so it's never built.
    #expect(try output("let r = 1...9_000_000_000_000; r.count") == "9000000000000\n")
    #expect(status("for i in 3...1 {}") == 1)
}

@Test func whileLoops() throws {
    #expect(try output("var n = 0; while n < 3 { n = n + 1 }; n") == "3\n")
    #expect(try output("var n = 0; while test $n -lt 2 { n = n + 1 }; n") == "2\n")
}

@Test func breakAndContinue() throws {
    #expect(
        try output("for i in 0..<10 { if i == 1 { continue }; if i == 3 { break }; print(i) }")
            == "0\n2\n"
    )
    #expect(
        try output("for i in 1...2 { for j in 1...3 { if j == 2 { break }; echo \\(i)\\(j) } }")
            == "11\n21\n"
    )
}

@Test func functionsInExpressionMode() throws {
    #expect(try output("func square(_ x: Int) -> Int { x * x }; square(7)") == "49\n")
    #expect(
        try output(
            "func fib(_ n: Int) -> Int { if n < 2 { return n }; return fib(n - 1) + fib(n - 2) }; fib(15)"
        )
            == "610\n"
    )
    #expect(
        try output(
            #"func greet(_ name: String, times: Int = 1) -> String { "\(name)x\(times)" }; greet("a"); greet("b", times: 2)"#
        ) == "\"ax1\"\n\"bx2\"\n"
    )
    #expect(try output("func half(_ x: Double) -> Double { x / 2 }; half(3)") == "1.5\n")
    #expect(
        try output(
            "func sum(_ xs: Int...) -> Int { var t = 0; for x in xs { t = t + x }; return t }; sum(); sum(1, 2, 3)"
        ) == "0\n6\n"
    )
}

@Test func argumentErrors() {
    let f = "func f(_ x: Int, label: String = \"d\") -> Int { x };"
    #expect(status(f + "f()") == 2)
    #expect(status(f + "f(\"s\")") == 2)
    #expect(status(f + "f(1, other: \"x\")") == 2)
    #expect(status(f + "f(1, 2)") == 2)
    #expect(status("func f() -> Int { \"no\" }; f()") == 2)
    #expect(status("func f() -> Int { echo hi }; f()") == 2)
}

@Test func functionsDontDisplay() throws {
    #expect(try output("func f() { 42; echo side }; f()") == "side\n")
}

@Test func closures() throws {
    #expect(try output("let double = { $0 * 2 }; double(21)") == "42\n")
    #expect(try output("let add = { a, b in a + b }; add(1, 2)") == "3\n")
    #expect(
        try output(
            "func apply(_ f: (Int) -> Int, _ x: Int) -> Int { f(x) }; apply({ $0 + 100 }, 1)"
        ) == "101\n"
    )
}

@Test func closuresCaptureByReference() throws {
    #expect(
        try output(
            "func counter() -> (Int) -> Int { var c = 0; return { c = c + $0; return c } }; let next = counter(); next(1); next(5)"
        ) == "1\n6\n"
    )
    #expect(
        try output(
            "var fs: [() -> Int] = []; for i in 1...3 { fs = fs + [{ i * 10 }] }; fs[0](); fs[2]()"
        )
            == "10\n30\n"
    )
}

@Test func stringsInExpressionsArePureSwift() throws {
    #expect(try output(#""costs $5 and $HOME""#) == #""costs $5 and $HOME""# + "\n")
    #expect(try output(#"echo "home: $HOME" | cut -c1-6"#) == "home: \n")
}
