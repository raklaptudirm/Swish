import Swiit
import Testing

@testable import SwishEngine

// What the prompt shows for a value, and what a script shows.

/// Runs `source` in `shell`, returning what it wrote to standard output.
private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

@Test func bareValuesShowTheirDebugDescription() throws {
    #expect(
        try output(#"let r = $(echo Hello); r"#)
            == #"Output(text: "Hello", status: Status(code: 0, signal: nil, succeeded: true))"#
            + "\n"
    )
    #expect(
        try output(#""tab\there"; let xs: [Any] = [1, "x", nil]; xs; ["k": "v"].debugDescription"#)
            == #""tab\there""#
            + "\n" + #"[1, "x", nil]"# + "\n" + #""[\"k\": \"v\"]""# + "\n"
    )
    #expect(
        try output(
            #"enum E { case a, b(code: Int, String) }; E.b(code: 2, "no"); "\(E.b(code: 2, "no"))""#
        )
            == #"E.b(code: 2, "no")"# + "\n" + #""b(code: 2, \"no\")""# + "\n"
    )
    // Interpolation, commands and pipelines use the plain text.
    #expect(
        try output(#"let r = $(echo Hello); echo $r "\(r)"; ["a", "b"] | prefix 2"#)
            == "Hello Hello\na\nb\n"
    )
    // Awaiting a job that wrote to the terminal shows nothing more.
    #expect(try output("let j = async true; await j").isEmpty)
}

@Test func onlyThePromptShowsValues() throws {
    // The prompt shows the value of each expression it is given; a block's
    // own expressions aren't shown, and `print` is how a block speaks.
    #expect(try output("1; 2; \"a\"") == "1\n2\n\"a\"\n")
    #expect(try output("for i in 1...3 { i }") == "")
    #expect(try output("if true { 1 } else { 2 }") == "")
    #expect(try output("do { 1 }; 2") == "2\n")
    #expect(try output("func f() -> Int { 1 }; f()") == "1\n")
    // Running code (a script, `swish -c`, `execute`) shows nothing for a bare expression.
    let shell = Shell()
    let code = try onLargeStack { try shell.capturing { shell.execute("1; 2; print(3)") } }
    #expect(code == "3\n")
}
