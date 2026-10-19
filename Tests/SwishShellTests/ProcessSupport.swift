@_spi(Layer) import Swiit
@_spi(Shell) @_spi(Layer) @testable import SwishShell
import Foundation

// What the tests need to know about the process they run in. In a file of
// its own: Foundation can't be imported next to Testing here.

/// This process's id.
func currentProcessID() -> Int {
    Int(ProcessInfo.processInfo.processIdentifier)
}

/// What `source` says when it fails, as written to the shell's error output (its first line), or nil if it ran without a word:
/// a failure of a pipeline's stage is found when the pipeline starts.
func errorText(_ source: String, in shell: Shell = Shell()) -> String? {
    guard let pipe = makePipe() else { return nil }
    let collector = OutputCollector(reading: pipe.read)
    let saved = shell.stderrFD
    shell.stderrFD = pipe.write
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    shell.stderrFD = saved
    close(pipe.write)
    let text = shell.interpreter.suspend { collector.finish() }
    return text.isEmpty ? nil : String(text.split(separator: "\n", omittingEmptySubsequences: false).first ?? "")
}
