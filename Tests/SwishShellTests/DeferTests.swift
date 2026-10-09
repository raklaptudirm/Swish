@testable import SwishCore
@testable import SwishShell
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

@Test func deferRunsWhenTheBlockEnds() throws {
    // Last deferred first, after the rest of the block.
    #expect(try output("func f() { defer { echo one }; defer { echo two }; echo body }; f()") == "body\ntwo\none\n")
    // On return, and when an error leaves the block.
    #expect(try output("func f() -> Int { defer { echo cleanup }; return 1 }; f()") == "cleanup\n1\n")
    #expect(try output("func f() throws { defer { echo cleanup }; try $(false) }; do { try f() } catch { echo caught }") == "cleanup\ncaught\n")
    // Each time round a loop.
    #expect(try output("for i in 1...2 { defer { echo \"end \\(i)\" }; echo \"start \\(i)\" }") == "start 1\nend 1\nstart 2\nend 2\n")
}

@Test func nothingLeavesADefer() throws {
    let shell = Shell()
    _ = try output("func f() -> Int { defer { return 2 }; return 1 }", in: shell)
    #expect(shell.lastStatus == 2) // a syntax error: return outside a function
    _ = try output("func f() throws { defer { try $(false) } }", in: shell)
    #expect(shell.lastStatus == 2)
}

@Test func scriptsKnowWhereTheyAreAndCleanUp() throws {
    let shell = Shell()
    let directory = try output("mktemp -d", in: shell).trimmingCharacters(in: .newlines)
    let script = directory + "/cleanup.swish"
    // A shebang line; #filePath; a top-level defer that runs when the script ends, after main.
    shell.execute(#"printf '%s\n' '#!/usr/bin/env swish' 'defer { rm \#(directory)/marker; echo deferred }' 'touch \#(directory)/marker' 'echo "at \(#filePath)"' 'func main() { echo main }' > \#(script)"#)
    let script2 = Shell()
    let printed = try onLargeStack { try script2.capturing { _ = script2.runScript(at: script) } }
    #expect(printed == "at \(script)\nmain\ndeferred\n")
    #expect(try output("test -e \(directory)/marker && echo left || echo gone", in: shell) == "gone\n")
    #expect(try output("#filePath") == "\"<prompt>\"\n")
}
