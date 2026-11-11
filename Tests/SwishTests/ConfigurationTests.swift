import Swiit
import SwishShell
import Testing

@testable import Swish

// The config file, and the prompt function it may declare.

@Test func configLivesInTheXDGConfigDirectories() {
    // Only the files that exist count, in the spec's order.
    func path(_ environment: [String: String], existing: Set<String>) -> String? {
        Configuration.path(environment: environment, exists: existing.contains)
    }
    let home = "/h/.config/swish/config.swish"
    #expect(path(["HOME": "/h"], existing: [home]) == home)
    #expect(path(["HOME": "/h"], existing: []) == nil)
    #expect(
        path(["HOME": "/h", "XDG_CONFIG_HOME": "/c"], existing: [home, "/c/swish/config.swish"])
            == "/c/swish/config.swish"
    )
    #expect(path(["HOME": "/h", "XDG_CONFIG_HOME": "relative"], existing: [home]) == home)
    // Then the system's: $XDG_CONFIG_DIRS, or /etc/xdg.
    #expect(
        path(["HOME": "/h"], existing: ["/etc/xdg/swish/config.swish"])
            == "/etc/xdg/swish/config.swish"
    )
    #expect(
        path(["HOME": "/h", "XDG_CONFIG_DIRS": "/a:rel:/b"], existing: ["/b/swish/config.swish"])
            == "/b/swish/config.swish"
    )
    // $SWISH_CONFIG picks one outright, or none when it's empty.
    #expect(path(["HOME": "/h", "SWISH_CONFIG": "/mine.swish"], existing: [home]) == "/mine.swish")
    #expect(path(["HOME": "/h", "SWISH_CONFIG": ""], existing: [home]) == nil)
}

@Test func promptFunctions() throws {
    let shell = Shell()
    let prompt = InteractivePrompt(shell: shell)
    #expect(try prompt.customPrompt() == nil)

    shell.execute(#"func prompt() -> String { "plain> " }"#)
    #expect(try prompt.customPrompt() == "plain> ")

    // One told the last status wins over one that isn't, and leaves the status as it was.
    shell.execute(#"func prompt(status: Int) -> String { "[\(status)]> " }; false"#)
    #expect(try prompt.customPrompt() == "[1]> ")
    #expect(shell.lastStatus.number == 1)

    let wrong = Shell()
    wrong.execute("func prompt(_ n: Int) -> Int { n }")
    #expect(throws: PromptError.self) { try InteractivePrompt(shell: wrong).customPrompt() }
}
