import Foundation
import Testing

@Test func executionNamesNothingOfShell() throws {
    let found: Set<String>
    do { found = try Layering.breaches() } catch {
        Issue.record("\(error)")
        return
    }

    // A new breach fails, and so does a known one that is gone: the list only shrinks.
    #expect(found.subtracting(Layering.known).sorted() == [])
    #expect(Layering.known.subtracting(found).sorted() == [])
}

/// The library is under the engine: it can be used without a shell, and a script type needs nothing
/// of the shell to be one. The compiler enforces this (a module cannot import one that imports it);
/// the test names the rule where a reader looks for it, and catches a mention that survives in a
/// comment or a name.
@Test func theLibraryNamesNothingOfTheEngine() throws {
    let sources = PublicSurface.sources(of: "SwishLibrary")
    let files = FileManager.default.enumerator(atPath: sources.path)!.compactMap { $0 as? String }
        .filter { $0.hasSuffix(".swift") && !$0.hasPrefix("Generated") }
    var mentions: [String] = []
    for file in files {
        let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
        for (index, line) in text.components(separatedBy: "\n").enumerated()
        where line.contains("import SwishEngine") || line.contains("ShellTask")
            || line.contains("CommandRunner")
        {
            mentions.append("\(file):\(index + 1)")
        }
    }
    #expect(mentions == [])
}
