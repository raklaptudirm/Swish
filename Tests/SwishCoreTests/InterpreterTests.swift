@testable import SwishCore
import Testing

/// Runs `source` in `shell`, returning what it wrote to standard output.
private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try shell.capturing { shell.execute(source) }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? shell.capturing { shell.execute(source) }
    return shell.lastStatus
}

@Test func arithmeticAndDisplay() throws {
    #expect(try output("let n = 3; n * 2 + 1") == "7\n")
    #expect(try output("7 / 2; 7 % 2; 7.0 / 2; -n", in: withVariable("n", 4)) == "3\n1\n3.5\n-4\n")
    #expect(try output(#""a" + "b"; [1, 2] + [3]"#) == "ab\n[1, 2, 3]\n")
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

@Test func environmentVariables() throws {
    #expect(try output("echo $HOME") == (env("HOME") ?? "") + "\n")
}

@Test func commandSubstitution() throws {
    #expect(try output("let b = $(echo hi | tr a-z A-Z); b") == "HI\n")
    #expect(try output(#"echo "[$(printf 'x\n\n')]""#) == "[x]\n")
}

@Test func substitutionHandlesLargeOutput() throws {
    // Larger than a pipe buffer, which would deadlock without concurrent draining.
    #expect(try output("let s = $(head -c 300000 /dev/zero | tr '\\0' x); s == s").hasPrefix("true"))
}

@Test func chains() throws {
    #expect(try output("false && echo no || echo yes") == "yes\n")
    #expect(try output("true && echo a; echo b") == "a\nb\n")
    #expect(try output("1 > 2 || echo fallback") == "fallback\n")
}

@Test func ifElse() throws {
    #expect(try output("let n = 3; if n > 2 { echo big } else { echo small }") == "big\n")
    #expect(try output("if false { echo 1 } else if true { echo 2 } else { echo 3 }") == "2\n")
    #expect(try output("if grep -q nope /dev/null { echo found } else { echo none }") == "none\n")
    #expect(try output("if true && 1 < 2 { echo both }") == "both\n")
    #expect(try output("if true {\n  echo a\n  echo b\n}\nelse { echo c }") == "a\nb\n")
}

@Test func conditionsMustBeBool() {
    #expect(status("if 1 { echo x }") == 1)
}

@Test func variablesAndScopes() throws {
    #expect(try output("var i = 1; i = i + 1; i") == "2\n")
    #expect(try output("let x = 1; if true { let x = 2; x }; x") == "2\n1\n")
    #expect(try output("var x = 1; if true { x = 5 }; x") == "5\n")
}

@Test func globalsPersistAcrossInputs() throws {
    let shell = Shell()
    _ = try output("let n = 41", in: shell)
    #expect(try output("n + 1", in: shell) == "42\n")
}

@Test func runtimeErrorsStopTheInput() throws {
    #expect(try output("let c = 1; c = 2; echo unreachable") == "")
    #expect(status("let c = 1; c = 2") == 1)
    #expect(status("1 / 0") == 1)
    #expect(status("[1][5]") == 1)
    #expect(status("(undefined)") == 2) // an unknown name in an expression
    #expect(status("9223372036854775807 + 1") == 1)
    #expect(status("echo $SWISH_SURELY_UNSET") == 1)
}

@Test func failingCommandsDontStopTheInput() throws {
    #expect(try output("false; echo $?; ^false; echo $?") == "1\n1\n")
}

@Test func syntaxErrorsSetStatusTwo() {
    #expect(status("echo (") == 2)
}

private func withVariable(_ name: String, _ value: Any) -> Shell {
    let shell = Shell()
    let literal = value is String ? "\"\(value)\"" : "\(value)"
    shell.execute("let \(name) = \(literal)")
    return shell
}

// MARK: Loops

@Test func forLoops() throws {
    #expect(try output("for i in 1...3 { i }") == "1\n2\n3\n")
    #expect(try output("for i in 0..<2 { i }; for x in [\"a\", \"b\"] { x }") == "0\n1\na\nb\n")
    #expect(try output(#"for line in $(printf 'a b\nc') { echo "<\(line)>" }"#) == "<a b>\n<c>\n")
    #expect(try output(#"for line in "" { echo never }"#) == "")
    #expect(try output("for _ in 1...2 { echo x }") == "x\nx\n")
}

@Test func rangesAreLazyInLoops() throws {
    #expect(try output("for i in 1...9_000_000_000_000 { if i == 2 { break } }; echo done") == "done\n")
    #expect(status("let r = 1...9_000_000_000_000") == 1)
    #expect(status("for i in 3...1 {}") == 1)
}

@Test func whileLoops() throws {
    #expect(try output("var n = 0; while n < 3 { n = n + 1 }; n") == "3\n")
    #expect(try output("var n = 0; while test $n -lt 2 { n = n + 1 }; n") == "2\n")
}

@Test func breakAndContinue() throws {
    #expect(try output("for i in 0..<10 { if i == 1 { continue }; if i == 3 { break }; i }") == "0\n2\n")
    #expect(try output("for i in 1...2 { for j in 1...3 { if j == 2 { break }; echo \\(i)\\(j) } }") == "11\n21\n")
}

// MARK: Functions

@Test func functionsInExpressionMode() throws {
    #expect(try output("func square(_ x: Int) -> Int { x * x }; square(7)") == "49\n")
    #expect(try output("func fib(_ n: Int) -> Int { if n < 2 { return n }; return fib(n - 1) + fib(n - 2) }; fib(15)") == "610\n")
    #expect(try output(#"func greet(_ name: String, times: Int = 1) -> String { "\(name)x\(times)" }; greet("a"); greet("b", times: 2)"#) == "ax1\nbx2\n")
    #expect(try output("func half(_ x: Double) -> Double { x / 2 }; half(3)") == "1.5\n")
    #expect(try output("func sum(_ xs: Int...) -> Int { var t = 0; for x in xs { t = t + x }; return t }; sum(); sum(1, 2, 3)") == "0\n6\n")
}

@Test func argumentErrors() {
    let f = "func f(_ x: Int, label: String = \"d\") -> Int { x };"
    #expect(status(f + "f()") == 1)
    #expect(status(f + "f(\"s\")") == 1)
    #expect(status(f + "f(1, other: \"x\")") == 1)
    #expect(status(f + "f(1, 2)") == 1)
    #expect(status("func f() -> Int { \"no\" }; f()") == 1)
    #expect(status("func f() -> Int { echo hi }; f()") == 1)
}

@Test func functionsDontDisplay() throws {
    #expect(try output("func f() { 42; echo side }; f()") == "side\n")
}

@Test func closures() throws {
    #expect(try output("let double = { $0 * 2 }; double(21)") == "42\n")
    #expect(try output("let add = { a, b in a + b }; add(1, 2)") == "3\n")
    #expect(try output("func apply(_ f: (Int) -> Int, _ x: Int) -> Int { f(x) }; apply({ $0 + 100 }, 1)") == "101\n")
}

@Test func closuresCaptureByReference() throws {
    #expect(try output("func counter() -> (Int) -> Int { var c = 0; return { c = c + $0; return c } }; let next = counter(); next(1); next(5)") == "1\n6\n")
    #expect(try output("var fs = []; for i in 1...3 { fs = fs + [{ i * 10 }] }; fs[0](); fs[2]()") == "10\n30\n")
}

// MARK: Command-mode calls

private let greet = #"func greet(_ name: String, times: Int = 1, loud: Bool = false) { var word = "hi"; if loud { word = "HI" }; for _ in 1...times { echo "\(word) \(name)" } };"#

@Test func commandModeBinding() throws {
    let f = #"func f(_ a: String, count: Int = 0, dryRun: Bool = false, color: Bool = true, include: [String]) -> String { "\(a) \(count) \(dryRun) \(color) \(include)" };"#
    #expect(try output(f + "f x --count 3 --dry-run --no-color --include a --include=b") == "x 3 true false [a, b]\n")
    #expect(try output(f + "f --count=2 -- --x") == "--x 2 false true []\n")
}

@Test func commandModeNumbersAndVariadics() throws {
    #expect(try output("func add(_ a: Int, _ b: Int) -> Int { a + b }; add 2 -5") == "-3\n")
    #expect(try output("func sum(_ xs: Double...) -> Double { var t = 0.0; for x in xs { t = t + x }; return t }; sum 1 2.5") == "3.5\n")
}

@Test func commandModeErrors() {
    let f = "func f(_ n: Int, name: String) {};"
    #expect(status(f + "f 1") == 1)                  // missing --name
    #expect(status(f + "f abc --name x") == 1)       // not an Int
    #expect(status(f + "f 1 --name x --bogus") == 1) // unknown option
    #expect(status(f + "f 1 2 --name x") == 1)       // extra positional
    #expect(status(f + "f 1 --name") == 1)           // flag without a value
    #expect(status(f + "f 1 --name x -v") == 1)      // no short flags
}

@Test func functionsInPipelinesAndSubstitutions() throws {
    #expect(try output(greet + "greet Rak --times 2 | tr a-z A-Z") == "HI RAK\nHI RAK\n")
    #expect(try output(greet + #"let s = $(greet Rak --loud); echo "[\(s)]""#) == "[HI Rak]\n")
    #expect(try output(greet + "^greet Rak") == "") // no external named greet
}

@Test func boolResultsAreStatuses() throws {
    let isBig = "func isBig(_ n: Int) -> Bool { n > 10 };"
    #expect(try output(isBig + "isBig 50 && echo big; isBig 5 || echo small") == "big\nsmall\n")
}

// MARK: Pipeline input

private let streaming = """
func double(@input _ n: Int) -> Int { n * 2 }
func total(@input _ xs: [Int]) -> Int { var t = 0; for x in xs { t = t + x }; return t }
func evens(@input _ n: Int) -> Int? { if n % 2 == 0 { return n }; return nil }
var calls = 0
func counted(@input _ n: Int) -> Int { calls = calls + 1; return n }

"""

@Test func perItemInput() throws {
    #expect(try output(streaming + "seq 4 | double") == "2\n4\n6\n8\n")
    #expect(try output(streaming + "seq 6 | evens | double") == "4\n8\n12\n")
    #expect(try output(streaming + "[1, 2, 3] | double") == "2\n4\n6\n")
}

@Test func wholeStreamInput() throws {
    #expect(try output(streaming + "seq 4 | double | total") == "20\n")
    #expect(try output(streaming + "[] | total") == "0\n")
}

@Test func inputFromTheCommandLineWhenFirst() throws {
    #expect(try output(streaming + "double 21; total 1 2 3") == "42\n6\n")
}

@Test func streamsFeedExternalCommands() throws {
    #expect(try output(streaming + "seq 3 | double | tr 0-9 a-j") == "c\ne\ng\n")
    #expect(try output(#""a b" | tr a-z A-Z"#) == "A B\n")
    #expect(try output("func gen() -> [Int] { [1, 2, 3] }; gen | tail -1") == "3\n")
}

@Test func streamsAreLazy() throws {
    // `head` exits after one line; the shell sees EPIPE and stops pulling
    // instead of dying of SIGPIPE or looping forever.
    #expect(try output(streaming + "yes 7 | double | head -2") == "14\n14\n")
    #expect(try output(streaming + "for _ in 1...1 { seq 100000 | counted | head -1 }; calls < 100000") == "1\ntrue\n")
}

@Test func streamErrors() {
    #expect(status(streaming + "printf 'x\\n' | double") == 1) // not an Int
    #expect(status(streaming + "double | cat | double") == 1)  // two in-process runs
}

// MARK: Flags, overloads, help

@Test func shortFlags() throws {
    let f = #"func f(@flag("n") times: Int = 1, @flag("v") verbose: Bool = false, @flag("q") quiet: Bool = false) -> String { "\(times) \(verbose) \(quiet)" };"#
    #expect(try output(f + "f -n 3; f -n3 -vq; f -qv --times=2") == "3 false false\n3 true true\n2 true true\n")
    #expect(status(f + "f -x") == 1)
    #expect(status(f + "f -vx") == 1)
}

@Test func negativeNumbersVersusShortFlags() throws {
    #expect(try output(#"func f(_ x: Int, @flag("5") five: Bool = false) -> String { "\(x) \(five)" }; f -5 -3"#) == "-3 true\n")
}

@Test func overloads() throws {
    let byType = #"func f(_ x: Int) -> String { "int" }; func f(_ x: String) -> String { "string" };"#
    #expect(try output(byType + "f 5; f abc; f(5); f(\"a\")") == "int\nstring\nint\nstring\n")
    let byLabel = #"func f(a: Int) -> String { "a" }; func f(b: Int) -> String { "b" };"#
    #expect(try output(byLabel + "f --b 1; f(a: 2)") == "b\na\n")
    #expect(try output(#"func f(_ x: Double) -> String { "double" }; func f(_ x: Int) -> String { "int" }; f(5); f(5.5)"#) == "int\ndouble\n")
}

@Test func redeclaringReplaces() throws {
    #expect(try output("func f() -> Int { 1 }; func f() -> Int { 2 }; f()") == "2\n")
}

@Test func overloadErrors() {
    #expect(status("func g(_ x: Int, _ y: Int) {}; func g(_ s: String) {}; g 1 2 3") == 1)
    #expect(status("func g(a: Int) {}; func g(b: Int) {}; g(c: 1)") == 1)
    #expect(status(#"func g(_ x: Int, y: Int = 0) -> Int { 1 }; func g(_ x: Int, z: Int = 0) -> Int { 2 }; g(1)"#) == 1) // ambiguous
}

@Test func generatedHelp() throws {
    let source = """
    # Greets someone.
    # - Parameter name: who to greet
    func greet(_ name: String, @flag("n") times: Int = 1, color: Bool = true, tags: [String]) {}
    greet --help
    """
    #expect(try output(source) == """
    Greets someone.

    Usage:
      greet [--times <Int>] [--no-color] [--tags <String>] <name>

    Arguments:
      <name>               who to greet (String)

    Options:
      -n, --times <Int>    (default: 1)
          --[no-]color     (default: true)
          --tags <String>  (repeatable)
      -h, --help           Show this help

    """)
}

@Test func helpCanBeClaimed() throws {
    #expect(try output(#"func f(help: Bool = false) -> Bool { help }; f --help"#) == "true\n")
    #expect(try output(#"func f() {}; f -- --help"#) == "")
}

@Test func which() throws {
    let text = try output("func greet(_ name: String) {}; which greet cd ls")
    #expect(text.hasPrefix("greet: function greet(_ name: String)\ncd: shell builtin\n/"))
    #expect(text.hasSuffix("/ls\n"))
    #expect(status("which surely-not-a-command") == 1)
}
