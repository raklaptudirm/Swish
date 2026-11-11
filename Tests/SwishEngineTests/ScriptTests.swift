import Swiit
import Testing

@testable import SwishEngine

// Scripts and their surroundings: arguments, `main`, the environment and the status.

/// Runs `source` in `shell`, returning what it wrote to standard output.
private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    return shell.lastStatus.number
}

@Test func environmentVariables() throws {
    #expect(try output("echo $HOME") == (env("HOME") ?? "") + "\n")
}

@Test func environmentValue() throws {
    let name = "SWISH_TEST_\(Int.random(in: 0..<1_000_000))"
    #expect(
        try output(
            "env.\(name) == nil; env.\(name) = \"one two\"; echo $\(name); env[\"\(name)\"]; env.\(name) = nil; env.\(name) == nil"
        ) == "true\none two\n\"one two\"\ntrue\n"
    )
    #expect(try output("env.HOME == \"\(env("HOME")!)\"") == "true\n")
    // `env.NAME` is always the variable NAME, even one called `count`.
    #expect(try output("env.count == nil") == "true\n")
}

@Test func environmentForOneCommand() throws {
    let name = "SWISH_TEST_\(Int.random(in: 0..<1_000_000))"
    #expect(
        try output(#"\#(name)="a b" sh -c 'echo "$\#(name)"'; env.\#(name) == nil"#)
            == "a b\ntrue\n"
    )
    #expect(try output(#"func show() { sh -c 'echo "$\#(name)"' }; \#(name)=fn show"#) == "fn\n")
    #expect(
        try output(
            #"with(env: ["\#(name)": "block"]) { sh -c 'echo "$\#(name)"' }; env.\#(name) == nil"#
        )
            == "block\ntrue\n"
    )
}

@Test func noGlobalStatus() {
    #expect(status("false; status") == 127)  // just a command name now
}

@Test func scriptsGetArgsAndMain() throws {
    let shell = Shell()
    let path = try output("mktemp", in: shell).trimmingCharacters(in: .newlines)
    shell.execute(
        #"printf '%s\n' '/// Greets someone.' 'func main(_ name: String, loud: Bool = false) { if loud { echo "HI \(name)" } else { echo "hi \(name)" } }' 'echo "args \(args.count)"' > \#(path)"#
    )
    let script = Shell()
    var status: Int32 = 0
    #expect(
        try script.capturing { status = script.runScript(at: path, arguments: ["Rak", "--loud"]) }
            == "args 2\nHI Rak\n"
    )
    #expect(status == 0)
    let helper = Shell()
    let help = try helper.capturing { _ = helper.runScript(at: path, arguments: ["--help"]) }
    #expect(help.contains("Greets someone.") && help.contains("[--loud] <name>"))
    let missing = Shell()
    #expect(missing.runScript(at: path) == 1)  // main needs a name
}
