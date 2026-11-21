import Foundation
import Swiit

/// A Swift value scripts hold as data, as `ls` gives `FileEntry`s: it says its fields, in order,
/// wherever its fields are laid out (a table, `to json`, `select`), as a struct a script declares has.
/// The default reads the stored properties, in the order they are declared, which its type registers
/// for the checker as members.
public protocol RecordRepresentable: BridgedValue, Sendable {
    /// The fields, in order, each with the value a script reads.
    var fields: [(name: String, value: Value)] { get }
}

extension RecordRepresentable {
    public var fields: [(name: String, value: Value)] {
        Mirror(reflecting: self).children
            .compactMap { child in
                guard let name = child.label else { return nil }
                return (name, (child.value as? any BridgedValue)?.value ?? .nothing)
            }
    }
}
