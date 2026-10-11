@_spi(Layer) import Swiit
@_spi(Shell) @_spi(Layer) @testable import SwishShell
import Foundation
import SwiitKit
import Testing

// The shell's syntax under the SwiftSyntax front end: the hand-written parser,
// with the same plug-in, is the oracle.

/// Programs harvested from the test suites, which Swiit's own tests keep.
private func harvested() throws -> [String] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/Swiit/Tests/SwiitTests/programs.txt")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\u{1E}", omittingEmptySubsequences: true).map(String.init)
}

@Test func theSwiftSyntaxFrontEndReadsTheShellsSyntaxAsTheOracleDoes() throws {
    let shell = Shell()
    let bound = shell.interpreter.globalNames()
    var readable = 0, agree = 0, unsupported: [String: Int] = [:], wrong: [String] = []
    for source in try harvested() {
        guard let oracle = try? Parser.parse(source, bound: bound, plugin: ShellSyntax()) else { continue }
        readable += 1
        do {
            let lowered = try SwiftSyntaxFrontEnd().parse(source, bound: bound, plugin: ShellSyntax())
            if lowered == oracle { agree += 1 } else { wrong.append(source) }
        } catch {
            let reason = "\(error)".replacingOccurrences(of: #" \(line \d+\)"#, with: "", options: .regularExpression)
            unsupported[reason, default: 0] += 1
        }
    }
    for source in wrong.prefix(30) {
        let oracle = SwiftPrinter().source(try Parser.parse(source, bound: bound, plugin: ShellSyntax())).split(separator: "\n", omittingEmptySubsequences: false)
        let lowered = SwiftPrinter().source(try SwiftSyntaxFrontEnd().parse(source, bound: bound, plugin: ShellSyntax())).split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0
        while index < min(oracle.count, lowered.count), oracle[index] == lowered[index] { index += 1 }
        print("DIFFERS: \(source.prefix(70).replacingOccurrences(of: "\n", with: "\\n"))\n   oracle: \(index < oracle.count ? String(oracle[index]) : "(ends)")\n   swiftsyntax: \(index < lowered.count ? String(lowered[index]) : "(ends)")")
    }
    print("harvested programs the oracle reads: \(readable); agree \(agree); unsupported \(unsupported.values.reduce(0, +)); wrong \(wrong.count)")
    for (reason, count) in unsupported.sorted(by: { $0.value > $1.value }).prefix(25) { print("  \(count) × \(reason)") }
    #expect(unsupported.isEmpty, "\(unsupported.values.reduce(0, +)) programs aren't read")
    #expect(wrong.isEmpty, "\(wrong.count) programs differ, the first: \(wrong.first ?? "")")
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

@Test func theSwiftSyntaxFrontEndColorsAsTheOracleDoes() throws {
    let shell = Shell()
    let bound = shell.interpreter.globalNames()
    var same = 0, differ: [(String, String)] = []
    for source in try harvested() {
        guard (try? Parser.parse(source, bound: bound, plugin: ShellSyntax())) != nil else { continue }
        guard (try? SwiftSyntaxFrontEnd().parse(source, bound: bound, plugin: ShellSyntax())) != nil else { continue }
        let length = source.count
        let oracle = painted(HandWrittenFrontEnd().highlight(source, bound: bound, plugin: ShellSyntax()), length: length)
        let colored = painted(SwiftSyntaxFrontEnd().highlight(source, bound: bound, plugin: ShellSyntax()), length: length)
        if oracle == colored { same += 1; continue }
        let characters = Array(source)
        let index = oracle.indices.first { oracle[$0] != colored[$0] }!
        let word = String(characters[max(0, index - 12)..<min(length, index + 12)])
        differ.append((source, "at \(index) …\(word)…: oracle \(oracle[index].map { "\($0)" } ?? "plain"), swiftsyntax \(colored[index].map { "\($0)" } ?? "plain")"))
    }
    for (source, why) in differ.prefix(40) {
        print("COLORS DIFFER: \(source.prefix(60).replacingOccurrences(of: "\n", with: "\\n"))\n   \(why.replacingOccurrences(of: "\n", with: "\\n"))")
    }
    print("programs both read: \(same + differ.count); colored the same \(same); differ \(differ.count)")
    #expect(differ.isEmpty)
}

@Test func aCommentAfterACommandIsNotOne() throws {
    let bound = Shell().interpreter.globalNames()
    let source = "try! swift build\n// a comment\nlet x = 1\nx"
    #expect(try SwiftSyntaxFrontEnd().parse(source, bound: bound, plugin: ShellSyntax()) == Parser.parse(source, bound: bound, plugin: ShellSyntax()))
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

/// The prelude, read through SwiftSyntax, is the tree the hand-written parser
/// gives it: the oracle, for the shell's whole prelude, until it is deleted.
@Test func thePreludeReadsAsTheOracleDoesIt() throws {
    let shell = Shell()
    let bound = Dictionary(uniqueKeysWithValues: Bridge.types.keys.map { ($0, NameKind.type) })
    let source = shell.interpreter.preludeSource
    let oracle = try Parser.parsePrelude(source, bound: bound)
    let lowered = try SwiftSyntaxFrontEnd().parsePrelude(source, bound: bound)
    #expect(oracle.statements.count == lowered.statements.count)
    for (expected, actual) in zip(oracle.statements, lowered.statements) where expected != actual {
        Issue.record("the prelude differs at \(String(reflecting: expected).prefix(200)) vs \(String(reflecting: actual).prefix(200))")
    }
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
/// character. A change is a decision, not an accident; `UPDATE_GOLDENS=1`
/// writes the file again from the front end as it is.
@Test func theShellsSyntaxReadsAsTheHandWrittenParserDid() throws {
    let shell = Shell()
    let bound = shell.interpreter.globalNames()
    let programs = try harvested()
    if ProcessInfo.processInfo.environment["UPDATE_GOLDENS"] != nil {
        var records: [String] = []
        for (index, source) in programs.enumerated() {
            guard let oracle = try? Parser.parse(source, bound: bound, plugin: ShellSyntax()) else { continue }
            let colors = painted(HandWrittenFrontEnd().highlight(source, bound: bound, plugin: ShellSyntax()), length: source.count)
            records.append("\(index)\u{1F}\(SwiftPrinter().source(oracle))\u{1F}\(String(colors.map(letter)))")
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
        guard let lowered = try? SwiftSyntaxFrontEnd().parse(source, bound: bound, plugin: ShellSyntax()) else {
            wrongTree.append("#\(index) not read:\n\(source.prefix(120))")
            continue
        }
        if SwiftPrinter().source(lowered) != String(parts[1]) { wrongTree.append("#\(index):\n\(source.prefix(120))") }
        let colors = painted(SwiftSyntaxFrontEnd().highlight(source, bound: bound, plugin: ShellSyntax()), length: source.count)
        if String(colors.map(letter)) != String(parts[2]) { wrongColors.append("#\(index):\n\(source.prefix(120))") }
    }
    #expect(wrongTree.isEmpty, "\(wrongTree.count) trees differ:\n\(wrongTree.prefix(5).joined(separator: "\n---\n"))")
    #expect(wrongColors.isEmpty, "\(wrongColors.count) colorings differ:\n\(wrongColors.prefix(5).joined(separator: "\n---\n"))")
}
