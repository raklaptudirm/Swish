@testable import SwishCore
@testable import SwishShell
import SwishKit
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
    #expect(try output("help K", in: shell) == "enum K\n\nCases:\n  case a\n\n  case b(n: Int)\n")
}

@Test func membersDescribesEachItemsType() throws {
    // Its own fields, then what its type has, as `help` shows it.
    #expect(try output("struct P { var x: Int; func twice() -> Int { x * 2 } }; [P(x: 1)] | members | get name") == "x\ntwice\n")
    #expect(try output(#""a" | members | filter { $0.name == "uppercased" } | get kind"#) == "method\n")
}

@Test func signaturesAreColoredByWhatEachPartIs() {
    let shell = Shell()
    func style(_ word: String, in signature: String, of type: String) -> DisplayStyle?? {
        runStyle(of: word, inSignature: signature, ofType: type, shell: shell)
    }
    let initializer = "init(_ description: String)"
    #expect(style("init", in: initializer, of: "Int") == .keyword)
    #expect(style("description", in: initializer, of: "Int") == .variable)
    #expect(style("String", in: initializer, of: "Int") == .type)
    // A property: its keyword, its name, its type.
    let property = "let cpuTime: Double?"
    #expect(style("let", in: property, of: "ProcessEntry") == .keyword)
    #expect(style("cpuTime", in: property, of: "ProcessEntry") == .command)
    #expect(style("Double", in: property, of: "ProcessEntry") == .type)
    // A method: its name, labels, and the types of what it takes and gives.
    let method = "contains(where predicate: (Element) throws -> Bool) -> Bool"
    #expect(style("contains", in: method, of: "Array") == .command)
    #expect(style("where", in: method, of: "Array") == .variable)
    #expect(style("throws", in: method, of: "Array") == .keyword)
    #expect(style("Bool", in: method, of: "Array") == .type)
}

@Test func styledTextIsColoredOnlyWhereItsAskedFor() throws {
    let line = sampleStyledLine()
    #expect(line.plain == "ls [--all]")
    #expect(line.colored == "\u{1B}[32mls\u{1B}[0m [--all]")
    // Piped or captured, help is its plain text, and it's text where a String is.
    #expect(try output("help ls | grep -c Usage") == "1\n")
    #expect(try output(#"help ls | filter { $0.text.hasPrefix("Usage") } | count"#) == "1\n")
}

@Test func documentationIsMarkdown() throws {
    // Code, strong and emphasis show as styles where there are colors…
    let line = documentationLine("Returns `first` or **nothing**, _usually_.")
    #expect(line.colored == "Returns \u{1B}[36mfirst\u{1B}[0m or \u{1B}[1mnothing\u{1B}[0m, \u{1B}[3musually\u{1B}[0m.")
    // …and are just the words anywhere else, as in a man page.
    #expect(line.plain == "Returns first or nothing, usually.")
    // What Markdown doesn't take for its own stays: angle brackets, brackets.
    #expect(documentationLine("to <dir>, or [Element] back").plain == "to <dir>, or [Element] back")
    // A doc comment of your own is read the same way.
    #expect(try output("/// Doubles the `x`, **fast**.\nfunc d(_ x: Int) -> Int { x * 2 }\nhelp d | prefix 1") == "Doubles the x, fast.\n")
}
