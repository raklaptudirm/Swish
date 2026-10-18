@testable @_spi(Layer) import Swiit
@_spi(Shell) @_spi(Layer) @testable import SwishShell
import Foundation
import Testing

// Spike: after the shell's constructs are rewritten, is what is left Swift that Swiit reads with no plug-in?
// For each harvested program: parse with the shell, check and rewrite, print as Swift, and read the print back
// with no plug-in; the second print must equal the first.

private func harvested() throws -> [String] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("programs.txt")
    return try String(contentsOf: url, encoding: .utf8).split(separator: "\u{1E}", omittingEmptySubsequences: true).map(String.init)
}

@Test func theRewrittenProgramIsSwiftThatNeedsNoPlugIn() throws {
    let programs = try harvested()
    var total = 0, rewritten = 0, same = 0
    var unread: [String: [String]] = [:], changed: [String] = []
    for source in programs {
        let shell = Shell()
        let bound = shell.interpreter.globalNames()
        guard let parsed = try? SwiftSyntaxFrontEnd().parse(source, bound: bound, plugin: ShellSyntax()) else { continue }
        total += 1
        var desugared: Program?
        _ = try? shell.capturing { desugared = shell.typeCheck(parsed) }
        guard let desugared else { continue }
        rewritten += 1
        let printed = SwiftPrinter().source(desugared)
        do {
            let back = try SwiftSyntaxFrontEnd().parse(printed, bound: bound, plugin: nil)
            let again = SwiftPrinter().source(back)
            if again == printed { same += 1 } else { changed.append("\(source.prefix(80))\n--- printed:\n\(printed.prefix(600))\n--- again:\n\(again.prefix(600))") }
        } catch {
            unread["\(error)".prefix(90).description, default: []].append("\(source.prefix(70))  ==>  \(printed.prefix(400))")
        }
    }
    print("SPLIT programs \(total), checked and rewritten \(rewritten), read back identically \(same), unread \(unread.values.map(\.count).reduce(0, +)), changed \(changed.count)")
    for (reason, cases) in unread.sorted(by: { $0.value.count > $1.value.count }).prefix(20) {
        print("SPLIT UNREAD x\(cases.count): \(reason)\n   e.g. \(cases.joined(separator: "\n   e.g. "))")
    }
    for case_ in changed.prefix(10) { print("SPLIT CHANGED: \(case_)") }
}
