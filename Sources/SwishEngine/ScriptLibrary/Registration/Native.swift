import Foundation
import Swiit

// The Swift types the shell gives scripts that the generator cannot describe (Scripts/bridge makes
// the rest): a command's output, which has the members of a collection and of its text.

/// A Swift struct scripts hold as data, as `ls` gives `FileEntry`s: its stored properties are its
/// fields, in the order they are declared, wherever its fields are laid out (a table, `to json`,
/// `select`), as a struct a script declares has. Its type registers the same properties for the
/// checker.
protocol Record: ScriptConvertible, Sendable {}

extension Record {
    var memberNames: [String]? {
        Mirror(reflecting: self).children.compactMap(\.label)
    }

    func member(_ name: String) -> Value? {
        let field = Mirror(reflecting: self).children.first { $0.label == name }
        return field.map { ($0.value as? any ScriptConvertible)?.value ?? .nothing }
    }
}
