@testable import SwishCore
import Testing

private func output(_ source: String, in shell: Shell) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

/// The example plugin, `Examples/Tools`, from this file's path.
private let tools = "/" + #filePath.split(separator: "/").dropLast(3).joined(separator: "/") + "/Examples/Tools"

// One test, so the package builds once rather than from tests running in
// parallel. The first run builds it (and SwishKit) in release mode.
@Test func importingAPlugin() throws {
    let shell = Shell()
    #expect(try output(#"import Tools from "\#(tools)""#, in: shell) == "")

    // Functions, from Swift and command-line syntax, with flags and defaults.
    #expect(try output(#"greet("Rak", times: 2); greet Rak -n 2 --loud"#, in: shell)
        == #"["hello Rak", "hello Rak"]"# + "\nHELLO RAK\nHELLO RAK\n")
    // `@Input`: per item, and the whole stream for a list.
    #expect(try output("seq 3 | double; [\"a\", \"abc\", \"ab\"] | longest", in: shell) == "2\n4\n6\nabc\n")
    // Enums, by case name on the command line or `.case` by context.
    #expect(try output("volume high; volume(.high); volume(); Level.low", in: shell) == "11\n11\n1\nLevel.low\n")
    // Encodable results are records.
    #expect(try output(#"words(["b a b"]) | get word"#, in: shell) == "b\na\n")
    // A live object: properties, methods, and its fields when shown.
    #expect(try output(#"let c = counter("x"); c.add(); c.add(5); c.total; c"#, in: shell)
        == "1\n6\n6\n" + #"Counter(total: 6, name: "x")"# + "\n")
    // The module holds what it exports.
    #expect(try output("Tools.volume(.low); Tools", in: shell) == "1\nmodule Tools\n")

    // Errors: thrown by the plugin, and arguments of the wrong type.
    #expect(try output(#"do { try fail("nope") } catch { error.message }"#, in: shell) == #""fail: nope""# + "\n")
    // A wrong argument is found before anything runs, like any type error.
    _ = try output("greet(5)", in: shell)
    #expect(shell.lastStatus == 2)

    // Help from the signature and doc comment; a default only Swift knows.
    let help = try output("greet --help; counter --help", in: shell)
    #expect(help.contains("Greets someone."))
    #expect(help.contains("-n, --times <Int>  how many times to greet (default: 1)"))
    #expect(help.contains("--since <Date>  (default: Date())"))

    // Importing again does nothing; from elsewhere, it's an error.
    #expect(try output(#"import Tools from "\#(tools)""#, in: shell) == "")
    #expect(try output(#"do { import Tools from "/tmp" } catch { error.message }"#, in: shell).contains("already imported from"))

    // A clash with a function of the same signature binds nothing.
    let other = Shell()
    let clash = #"func greet(_ name: String, times: Int = 1, loud: Bool = false) {}; do { import Tools from "\#(tools)" } catch { error.message }"#
    #expect(try output(clash, in: other) == #""import Tools: greet(_ name: String, times: Int, loud: Bool) is already defined""# + "\n")
    #expect(other.lookup("volume") == nil && other.lookup("Tools") == nil)

    #expect(try output(#"do { import Nope from "/nonexistent" } catch { error.message }"#, in: other)
        == #""import Nope: no Swift package at /nonexistent (no Package.swift)""# + "\n")
}
