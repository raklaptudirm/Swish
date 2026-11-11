import Foundation
import Testing

// What SwishShell offers a client, as a list. A client of the shell uses this interface and nothing
// else (Docs/Design/shell-interface.md), so a new public declaration is a decision: add its name here
// and to the design, or make it internal.

enum PublicSurface {
    /// The top-level types.
    static let types: Set<String> = [
        "Shell", "Status", "HighlightKind", "HighlightSpan", "Terminal",
    ]

    /// The public members, by the type that has them.
    static let members: Set<String> = [
        // Making a shell, and what it is built over
        "Shell.init", "Shell.interpreter", "Shell.lastStatus",
        // Running source
        "Shell.execute", "Shell.enter", "Shell.keepingStatus",
        "Shell.accept", "Shell.hasUnfinishedStatement", "Shell.discardUnfinishedStatement",
        "Shell.finishInput", "Shell.isUnfinished", "Shell.Acceptance",
        // Files
        "Shell.source", "Shell.runScript", "Shell.endBySignal", "Shell.loadEnvironment",
        "Shell.ScriptFile", "Shell.ScriptFile.functions", "Shell.ScriptFile.call",
        // What an editor asks
        "Shell.highlighting", "Shell.completions", "Shell.Completions",
        "Shell.Completions.Candidate", "Shell.Completions.Candidate.init",
        "Shell.Completions.Candidate.replacement", "Shell.Completions.Candidate.suffix",
        "Shell.Completions.Candidate.display", "Shell.Completions.Candidate.description",
        "Shell.Completions.start", "Shell.Completions.candidates",
        // A terminal, its jobs and tasks
        "Shell.takeTerminal", "Shell.jobNotices", "Shell.cancelAndJoinTasks",
        // What a client adds
        "Shell.register", "Shell.Builtin", "Shell.Builtin.run", "Shell.Builtin.program",
        "Shell.report",
        // How a statement ended, and what the spans of a source say
        "Status.success", "Status.succeeded", "Status.number", "Status.code", "Status.signal",
        "Status.encode",
        "HighlightKind.displayStyle", "HighlightSpan.range", "HighlightSpan.kind",
        "HighlightSpan.init",
        // A retroactive conformance is as public as the type and the protocol: `Date` is a
        // `LosslessStringConvertible`, so a word of ISO 8601 text is a date on a command line.
        "Date.init",
        // The terminal a client draws on, and where a descriptor may be styled
        "Terminal.width", "Terminal.height", "Terminal.write", "DisplayStyle.enabled",
        // A doc comment's first sentence, which a list of functions shows
        "String.firstSentence",
        // Painting spans onto characters, for an editor and for the shell's own diagnostics
        "Sequence.paintedStyles",
    ]

    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/SwishShell")

    private static let container = try! NSRegularExpression(
        pattern:
            #"^(\s*)(?:@\w+(?:\([^)]*\))?\s+)*(public\s+|internal\s+|private\s+|fileprivate\s+)?(?:final\s+|indirect\s+)*(struct|class|enum|extension|protocol)\s+([A-Za-z_][\w]*)"#
    )
    private static let member = try! NSRegularExpression(
        pattern:
            #"^(\s*)(?:@\w+(?:\([^)]*\))?\s+)*public\s+(?:(?:internal|private|fileprivate)\(set\)\s+)?(?:final\s+|static\s+|mutating\s+|indirect\s+)*(func|var|let|init|subscript|typealias|struct|class|enum)\s*([A-Za-z_]\w*)?"#
    )

    /// The public declarations in the sources: the top-level types, and the members of public
    /// types (a member of an extension counts for the type it extends).
    static func current() throws -> (types: Set<String>, members: Set<String>) {
        var types: Set<String> = []
        var localTypes: Set<String> = []
        var members: Set<String> = []
        var parsed: [(lines: [String], file: String)] = []
        let files = FileManager.default.enumerator(atPath: sources.path)!
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") }
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            parsed.append((text.components(separatedBy: "\n"), file))
        }
        func groups(_ regex: NSRegularExpression, _ line: String) -> [String]? {
            guard
                let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
            else { return nil }
            return (1..<match.numberOfRanges)
                .map {
                    Range(match.range(at: $0), in: line).map { String(line[$0]) } ?? ""
                }
        }
        for (lines, _) in parsed {
            for line in lines {
                if let g = groups(container, line), g[3] != "", g[2] != "extension" {
                    localTypes.insert(g[3])
                    if g[0].isEmpty, g[1].hasPrefix("public") { types.insert(g[3]) }
                }
            }
        }

        for (lines, _) in parsed {
            var stack: [(indent: Int, name: String, isPublic: Bool)] = []
            for line in lines {
                if let g = groups(container, line) {
                    let indent = g[0].count
                    stack.removeAll { $0.indent >= indent }
                    let explicit = g[1].trimmingCharacters(in: .whitespaces)
                    let isPublic: Bool =
                        g[2] == "extension"
                        ? (stack.last?.isPublic
                            ?? (types.contains(g[3]) || !localTypes.contains(g[3])))
                            && explicit != "private" && explicit != "fileprivate"
                        : explicit == "public" && (stack.last?.isPublic ?? true)
                    stack.append((indent, g[3], isPublic))
                    if g[2] != "extension", explicit == "public", indent > 0,
                        stack.dropLast().allSatisfy(\.isPublic)
                    {
                        members.insert(
                            (stack.dropLast().map(\.name) + [g[3]]).joined(separator: ".")
                        )
                    }
                    continue
                }
                if let g = groups(member, line) {
                    let indent = g[0].count
                    stack.removeAll { $0.indent >= indent }
                    guard indent > 0, !stack.isEmpty, stack.allSatisfy(\.isPublic) else { continue }
                    let name = g[1] == "init" ? "init" : (g[2].isEmpty ? g[1] : g[2])
                    members.insert((stack.map(\.name) + [name]).joined(separator: "."))
                }
            }
        }
        return (types, members)
    }
}

@Test func theTopLevelPublicTypesAreTheOnesListed() throws {
    #expect(try PublicSurface.current().types == PublicSurface.types)
}

@Test func theMembersOfThePublicTypesAreTheOnesListed() throws {
    let current = try PublicSurface.current().members
    #expect(
        current.subtracting(PublicSurface.members).sorted() == [],
        "public, and not listed"
    )
    #expect(
        PublicSurface.members.subtracting(current).sorted() == [],
        "listed, and not public"
    )
}
