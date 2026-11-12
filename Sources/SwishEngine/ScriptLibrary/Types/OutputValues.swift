import Swiit
import SwishLibrary

extension Value {
    /// What `$(…)` gives: a command's output, held as the Swift value it is.
    static func output(_ output: Output) -> Value { Value(output) }

    /// The command output it holds, if it's one.
    var commandOutput: Output? { casting(to: Output.self) }
}
