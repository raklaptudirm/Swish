import Foundation

/// What the engine's layers may not name (Docs/Design/execution-seam.md). Execution runs a command
/// line; it asks `Shell` for nothing by name, so it can be read, and tested, without it. A support
/// file because it reads source with Foundation, which the test file can't import beside Testing.
enum Layering {
    /// A folder under `Sources/SwishEngine` and the folders whose declarations it may not name.
    static let rules: [(layer: String, mustNotName: [String])] = [
        ("Execution", ["Shell"])
    ]

    /// The files that still break a rule, until the step that moves them: `file: name`. A file that
    /// stops breaking its rule must leave this list, so the list only shrinks.
    static let known: Set<String> = [
        "Execution/CommandBinding/CommandLineBinder.swift: Shell",
        "Execution/CommandBinding/Shell+CommandLine.swift: Shell",
        "Execution/CommandBinding/Shell+WordValues.swift: Shell",
        "Execution/CommandBinding/StageNames.swift: Shell",
        "Execution/Jobs/Jobs.swift: Shell",
        "Execution/Jobs/Jobs.swift: ShellTask",
        "Execution/Jobs/JobsBinding.swift: Shell",
        "Execution/Pipelines/CommandFailure.swift: Shell",
        "Execution/Pipelines/CommandObject.swift: Shell",
        "Execution/Pipelines/Redirects.swift: Shell",
        "Execution/Pipelines/Shell+Capturing.swift: Shell",
        "Execution/Pipelines/Shell+Pipelines.swift: Shell",
        "Execution/Pipelines/Shell+Resolving.swift: Shell",
        "Execution/Pipelines/Shell+Stages.swift: Shell",
        "Execution/Pipelines/Shell+Streams.swift: Shell",
        "Execution/WordExpansion/Shell+Words.swift: Shell",
    ]

    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/SwishEngine")

    private static let declaration = try! NSRegularExpression(
        pattern:
            #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final|indirect)\s+)*(?:struct|class|enum|protocol|actor|typealias)\s+([A-Z]\w*)"#,
        options: [.anchorsMatchLines]
    )

    /// Every `file: name` where a layer names a declaration of a layer it must not.
    static func breaches() throws -> Set<String> {
        let files = FileManager.default.enumerator(atPath: sources.path)!
            .compactMap { $0 as? String }
            // The prelude is Swift written for the interpreter to read, not declarations of this module.
            .filter { $0.hasSuffix(".swift") && !$0.hasSuffix("Prelude/Prelude.swift") }
            .sorted()

        var text: [String: String] = [:]
        var declaredIn: [String: Set<String>] = [:]
        for file in files {
            let source = try String(
                contentsOf: sources.appendingPathComponent(file),
                encoding: .utf8
            )
            let code = source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            text[file] = code

            for match in declaration.matches(in: code, range: NSRange(code.startIndex..., in: code))
            {
                let name = String(code[Range(match.range(at: 1), in: code)!])
                declaredIn[name, default: []].insert(layer(of: file))
            }
        }

        var found: Set<String> = []
        for (layer, forbiddenLayers) in rules {
            // A name a permitted layer declares too cannot be told from it, so it is not counted.
            let forbidden = declaredIn.filter { _, layers in
                !layers.contains(layer) && !layers.isDisjoint(with: forbiddenLayers)
            }
            for file in files where self.layer(of: file) == layer {
                for name in forbidden.keys.sorted()
                where text[file]!.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil {
                    found.insert("\(file): \(name)")
                }
            }
        }
        return found
    }

    private static func layer(of file: String) -> String {
        String(file.split(separator: "/")[0])
    }
}
