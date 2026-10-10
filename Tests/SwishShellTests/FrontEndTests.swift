@_spi(Shell) import Swiit
@_spi(Shell) import SwiitSwiftSyntax
@_spi(Shell) @testable import SwishShell
import Foundation
import SwishKit
import Testing

// The shell's syntax under the SwiftSyntax front end: the hand-written parser,
// with the same plug-in, is the oracle.

/// Programs harvested from the test suites, which Swiit's own tests keep.
private func harvested() throws -> [String] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/Swiit/Tests/SwiitSwiftSyntaxTests/programs.txt")
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
