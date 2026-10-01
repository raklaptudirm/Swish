@testable import SwishCore
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

@Test func helpListsEveryFunction() throws {
    let listing = try output("help")
    #expect(listing.hasPrefix("name "))
    let source = { (name: String) in try output(#"help | filter { $0.name == "\#(name)" } | prefix 1 | get source"#) }
    #expect(try source("ls") == "builtin\n")
    #expect(try source("cd") == "shell\n")
    // A sequence's methods are members, under `help Array`; the shell's own
    // functions, whose names can't be written, aren't listed.
    #expect(try source("sorted") == "")
    #expect(try output(#"help | filter { $0.name.hasPrefix("$") } | count"#) == "0\n")
    // Records, so the usual tools work on them; yours are listed too.
    let mine = "/// Says hi.\nfunc hi(_ name: String) {}\n"
    #expect(try output(mine + #"help | filter { $0.source == "yours" } | get usage"#) == "hi(_ name: String)\n")
    #expect(try output(mine + #"help | filter { $0.name == "hi" } | get summary"#) == "Says hi.\n")
    // One row a name, with each overload's usage.
    #expect(try output(#"help | filter { $0.name == "help" } | count"#) == "1\n")
    #expect(try output(#"func f(_ a: Int) {}; func f(_ a: String) {}; help | filter { $0.name == "f" } | get usage"#)
        == "f(_ a: Int) or f(_ a: String)\n")
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

@Test func helpShowsWhatATypeHas() throws {
    // A Swift type's members, with Swift's own documentation.
    let filePath = try output("help FilePath")
    #expect(filePath.hasPrefix("Swift type FilePath\n"))
    #expect(filePath.contains("  extension: String? { get set }"))
    #expect(filePath.contains("lastComponent: FilePath.Component?") && filePath.contains("Returns the final component of the path."))
    // A sequence has the shell's additions too.
    #expect(try output("help Array").contains("  select(_ fields: String...) -> [Any]"))
    // Yours, from their declarations.
    let shell = Shell()
    _ = try output("struct P { var x: Int; func twice() -> Int { x * 2 } }; enum K { case a, b(n: Int) }", in: shell)
    #expect(try output("help P", in: shell) == "struct P\n\nInitializers:\n  init(x: Int)\n\nProperties:\n  var x: Int\n\nMethods:\n  twice() -> Int\n")
    #expect(try output("help K", in: shell) == "enum K\n\nCases:\n  case a\n  case b(n: Int)\n")
}

@Test func membersDescribesEachItemsType() throws {
    // Its own fields, then what its type has, as `help` shows it.
    #expect(try output("struct P { var x: Int; func twice() -> Int { x * 2 } }; [P(x: 1)] | members | get name") == "x\ntwice\n")
    #expect(try output(#""a" | members | filter { $0.name == "uppercased" } | get kind"#) == "method\n")
}
