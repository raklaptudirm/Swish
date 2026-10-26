import Swiit

/// The types the prelude declares and Swift code tells values apart by. `installLibrary` checks
/// that each is declared, so a rename in the prelude stops the shell at startup, not at a use.
enum PreludeTypes {
    static let glob = Symbol.ID(declaring: "Glob")
    static let spread = Symbol.ID(declaring: "Spread")
    static let jobState = Symbol.ID(declaring: "JobState")
    static let wrapping = Symbol.ID(declaring: "Wrapping")

    static var all: [Symbol.ID] { [Status.id, glob, spread, jobState, wrapping] }
}
