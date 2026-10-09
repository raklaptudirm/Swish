@testable import SwishCore
@testable import SwishShell
import SwishKit
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

@Test func configLivesInTheXDGConfigDirectories() {
    // Only the files that exist count, in the spec's order.
    func path(_ environment: [String: String], existing: Set<String>) -> String? {
        Shell.configPath(environment: environment, exists: existing.contains)
    }
    let home = "/h/.config/swish/config.swish"
    #expect(path(["HOME": "/h"], existing: [home]) == home)
    #expect(path(["HOME": "/h"], existing: []) == nil)
    #expect(path(["HOME": "/h", "XDG_CONFIG_HOME": "/c"], existing: [home, "/c/swish/config.swish"]) == "/c/swish/config.swish")
    #expect(path(["HOME": "/h", "XDG_CONFIG_HOME": "relative"], existing: [home]) == home)
    // Then the system's: $XDG_CONFIG_DIRS, or /etc/xdg.
    #expect(path(["HOME": "/h"], existing: ["/etc/xdg/swish/config.swish"]) == "/etc/xdg/swish/config.swish")
    #expect(path(["HOME": "/h", "XDG_CONFIG_DIRS": "/a:rel:/b"], existing: ["/b/swish/config.swish"]) == "/b/swish/config.swish")
    // $SWISH_CONFIG picks one outright, or none when it's empty.
    #expect(path(["HOME": "/h", "SWISH_CONFIG": "/mine.swish"], existing: [home]) == "/mine.swish")
    #expect(path(["HOME": "/h", "SWISH_CONFIG": ""], existing: [home]) == nil)
}

@Test func promptFunctions() throws {
    let shell = Shell()
    #expect(try shell.customPrompt() == nil)
    _ = try output(#"func prompt() -> String { "plain> " }"#, in: shell)
    #expect(try shell.customPrompt() == "plain> ")
    // One told the last status wins over one that isn't, and leaves the status as it was.
    _ = try output(#"func prompt(status: Int) -> String { "[\(status)]> " }; false"#, in: shell)
    #expect(try shell.customPrompt() == "[1]> ")
    #expect(shell.lastStatus == 1)

    let wrong = Shell()
    _ = try output("func prompt(_ n: Int) -> Int { n }", in: wrong)
    #expect(throws: RuntimeError.self) { try wrong.customPrompt() }
}

@Test func styledTextIsPlainOffATerminal() throws {
    #expect(try output(#""x".styled(.red, .bold); let c = true ? TextStyle.green : .red; "y".styled(c) + "!""#) == "\"x\"\n\"y!\"\n")
}
