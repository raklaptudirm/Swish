import Foundation
import Swiit

/// A Swift struct scripts hold as data, as `ls` gives `FileEntry`s: its stored properties are its
/// fields, in the order they are declared, wherever its fields are laid out (a table, `to json`,
/// `select`), as a struct a script declares has. Its type registers the same properties for the
/// checker.
public protocol RecordRepresentable: ScriptConvertible, Sendable {}

extension RecordRepresentable {
    public var memberNames: [String]? {
        Mirror(reflecting: self).children.compactMap(\.label)
    }

    public func member(_ name: String) -> Value? {
        let field = Mirror(reflecting: self).children.first { $0.label == name }
        return field.map { ($0.value as? any ScriptConvertible)?.value ?? .nothing }
    }
}
