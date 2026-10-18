@testable @_spi(Layer) import Swiit
@_spi(Shell) @_spi(Layer) @testable import SwishShell
import Foundation
import Testing

// The shell's syntax under the SwiftSyntax front end. What the hand-written
// parser read with the same plug-in, which it was held to while it existed, is
// kept as goldens (below).

/// Programs harvested from the test suites, which Swiit's own tests keep too (a copy here, so this suite reads nothing outside the repository).
private func harvested() throws -> [String] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/SwishShellTests/programs.txt")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\u{1E}", omittingEmptySubsequences: true).map(String.init)
}

/// The kind each character is painted, as the shell paints spans: longer
/// ones first, so what is inside them is painted over them.
private func painted(_ spans: [Span], length: Int) -> [SpanKind?] {
    var kinds = [SpanKind?](repeating: nil, count: length)
    for span in spans.sorted(by: { $0.range.count > $1.range.count }) {
        for index in span.range.clamped(to: 0..<length) { kinds[index] = span.kind }
    }
    return kinds
}

@Test func aCommentAfterACommandIsNotOne() throws {
    let bound = Shell().interpreter.globalNames()
    let program = try SwiftSyntaxFrontEnd().parse("try! swift build\n// a comment\nlet x = 1\nx", bound: bound, plugin: ShellSyntax())
    // The comment isn't another command's word.
    #expect(program.statements.count == 3)
}

/// Reading a command doesn't read the whole source again: a script of many
/// commands parses in time that grows with it, not with its square.
@Test func manyCommandsParseInLinearTime() throws {
    // The best of a few runs, as other tests share the machine.
    func seconds(_ commands: Int) throws -> Double {
        let source = "func f() {\n" + String(repeating: "    true\n", count: commands) + "}"
        var best = Double.infinity
        for _ in 0..<2 {
            let start = Date()
            _ = try SwiftSyntaxFrontEnd().parse(source, bound: [:], plugin: ShellSyntax())
            best = min(best, Date().timeIntervalSince(start))
        }
        return best
    }
    // Sixteen times the commands: about sixteen times as long, linear; up to
    // 256 times, quadratic (it was over 60).
    let small = try seconds(250), large = try seconds(4000)
    #expect(large / small < 32, "250 commands: \(small)s, 4000: \(large)s")
}

// MARK: What the hand-written parser read, kept

private func letter(_ kind: SpanKind?) -> Character {
    switch kind {
    case nil: "."
    case .keyword?: "k"
    case .command?: "c"
    case .flag?: "f"
    case .string?: "s"
    case .number?: "n"
    case .constant?: "C"
    case .variable?: "v"
    case .comment?: "m"
    case .type?: "t"
    case .punctuation?: "p"
    }
}

private func goldenURL() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Goldens/shell.txt")
}

/// The shell's syntax is held to what the hand-written parser read with the
/// same plug-in (Goldens/shell.txt, made from it before it was deleted): each
/// harvested program's tree, printed back as Swift, and its colors, a letter a
/// character. A change is a decision, not an accident.
@Test func theShellsSyntaxReadsAsTheHandWrittenParserDid() throws {
    let shell = Shell()
    let bound = shell.interpreter.globalNames()
    let programs = try harvested()
    // `UPDATE_GOLDENS=1` writes the file again from the front end as it is.
    if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] != nil {
        var records: [String] = []
        for (index, source) in programs.enumerated() {
            guard let lowered = try? SwiftSyntaxFrontEnd().parse(source, bound: bound, plugin: ShellSyntax()) else { continue }
            let colors = painted(SwiftSyntaxFrontEnd().highlight(source, bound: bound, plugin: ShellSyntax()), length: source.count)
            records.append("\(index)\u{1F}\(SwiftPrinter().source(lowered))\u{1F}\(String(colors.map(letter)))")
        }
        try records.joined(separator: "\u{1E}").write(to: goldenURL(), atomically: true, encoding: .utf8)
    }
    let golden = try String(contentsOf: goldenURL(), encoding: .utf8).split(separator: "\u{1E}", omittingEmptySubsequences: true)
    #expect(golden.count > 500)
    var wrongTree: [String] = [], wrongColors: [String] = []
    for record in golden {
        let parts = record.split(separator: "\u{1F}", maxSplits: 2, omittingEmptySubsequences: false)
        let index = try #require(Int(parts[0]))
        let source = programs[index]
        let lowered: Program
        do {
            lowered = try SwiftSyntaxFrontEnd().parse(source, bound: bound, plugin: ShellSyntax())
        } catch {
            wrongTree.append("#\(index) not read (\(error)):\n\(source.prefix(120))")
            continue
        }
        let printed = SwiftPrinter().source(lowered)
        if printed != String(parts[1]) {
            let expected = parts[1].split(separator: "\n", omittingEmptySubsequences: false), got = printed.split(separator: "\n", omittingEmptySubsequences: false)
            var line = 0
            while line < min(expected.count, got.count), expected[line] == got[line] { line += 1 }
            wrongTree.append("#\(index):\n\(source.prefix(120))\n  kept: \(line < expected.count ? expected[line] : "(ends)")\n  read: \(line < got.count ? got[line] : "(ends)")")
        }
        let colors = painted(SwiftSyntaxFrontEnd().highlight(source, bound: bound, plugin: ShellSyntax()), length: source.count)
        let painting = String(colors.map(letter))
        if painting != String(parts[2]) {
            let kept = Array(parts[2]), got = Array(painting)
            let at = kept.indices.first { kept[$0] != got[$0] } ?? 0
            let characters = Array(source)
            wrongColors.append("#\(index): at \(at) …\(String(characters[max(0, at - 10)..<min(characters.count, at + 14)]))… kept \(kept[at]) read \(got[at])\n\(source.prefix(100))")
        }
    }
    #expect(wrongTree.isEmpty, "\(wrongTree.count) trees differ:\n\(wrongTree.prefix(ProcessInfo.processInfo.environment["GOLDEN_ALL"] != nil ? 400 : 5).joined(separator: "\n---\n"))")
    #expect(wrongColors.isEmpty, "\(wrongColors.count) colorings differ:\n\(wrongColors.prefix(ProcessInfo.processInfo.environment["GOLDEN_ALL"] != nil ? 400 : 5).joined(separator: "\n---\n"))")
}
