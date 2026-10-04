@testable import SwishCore
import Foundation
import SwishKit

// What the help tests need from Foundation's AttributedString. In a file of
// their own: Foundation can't be imported next to Testing here.

/// The style of the run that is exactly `word`, in the signature (found by its
/// text) of a member of `type`; nil if there's no such member or run, and the
/// run's own style (itself possibly nil) otherwise.
func runStyle(of word: String, inSignature signature: String, ofType type: String, shell: Shell) -> DisplayStyle?? {
    guard let members = shell.typeDescription(named: type)?.members,
          let text = members.first(where: { $0.signature.plain == signature })?.signature else { return nil }
    return text.runs.first { String(text[$0.range].characters) == word }.map { $0.swish.displayStyle }
}

/// `ls [--all]` with the command in its style, as plain text and as colored.
func sampleStyledLine() -> (plain: String, colored: String) {
    let line = AttributedString(joining: [AttributedString("ls", .command), AttributedString(" [--all]")])
    return (line.plain, line.colored)
}
