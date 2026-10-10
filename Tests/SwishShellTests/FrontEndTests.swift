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
    // A ratchet: the programs it can't read yet (mostly a shell word SwiftParser stops at) only go down.
    #expect(unsupported.values.reduce(0, +) <= 46, "more programs are unsupported than before")
    #expect(wrong.isEmpty, "\(wrong.count) programs differ, the first: \(wrong.first ?? "")")
}
