import Foundation
import Swiit
import SwiitStandardLibrary

// What the shell's printers read of a value, over Swiit's public inspection: a struct's or an object's fields, and how a
// value held as a Swift one looks.

/// The fields of a struct, a tuple, or an object that is data, in order, and the name of the struct's type.
struct Fields: Sequence {
    var typeName: String?
    private(set) var entries: [(key: String, value: Value)]

    init?(_ value: Value) {
        switch value.kind {
        case .structure, .tuple, .object: break
        default: return nil
        }
        guard let entries = value.entries else { return nil }
        typeName = value.kind == .tuple ? nil : value.typeName
        self.entries = entries.map { key, value in (key.description, value) }
    }

    var keys: [String] { entries.map(\.key) }
    var count: Int { entries.count }

    subscript(key: String) -> Value? { entries.first { $0.key == key }?.value }

    func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> { entries.makeIterator() }

    /// A tuple's unlabeled element is named by its position.
    static func isPosition(_ key: String) -> Bool { !key.isEmpty && key.allSatisfy(\.isNumber) }
}

extension Value {
    /// The fields of a struct, a tuple or an object that is data.
    var fields: Fields? { Fields(self) }

    /// How it looks beyond its text, said by the Swift type it is held as.
    var displayShape: DisplayShape {
        ((try? unboxed((any SwiitDisplayed).self))?.swiitShape) ?? DisplayShape()
    }

    /// Text with styles, held as the Swift value it is.
    static func attributed(_ text: AttributedString) -> Value { Value(boxing: text, as: "AttributedString") }
}
