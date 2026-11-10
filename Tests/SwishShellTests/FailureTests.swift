import Swiit
import Testing

@testable import SwishShell

// Failing commands and errors: statuses, `try`, `try?`, `try!`, and `do`/`catch`.

/// Runs `source` in `shell`, returning what it wrote to standard output.
private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    return shell.lastStatus.number
}

@Test func runtimeErrorsStopTheInput() throws {
    #expect(try output("let c = 1; c = 2; echo unreachable") == "")
    #expect(status("let c = 1; c = 2") == 2)
    #expect(status("1 / 0") == 1)
    #expect(status("[1][5]") == 1)
    #expect(status("(undefined)") == 2)  // an unknown name in an expression
    #expect(status("9223372036854775807 + 1") == 1)
    #expect(status("echo $SWISH_SURELY_UNSET") == 1)
}

@Test func failingCommandsDontStopTheInput() throws {
    #expect(try output("false; echo after; foreign false; echo again") == "after\nagain\n")
}

@Test func syntaxErrorsSetStatusTwo() {
    #expect(status("echo (") == 2)
}

@Test func failingSubstitutionsGiveTheirStatus() throws {
    // Without `try`, a failure is just what `.status` says.
    #expect(
        try output("let x = $(sh -c 'echo partial; exit 3'); x.status.code; x.text; echo after")
            == "3\n\"partial\"\nafter\n"
    )
    #expect(try output("echo $(false) x") == " x\n")
    #expect(
        try output("let x = $(echo fine); x")
            == "Output(text: \"fine\", status: Status(code: 0, signal: nil, succeeded: true))\n"
    )
}

@Test func tryMakesASubstitutionThrow() throws {
    #expect(status("let x = try $(false)") == 1)
    #expect(try output("let x = try $(false); echo unreachable") == "")
    #expect(status("let x = try $(sh -c 'exit 3')") == 3)  // the command's own status
    // `try` covers what's to its right, including a command's arguments…
    #expect(try output("try echo $(false) x; echo unreachable") == "")
    // …but not a function's body, which decides for itself.
    #expect(try output("func f() -> Output { $(false) }; let o = try f(); o.status.code") == "1\n")
}

@Test func tryQuestionMark() throws {
    #expect(try output("let x = try? $(false); x == nil") == "true\n")
    #expect(try output(#"(try? $(false))?.text ?? "fallback""#) == "\"fallback\"\n")
    #expect(try output("try? $(grep -q nope /dev/null) != nil || echo missing") == "missing\n")
    #expect(
        try output(#"if let h = try? $(echo hi) { echo "got \(h)" } else { echo none }"#)
            == "got hi\n"
    )
    #expect(
        try output(
            #"if let h = try? $(false) { print(h) } else if let g = try? $(echo second) { print(g) }"#
        )
            == "second\n"
    )
    #expect(status("if let h = try? $(false) { }; h") == 127)  // h is only bound inside: here it's a command
    // Any runtime error, not just a failed command.
    #expect(try output("try? [1][5] == nil; try? 1 / 0 == nil") == "")
    #expect(try output("(try? [1][5]) == nil; (try? 1 / 0) == nil") == "true\ntrue\n")
    #expect(try output("func f() -> Int { [1][9] }; (try? f()) ?? 0") == "0\n")
}

@Test func tryCoversEverythingToItsRight() throws {
    // As in Swift: the `??` is inside the `try?`, so a failure makes it all nil.
    let shell = Shell()
    #expect(try output(#"try? $(false) ?? "fallback""#, in: shell) == "")
    #expect(shell.lastStatus.number == 1)  // nil is a failure
    #expect(
        try output("let y = try $(echo plain); y")
            == "Output(text: \"plain\", status: Status(code: 0, signal: nil, succeeded: true))\n"
    )
}

@Test func tryBangStopsAScript() throws {
    let shell = Shell()
    let path = try output("mktemp", in: shell).trimmingCharacters(in: .newlines)
    shell.execute(
        #"printf '%s\n' 'echo one' 'let a = $(false)' 'echo two' 'let b = try! $(sh -c "exit 4")' 'echo three' > \#(path)"#
    )
    let script = Shell()
    var status: Int32 = 0
    let printed = try script.capturing { status = script.runScript(at: path) }
    // A plain error abandons its statement; `try!` stops the script.
    #expect(printed == "one\ntwo\n")
    #expect(status == 4)
    #expect(Shell().runScript(at: path + ".missing") == 127)
}

@Test func nilCoalescing() throws {
    #expect(try output("nil ?? 1 + 2; 1 ?? 2 == 1; nil ?? nil ?? 3") == "3\ntrue\n3\n")
    #expect(
        try output("func f(name: String? = nil) -> String { name ?? \"anon\" }; f; f --name x")
            == "anon\nx\n"
    )
}

@Test func questionMarksAreLiteral() throws {
    #expect(try output("echo https://example.com/?q=1 a?b") == "https://example.com/?q=1 a?b\n")
}

@Test func catchingAFailedCapture() throws {
    #expect(
        try output(
            #"do { let r = try $(sh -c 'echo partial; exit 3') } catch { if let f = error as? CommandFailure { print(f.status.code); print(f.text) } }"#
        ) == "Optional(3)\npartial\n"
    )
    #expect(
        try output(
            #"do { let r = try $(sh -c 'kill -TERM $$') } catch { if let f = error as? CommandFailure { print(f.status.signal); print(f.status.code == nil) } }"#
        ) == "Optional(15)\ntrue\n"
    )
    // Without `try`, nothing throws, so the catch doesn't run.
    #expect(try output(#"do { let r = $(false) } catch { echo never }; echo done"#) == "done\n")
}

@Test func catchingAnyRuntimeError() throws {
    #expect(
        try output("do { 1 / 0 } catch let e { print(e.localizedDescription) }")
            == "division by zero\n"
    )
    #expect(try output("do { echo fine } catch { echo never }") == "fine\n")
    #expect(try output("do { let x = 1; print(x) }") == "1\n")  // do alone is a scope
    #expect(status("do { 1 / 0 }") == 1)  // no catch: still an error
}

@Test func tryMakesACommandThrow() throws {
    #expect(
        try output(
            "do { try sh -c 'exit 4' } catch { if let failure = error as? CommandFailure { echo \"failed with \\(failure.status.code)\" } }"
        ) == "failed with 4\n"
    )
    #expect(try output("try false; echo unreachable") == "")
    #expect(try output("try true && echo ok") == "ok\n")
    #expect(status("try? make") == 2)  // try? needs a value: a syntax error
}

@Test func tryBangCommandStopsAScript() throws {
    let shell = Shell()
    let path = try output("mktemp", in: shell).trimmingCharacters(in: .newlines)
    shell.execute(
        #"printf '%s\n' 'echo one' 'false' 'echo two' 'try! sh -c "exit 5"' 'echo three' > \#(path)"#
    )
    let script = Shell()
    var code: Int32 = 0
    #expect(try script.capturing { code = script.runScript(at: path) } == "one\ntwo\n")
    #expect(code == 5)
}

@Test func aCaughtErrorIsAnErrorUntilCast() throws {
    // As in Swift: `error` tells what went wrong, and a cast gets at more.
    #expect(
        try output("do { 1 / 0 } catch { print(error.localizedDescription) }")
            == "division by zero\n"
    )
    #expect(status("do { 1 / 0 } catch { error.status }") == 2)  // no `status` on an Error
    #expect(status("do { 1 / 0 } catch { error.message }") == 2)
    // A plain runtime error isn't a command failure; a failed `try $(…)` is.
    #expect(try output("do { 1 / 0 } catch { print(error as? CommandFailure == nil) }") == "true\n")
    #expect(
        try output(
            #"do { try $(sh -c 'echo no >&2; exit 2') } catch { if let f = error as? CommandFailure { print(f.status.code); print(f.localizedDescription) } }"#
        )
            == "Optional(2)\n$(…) failed with status 2\n"
    )
}
