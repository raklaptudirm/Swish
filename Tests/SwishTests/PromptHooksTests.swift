import Foundation
import Swiit
import SwishEngine
import Testing

@testable import Swish

@Test func actionsRunBeforeEachPromptAndWhenTheDirectoryChanged() throws {
    let shell = Shell()
    let prompt = InteractivePrompt(shell: shell)
    prompt.declareScriptFunctions()
    shell.execute(
        """
        var seen: [String] = []
        onDirectoryChange { from, to in seen.append("\\(from.lastComponent!)→\\(to.lastComponent!)") }
        beforePrompt { seen.append("p") }
        beforePrompt { throw Oops() }
        struct Oops: Error {}
        """
    )

    var directory = "/a/one"
    let errors = try capturingStandardError {
        for next in ["/a/one", "/a/two", "/a/two"] {
            directory = next
            prompt.willPrompt { directory }
        }
    }
    // The action that failed is reported, and the others ran.
    #expect(errors.contains("beforePrompt: "))
    let seen = try shell.interpreter.evaluate("seen")
    #expect(seen.debugDescription == #"["p", "one→two", "p", "p"]"#)
}
