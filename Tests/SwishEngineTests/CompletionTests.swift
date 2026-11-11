import Swiit
import Testing

@testable import SwishEngine

// What the shell offers to complete the word being typed.

private func completion(
    _ text: String,
    in shell: Shell = Shell()
) -> (start: Int, replacements: [String]) {
    let result = shell.completions(for: text, cursor: text.count)
    return (result?.start ?? -1, result?.candidates.map(\.replacement) ?? [])
}

@Test func completesCommandsIncludingFunctions() {
    let shell = Shell()
    shell.execute("/// Greets.\nfunc zzgreet() {}")
    let result = shell.completions(for: "zzg", cursor: 3)
    #expect(
        result?.candidates == [
            Shell.Completions.Candidate(
                replacement: "zzgreet",
                display: "zzgreet",
                description: "Greets."
            )
        ]
    )
    #expect(completion("ech").replacements.contains("echo"))
    #expect(completion("if tru && ls | filt").replacements.contains("filter"))  // after a pipe: command position
    #expect(completion("^zzg", in: shell).replacements.isEmpty)  // ^ is externals only
    #expect(completion("foreign ech").replacements.contains("echo"))
    #expect(completion("EDITOR=vim ech").replacements.contains("echo"))
}

@Test func completesFlagsFromSignatures() {
    let shell = Shell()
    shell.execute(#"func f(@flag("n") times: Int = 1, color: Bool = true) {}"#)
    #expect(
        completion("f --", in: shell).replacements == [
            "--color", "--help", "--no-color", "--times",
        ]
    )
    #expect(completion("f -", in: shell).replacements.contains("-n"))
    #expect(completion("ls | sorted --b").replacements == ["--by"])
}

@Test func completesVariables() {
    let shell = Shell()
    shell.execute("let zzvalue = 1")
    #expect(completion("echo $zzv", in: shell).replacements == ["$zzvalue"])
    #expect(completion("echo $HOM").replacements.contains("$HOME"))
}

@Test func completesPathsEscapingSpaces() throws {
    let shell = Shell()
    let dir = try shell.runner.capturing { shell.execute("mktemp -d") }
        .trimmingCharacters(in: .newlines)
    shell.execute("mkdir '\(dir)/a dir'; touch \(dir)/afile \(dir)/.hidden")
    let result = shell.completions(for: "cat \(dir)/a", cursor: "cat \(dir)/a".count)
    #expect(result?.start == 4)
    #expect(result?.candidates.map(\.replacement) == ["\(dir)/a\\ dir", "\(dir)/afile"])
    #expect(result?.candidates.map(\.suffix) == ["/", " "])
    #expect(completion("cat \(dir)/.h").replacements == ["\(dir)/.hidden"])
    #expect(completion("cat \"\(dir)/af").replacements == ["\"\(dir)/afile"])
}
