import Swiit
import Testing

@testable import SwishEngine

// `$(…)` and what a command gives back: its output, its lines and its status.

/// Runs `source` in `shell`, returning what it wrote to standard output.
private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.runner.capturing { shell.enter(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.runner.capturing { shell.execute(source) } }
    return shell.lastStatus.number
}

@Test func commandSubstitution() throws {
    #expect(
        try output("let b = $(echo hi | tr a-z A-Z); b")
            == "Output(text: \"HI\", status: Status(code: 0, signal: nil, succeeded: true))\n"
    )
    #expect(try output(#"echo "[$(printf 'x\n\n')]""#) == "[x]\n")
}

@Test func substitutionHandlesLargeOutput() throws {
    // Larger than a pipe buffer, which would deadlock without concurrent draining.
    #expect(
        try output("let s = $(head -c 300000 /dev/zero | tr '\\0' x); s == s").hasPrefix("true")
    )
}

@Test func chains() throws {
    #expect(try output("false && echo no || echo yes") == "yes\n")
    #expect(try output("true && echo a; echo b") == "a\nb\n")
    #expect(try output("1 > 2 || echo fallback") == "fallback\n")
}

@Test func outputIsLinesWithText() throws {
    let r = #"let r = $(printf 'a b\nc\n');"#
    #expect(
        try output(r + "r.count; r[0]; r.last; r.text; r.text.count")
            == "2\n\"a b\"\n\"c\"\n\"a b\\nc\"\n5\n"
    )
    #expect(try output(r + #"for line in r { echo "<\(line)>" }"#) == "<a b>\n<c>\n")
    #expect(
        try output(r + "r.status.code; r.status.succeeded; r.status.signal == nil")
            == "0\ntrue\ntrue\n"
    )
    #expect(try output("$(true).isEmpty; $(true).count") == "true\n0\n")
}

@Test func outputComparesWithTextAndGivesItsTextByName() throws {
    #expect(
        try output(#"let b = $(echo main); b == "main"; "on \(b)"; echo $(echo hi) there"#)
            == "true\n\"on main\"\nhi there\n"
    )
    #expect(try output(#"func up(_ s: String) -> String { s }; up($(echo hi).text)"#) == "\"hi\"\n")
    // There is no implicit conversion: a `String` parameter takes the text, by name.
    #expect(errorText(#"func up(_ s: String) -> String { s }; up($(echo hi))"#) != nil)
    #expect(try output("$(echo x).text + \"y\"") == "\"xy\"\n")
    // `description` is every value's textual form, as in Swift; `.text` is
    // the Output's data.
    #expect(
        try output(
            #"$(echo x).description == $(echo x).text; 1.5.kb.description; ["a": 1].description"#
        )
            == "true\n\"1.5 KB\"\n\"[\\\"a\\\": 1]\"\n"
    )
    #expect(try output(#"(description: "mine", n: 1).description"#) == "\"mine\"\n")
    #expect(status("$(echo x) + \"y\"") == 2)  // other String operations go through .text
    #expect(try output("$(printf '3\\n1\\n2') | sorted") == "1\n2\n3\n")
}

@Test func aCommandsListReadsLikePipelineOutput() throws {
    // In command form, an item per line, as `names | cat` would give; called
    // as Swift, the list as a value.
    #expect(
        try output(#"func names() -> [String] { ["a", "b"] }; names; names(); names | cat"#)
            == "a\nb\n" + #"["a", "b"]"# + "\na\nb\n"
    )
    #expect(try output("func none() -> [Int] { [] }; none").isEmpty)
}
