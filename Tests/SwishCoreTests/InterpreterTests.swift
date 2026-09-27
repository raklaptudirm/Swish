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
