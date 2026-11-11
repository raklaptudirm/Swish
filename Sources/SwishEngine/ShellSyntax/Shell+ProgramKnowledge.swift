import Foundation
import Swiit

extension Shell {
    /// What the front end knows of the programs around a command line, to read a command's words
    /// against them.
    struct ProgramKnowledge {
        /// Programs on PATH, for highlighting and completion.
        var executableCache: (path: String, time: Date, names: Set<String>)?

        /// The command lines the last program read has (Front/), to check against the functions
        /// they name.
        var commandUses: [Front.CommandUse] = []

        /// What the functions a script declared say of their parameters (`@input`, `@flag`), by
        /// `function.parameter`.
        var scriptMarks: [String: CommandMarks.Marks] = [:]

        /// The static members (an enum's cases among them) of the types the program being checked
        /// declares, by type: the interpreter has none of them yet, and a command's word for one
        /// is read against these.
        var staticMembers: [String: [Symbol]] = [:]
    }
}
