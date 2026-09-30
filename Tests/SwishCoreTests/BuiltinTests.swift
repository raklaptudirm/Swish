@testable import SwishCore
import SwishKit
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

private func status(_ source: String, in shell: Shell = Shell()) -> Int32 {
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    return shell.lastStatus
}

@Test func umaskShowsAndSetsTheMask() throws {
    // It's the whole process's, so it's put back as it was.
    let shell = Shell()
    let before = try output("umask", in: shell)
    #expect(before.count == 5 && before.hasPrefix("0"))
    #expect(try output("umask 027; umask", in: shell) == "0027\n")
    _ = try output("umask \(before)", in: shell)
    #expect(status("umask 999") == 2)
}

@Test func ulimitShowsAndSetsLimits() throws {
    let shell = Shell()
    let files = try output("ulimit -n", in: shell).trimmingCharacters(in: .newlines)
    #expect(UInt64(files) != nil || files == "unlimited")
    // Setting the soft limit to what it is changes nothing for other tests.
    #expect(status("ulimit -S -n \(files)", in: shell) == 0)
    #expect(try output("ulimit -n", in: shell) == files + "\n")
    #expect(try output("ulimit -a", in: shell).contains("open files"))
    #expect(status("ulimit -x") == 2)
    #expect(status("ulimit -n lots") == 2)
}

@Test func otherShellsBuiltinsSayWhatToUseInstead() throws {
    for name in ["alias ll=ls", "export A=1", "wait", "read x", "trap x INT", "set -e", "unset A"] {
        #expect(status(name) == 2)
    }
    #expect(try output("which export umask") == "export: not Swish; `env.NAME = value` sets an environment variable for the programs you run\numask: shell builtin\n")
    // A function of the same name still wins, as for any builtin.
    #expect(try output(#"func read() { echo mine }; read"#) == "mine\n")
}

@Test func sourceRunsAFileInThisShell() throws {
    let shell = Shell()
    let directory = try output("mktemp -d", in: shell).trimmingCharacters(in: .newlines)
    _ = try output(#"""
    "let greeting = \"hi\"\nfunc hello(_ n: String) { echo \"\\(greeting) \\(n) \\(args)\" }\n" | to text > \#(directory)/lib.swish
    """#, in: shell)
    _ = try output("source \(directory)/lib.swish a b", in: shell)
    // What it declared stays; args and #filePath are the shell's again.
    #expect(try output("hello Rak; args; #filePath", in: shell) == "hi Rak []\n[]\n\"<prompt>\"\n")
    #expect(status("source \(directory)/missing.swish") == 127)
}
