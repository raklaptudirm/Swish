@_spi(Shell) import Swiit
@_spi(Shell) @testable import SwishShell
import SwishKit
import Testing

// The library a command statement means (Docs/Design/desugaring.md), called by
// hand: `Command(…).run()` gives a Status, `a && b || c` is
// `a.and { b }.or { c }`, and `output()` is `$(…)`.

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    return shell.lastStatus
}

@Test func aCommandRunsAndGivesItsStatus() throws {
    #expect(try output(#"let s = Command("echo", "hi").run(); print(s.succeeded)"#) == "hi\ntrue\n")
    #expect(try output(#"let s = Command("sh", "-c", "exit 3").run(); print(s.code); print(s.succeeded)"#) == "3\nfalse\n")
    #expect(try output(#"let s = Command("sh", "-c", "kill -TERM $$").run(); print(s.signal); print(s.code == nil)"#) == "15\ntrue\n")
}

@Test func aStatusIsTheStatementsStatus() {
    // Bare, it sets the status and shows nothing.
    #expect(status(#"Command("true").run()"#) == 0)
    #expect(status(#"Command("sh", "-c", "exit 4").run()"#) == 4)
    #expect(status(#"Command("nope-not-a-program").run()"#) == 127)
}

@Test func aCommandsOutputIsWhatSubstitutionGives() throws {
    #expect(try output(#"let o = Command("echo", "hi").output(); print(o.text); print(o.status.succeeded)"#) == "hi\ntrue\n")
    #expect(try output(#"let o = Command("sh", "-c", "echo partial; exit 2").output(); print(o.text); print(o.status.code)"#) == "partial\n2\n")
}

@Test func theWordsAreTakenAsTheyAre() throws {
    // No `~`, `$name` or glob: that is what `Words` will do.
    #expect(try output(#"Command("echo", "*.swift", "$HOME", "~").run(); print(Command("echo", "a b").words.count)"#) == "*.swift $HOME ~\n2\n")
}

@Test func andAndOrRunOnTheStatusLeftToRight() throws {
    #expect(try output(#"Command("true").run().and { Command("echo", "yes").run() }"#) == "yes\n")
    #expect(try output(#"Command("false").run().and { Command("echo", "no").run() }"#) == "")
    #expect(try output(#"Command("false").run().or { Command("echo", "fallback").run() }"#) == "fallback\n")
    #expect(try output(#"Command("true").run().or { Command("echo", "never").run() }"#) == "")
}

@Test func theStatusChainMeansWhatAndAndOrMean() throws {
    // The same statuses as the shell's own `&&` and `||`, for every combination.
    // (`^name` is the program; a bare `true` is a Bool, which would take a `||` for its own.)
    let commands = [("^true", ["true"]), ("^false", ["false"]), ("sh -c 'exit 3'", ["sh", "-c", "exit 3"])]
    func command(_ words: [String]) -> String {
        "Command(" + words.map { "\"\($0)\"" }.joined(separator: ", ") + ").run()"
    }
    for (a, aWords) in commands { for (b, bWords) in commands { for (c, cWords) in commands {
        let shellWay = status("\(a) && \(b) || \(c)")
        let swiftWay = status("\(command(aWords)).and { \(command(bWords)) }.or { \(command(cWords)) }")
        #expect(shellWay == swiftWay, "\(a) && \(b) || \(c)")
    } } }
}
