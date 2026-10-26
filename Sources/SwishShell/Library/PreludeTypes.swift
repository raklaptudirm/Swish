import Swiit

/// The types the prelude declares, which Swift code builds values of and tells values apart by.
/// Asked of the interpreter once, after the prelude loads: a name the prelude no longer declares
/// stops the shell at startup, not at a use.
struct PreludeTypes {
    let status, commandFailure, glob, spread, jobState, wrapping: Symbol.ID

    init(_ interpreter: Interpreter) {
        func declared(_ name: String) -> Symbol.ID {
            guard let id = interpreter.typeID(named: name) else {
                preconditionFailure("the shell's prelude declares no \(name)")
            }
            return id
        }
        status = declared("Status")
        commandFailure = declared("CommandFailure")
        glob = declared("Glob")
        spread = declared("Spread")
        jobState = declared("JobState")
        wrapping = declared("Wrapping")
    }
}

/// The types the shell builds values of by name: a value of the Swift type of that name, which
/// stands for the prelude's declaration of it (`Status`, `FileEntry`).
enum NamedTypes {
    static let status = Symbol.ID(hostType: "Status")
    static let fileEntry = Symbol.ID(hostType: "FileEntry")
    static let processEntry = Symbol.ID(hostType: "ProcessEntry")
    static let json = Symbol.ID(hostType: "JSON")
    static let help = Symbol.ID(hostType: "Help")
    static let member = Symbol.ID(hostType: "Member")
}
