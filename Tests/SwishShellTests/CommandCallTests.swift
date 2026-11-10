import Swiit
import Testing

@testable import SwishShell

// A function called as a command: binding its words, flags, overloads and help.

/// Runs `source` in `shell`, returning what it wrote to standard output.
private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    return shell.lastStatus.number
}

private let greet =
    #"func greet(_ name: String, times: Int = 1, loud: Bool = false) { var word = "hi"; if loud { word = "HI" }; for _ in 1...times { echo "\(word) \(name)" } };"#

@Test func commandModeBinding() throws {
    let f =
        #"func f(_ a: String, count: Int = 0, dryRun: Bool = false, color: Bool = true, include: [String]) -> String { "\(a) \(count) \(dryRun) \(color) \(include)" };"#
    #expect(
        try output(f + "f x --count 3 --dry-run --no-color --include a --include=b")
            == "x 3 true false [\"a\", \"b\"]\n"
    )
    #expect(try output(f + "f --count=2 -- --x") == "--x 2 false true []\n")
}

@Test func commandModeNumbersAndVariadics() throws {
    #expect(try output("func add(_ a: Int, _ b: Int) -> Int { a + b }; add 2 -5") == "-3\n")
    #expect(
        try output(
            "func sum(_ xs: Double...) -> Double { var t = 0.0; for x in xs { t = t + x }; return t }; sum 1 2.5"
        ) == "3.5\n"
    )
}

@Test func commandModeErrors() {
    let f = "func f(_ n: Int, name: String) {};"
    #expect(status(f + "f 1") == 2)  // missing --name
    #expect(status(f + "f abc --name x") == 2)  // not an Int
    #expect(status(f + "f 1 --name x --bogus") == 2)  // unknown option
    #expect(status(f + "f 1 2 --name x") == 2)  // extra positional
    #expect(status(f + "f 1 --name") == 2)  // flag without a value
    #expect(status(f + "f 1 --name x -v") == 2)  // no short flags
}

@Test func functionsInPipelinesAndSubstitutions() throws {
    #expect(try output(greet + "greet Rak --times 2 | tr a-z A-Z") == "HI RAK\nHI RAK\n")
    #expect(try output(greet + #"let s = $(greet Rak --loud); echo "[\(s)]""#) == "[HI Rak]\n")
    #expect(try output(greet + "^greet Rak; foreign greet Rak") == "")  // no external named greet
}

@Test func boolResultsAreStatuses() throws {
    let isBig = "func isBig(_ n: Int) -> Bool { n > 10 };"
    #expect(try output(isBig + "isBig 50 && echo big; isBig 5 || echo small") == "big\nsmall\n")
}

@Test func shortFlags() throws {
    let f =
        #"func f(@flag("n") times: Int = 1, @flag("v") verbose: Bool = false, @flag("q") quiet: Bool = false) -> String { "\(times) \(verbose) \(quiet)" };"#
    #expect(
        try output(f + "f -n 3; f -n3 -vq; f -qv --times=2")
            == "3 false false\n3 true true\n2 true true\n"
    )
    #expect(status(f + "f -x") == 2)
    #expect(status(f + "f -vx") == 2)
}

@Test func negativeNumbersVersusShortFlags() throws {
    #expect(
        try output(
            #"func f(_ x: Int, @flag("5") five: Bool = false) -> String { "\(x) \(five)" }; f -5 -3"#
        )
            == "-3 true\n"
    )
}

@Test func overloads() throws {
    let byType =
        #"func f(_ x: Int) -> String { "int" }; func f(_ x: String) -> String { "string" };"#
    #expect(
        try output(byType + "f 5; f abc; f(5); f(\"a\")") == "int\nstring\n\"int\"\n\"string\"\n"
    )
    let byLabel = #"func f(a: Int) -> String { "a" }; func f(b: Int) -> String { "b" };"#
    #expect(try output(byLabel + "f --b 1; f(a: 2)") == "b\n\"a\"\n")
    #expect(
        try output(
            #"func f(_ x: Double) -> String { "double" }; func f(_ x: Int) -> String { "int" }; f(5); f(5.5)"#
        )
            == "\"int\"\n\"double\"\n"
    )
}

@Test func redeclaringReplaces() throws {
    #expect(try output("func f() -> Int { 1 }; func f() -> Int { 2 }; f()") == "2\n")
}

@Test func overloadErrors() {
    #expect(status("func g(_ x: Int, _ y: Int) {}; func g(_ s: String) {}; g 1 2 3") == 2)
    #expect(status("func g(a: Int) {}; func g(b: Int) {}; g(c: 1)") == 2)
    #expect(
        status(
            #"func g(_ x: Int, y: Int = 0) -> Int { 1 }; func g(_ x: Int, z: Int = 0) -> Int { 2 }; g(1)"#
        ) == 2
    )  // ambiguous
}

@Test func generatedHelp() throws {
    let source = """
        /// Greets someone.
        /// - Parameter name: who to greet
        func greet(_ name: String, @flag("n") times: Int = 1, color: Bool = true, tags: [String]) {}
        greet --help
        """
    #expect(
        try output(source) == """
            Greets someone.

            Usage:
              greet [--times <Int>] [--no-color] [--tags <String>] <name>

            Arguments:
              <name>               who to greet (String)

            Options:
              -n, --times <Int>    (default: 1)
                  --[no-]color     (default: true)
                  --tags <String>  (repeatable)
              -h, --help           Show this help

            """
    )
}

@Test func helpCanBeClaimed() throws {
    #expect(try output(#"func f(help: Bool = false) -> Bool { help }; f --help"#) == "true\n")
    #expect(try output(#"func f() {}; f -- --help"#) == "")
}

@Test func which() throws {
    let text = try output("func greet(_ name: String) {}; which greet cd prefix cat")
    #expect(
        text.hasPrefix(
            "greet: function greet(_ name: String)\ncd: shell builtin\nprefix: sequence method prefix(_ maxLength: Int) -> ThrowingStream\n/"
        )
    )
    #expect(text.hasSuffix("/cat\n"))
    #expect(status("which surely-not-a-command") == 1)
}
