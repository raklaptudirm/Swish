@testable import SwishCore
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

@Test func helpListsEveryFunction() throws {
    let listing = try output("help")
    #expect(listing.hasPrefix("name "))
    let source = { (name: String) in try output(#"help | filter { $0.name == "\#(name)" } | get source"#) }
    #expect(try source("ls") == "builtin\n")
    #expect(try source("cd") == "shell\n")
    #expect(try source("sorted") == "Sequence\n")
    // Records, so the usual tools work on them; yours are listed too.
    let mine = "/// Says hi.\nfunc hi(_ name: String) {}\n"
    #expect(try output(mine + #"help | filter { $0.source == "yours" } | get usage"#) == "hi(_ name: String)\n")
    #expect(try output(mine + #"help | filter { $0.name == "hi" } | get summary"#) == "Says hi.\n")
}

@Test func helpShowsOneInFull() throws {
    #expect(try output("help prefix").hasPrefix("The first items; stops reading after them.\n\nUsage:\n  prefix"))
    #expect(try output("help cd") == "Changes the working directory: to <dir>, back to the previous one (-), or home.\n\nUsage:\n  cd [<dir> | -]\n")
    #expect(try output("help sh").hasPrefix("sh is a program, "))
    // A nil default isn't worth saying.
    #expect(!(try output("help help")).contains("default: nil"))
    let shell = Shell()
    _ = try? output("help surely-not-a-command", in: shell)
    #expect(shell.lastStatus == 1)
}

@Test func helpCompletesNames() {
    // Functions, builtins and programs, but not variables.
    let shell = Shell()
    shell.execute("let prefixVariable = 1")
    let names = shell.completions(for: "help pre", cursor: 8)?.candidates.map(\.display) ?? []
    #expect(names.contains("prefix") && !names.contains("prefixVariable"))
}
