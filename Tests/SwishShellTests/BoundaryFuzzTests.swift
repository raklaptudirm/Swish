import Foundation
import Swiit
@testable import SwishShell
import Testing

// Swish's text is Swift's with the shell's in it (`$(…)`, commands, `async`), and SwiftParser is what finds where each
// begins and ends. A program built from pieces that each print one marker must print every marker, in order, whatever
// surrounds each piece: a statement the boundary loses is a script that does half its work and says nothing.

struct Generator {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}

/// A statement (or a few, on one line) that prints `m<k>` once.
func piece(_ k: Int, _ choice: Int) -> String {
    let m = "m\(k)"
    let pieces = [
        "print(\"\(m)\")",
        "echo \(m)",
        "let a\(k) = $(echo \(m)); print(a\(k))",
        "let a\(k) = $(echo \(m) | map { $0 }); print(a\(k))",
        "print($(echo \(m) | map { $0 + \"\" }))",
        "let a\(k) = $(echo \(m) | map { \"\\($0)\" }); print(a\(k))",
        "let a\(k) = $(echo \(m)); echo $a\(k)",
        "if true { print(\"\(m)\") }",
        "for _ in 1...1 { echo \(m) }",
        "func f\(k)() { print(\"\(m)\") }; f\(k)()",
        "let t\(k) = async { print(\"\(m)\") }; await t\(k)",
        "print(\"\(m)\") // a (comment) with { braces } and $(a substitution)\n",
        "let n\(k) = [1, 2].map { $0 * 2 }; print(\"\(m)\")",
        "let b\(k) = $(echo \(m) | map { $0 }) ?? \"\"; print(b\(k))",
        "let c\(k) = [$(echo \(m))].map { $0.text }; print(c\(k)[0])",
        "echo \(m) | map { $0 } | filter { true }",
        "let d\(k) = ($(echo \(m)) as Output).text; print(d\(k))",
        "let e\(k) = $(echo $(echo \(m))); print(e\(k))",
        "let f\(k) = $(echo \(m) | map { _ in \"}\" + \")\" }); print(\"\(m)\")",
        "print(\"\\($(echo \(m)))\")",
        "let g\(k) = $(\n    echo \(m)\n); print(g\(k))",
        "let h\(k) = $(echo \(m)).lines.first ?? \"\"; print(h\(k))",
        "[1].forEach { _ in print(\"\(m)\") }",
        "let i\(k) = try? $(echo \(m)); print(i\(k)?.text ?? \"\")",
        "while true { echo \(m); break }",
        "switch 1 { case 1: let j\(k) = $(echo \(m) | map { $0 }); print(j\(k)); default: break }",
        "if let l\(k) = Optional($(echo \(m) | map { $0 })) { print(l\(k)) }",
        "let o\(k) = [\"x\"].map { _ in $(echo \(m)).text }; print(o\(k)[0])",
        "echo \(m) e> /dev/null",
        "true && echo \(m)",
        "false || echo \(m)",
        "echo \(m) |\n  map { $0 }",
        "do { let z\(k) = try $(echo \(m)); print(z\(k)) } catch { print(\"error\") }",
        "let s\(k) = \"}\"; print(\"\(m)\")",
        "echo \(m) > /tmp/swish-fuzz-\(k); cat /tmp/swish-fuzz-\(k)",
        "SWISH_FUZZ=1 echo \(m)",
        "let u\(k) = { (x: Int) in print(\"\(m)\") }; u\(k)(1)",
        "repeat { echo \(m) } while false",
        "outer: for _ in 1...1 { for _ in 1...1 { echo \(m); break outer } }",
        "let v\(k) = $(echo \(m)); if v\(k).text == \"\(m)\" { echo $v\(k) }",
        "let w\(k) = $(echo a; echo \(m) | grep \(m)); print(w\(k).lines.last ?? \"\")",
        "let x\(k) = ls /nonexistent_swish e> /dev/null ?? $(echo \(m)); echo \(m)",
    ]
    return pieces[choice % pieces.count]
}

let pieceCount = 41

func wrap(_ body: String, in context: Int) -> String {
    switch context % 8 {
    case 0: body
    case 1: "func main() {\n\(body)\n}\nmain()"
    case 2: "if true {\n\(body)\n}"
    case 3: "{\n\(body)\n}()"
    case 6: "let t = async {\n\(body)\n}\nawait t"
    case 7: "func go(_ work: () -> Void) { work() }\ngo {\n\(body)\n}"
    case 4: "do {\n\(body)\n}"
    default: "for _ in 1...1 {\n\(body)\n}"
    }
}

let separators = ["; ", "\n", "\n\n", " ;\n", ";\n", "\n  "]

private func run(_ source: String) throws -> String {
    let shell = Shell()
    return try onLargeStack { try shell.capturing { shell.execute(source) } }
}

/// How many programs to try: a hundred and fifty as part of the suite; `SWISH_FUZZ=3000` for a long run.
private let programs = ProcessInfo.processInfo.environment["SWISH_FUZZ"].flatMap(Int.init) ?? 150

@Test func everyPieceOfAProgramRunsWhateverIsAroundIt() throws {
    var generator = Generator(state: 20_261_016)
    var failures: [(source: String, expected: String, actual: String)] = []
    for _ in 0..<programs {
        let count = 2 + generator.next(3)
        let choices = (0..<count).map { _ in generator.next(pieceCount) }
        let separator = separators[generator.next(separators.count)]
        let context = generator.next(8)
        let body = choices.enumerated().map { piece($0.offset, $0.element) }.joined(separator: separator)
        // One time in three, inside another block as well.
        let outer = generator.next(8)
        // One time in three, inside another block as well.
        let source = generator.next(3) == 0 ? wrap(wrap(body, in: context), in: outer) : wrap(body, in: context)
        let expected = (0..<count).map { "m\($0)\n" }.joined()
        let actual = (try? run(source)) ?? "<threw>"
        if actual != expected { failures.append((source, expected, actual)) }
    }
    // The smallest failing programs say the most.
    for failure in failures.sorted(by: { $0.source.count < $1.source.count }).prefix(12) {
        Issue.record("\n--- program\n\(failure.source)\n--- expected\n\(failure.expected)--- got\n\(failure.actual)")
    }
    #expect(failures.isEmpty, "\(failures.count) of \(programs) programs lost something")
}

@Test func blocksNestedInTheBlocksOfALayerStillReadTheirFirstCommand() throws {
    // A command-style call's closure, or a task's, holding another: each window of the source that is read ends mid-block
    // until the last, and the layer's "ran out of text" must win over what SwiftParser makes of the unfinished text.
    #expect(try run("let t = async {\nlet u = async {\necho m0\necho m1\n}\nawait u\n}\nawait t\n") == "m0\nm1\n")
    #expect(try run("func go(_ w: () -> Void) { w() }\ngo {\ngo {\necho m0\necho m1\n}\n}\n") == "m0\nm1\n")
    #expect(try run("func go(_ w: () -> Void) { w() }\ngo {\nlet t = async {\necho m0\necho m1\n}\nawait t\n}\n") == "m0\nm1\n")
    #expect(try run("let t = async {\n{\necho m0\necho m1\n}()\n}\nawait t\n") == "m0\nm1\n")
}

@Test func whatIsLeftOpenByTheWindowIsNotAnError() throws {
    // Blank lines, comments and a pipe at the end of a line, inside a closure of a command-style call.
    let source = "func go(_ w: () -> Void) { w() }\ngo {\n\n  echo m0 |\n    map { $0 } // x\n\n  let g = $(\n    echo m1\n  ); print(g)\n\n}\n"
    #expect(try run(source) == "m0\nm1\n")
    // And a real mistake is still reported, where it is.
    let shell = Shell()
    #expect(throws: Diagnostic.self) { try shell.interpreter.check("func go(_ w: () -> Void) { w() }\ngo {\n  let x = (1 +\n}\n") }
}

@Test func labeledLoopsAndRepeatLoopsHoldCommands() throws {
    #expect(try run("outer: for _ in 1...2 { for _ in 1...2 { echo a; continue outer } }\nvar n = 0\nrepeat { n += 1; echo b } while n < 2") == "a\na\nb\nb\n")
}

@Test func aClosureThatCatchesWhatItTriesDoesNotThrow() throws {
    #expect(try run("let h = { do { try $(false) } catch { print(\"e\") } }; h()") == "e\n")
}
