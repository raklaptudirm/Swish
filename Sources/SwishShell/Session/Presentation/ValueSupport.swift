import Foundation
import Swiit

// What the shell's printers read of a value, over Swiit's public inspection: a struct's or an
// object's fields, and how a value held as a Swift one looks.

/// The fields of a struct, a tuple, or an object that is data, in order, and the name of the
/// struct's type.
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

    func makeIterator() -> some IteratorProtocol<(key: String, value: Value)> {
        entries.makeIterator()
    }

    /// A tuple's unlabeled element is named by its position.
    static func isPosition(_ key: String) -> Bool { !key.isEmpty && key.allSatisfy(\.isNumber) }
}

extension Value {
    /// The fields of a struct, a tuple or an object that is data.
    var fields: Fields? { Fields(self) }

    /// How it looks beyond its text, said by the Swift type it is held as.
    var displayShape: DisplayShape {
        ((try? unboxed((any Presentable).self))?.shape) ?? DisplayShape()
    }

    /// Text with styles, held as the Swift value it is.
    static func attributed(_ text: AttributedString) -> Value {
        Value(boxing: text, as: "AttributedString")
    }
}

extension Array where Element == (key: Value, value: Value) {
    /// The entries sorted by key, so a dictionary is shown the same way every time: numbers by
    /// value, strings as Swift sorts them, `false` before `true`, and anything else by how it is
    /// written.
    var sortedForDisplay: [(key: Value, value: Value)] {
        sorted { Value.displaysBefore($0.key, $1.key) }
    }
}

extension Value {
    fileprivate static func displaysBefore(_ a: Value, _ b: Value) -> Bool {
        func number(_ value: Value) -> Double? {
            value.cast(to: Int.self).map(Double.init) ?? value.cast(to: Double.self)
        }
        if let x = number(a), let y = number(b) { return x < y }
        if let x = a.cast(to: String.self), let y = b.cast(to: String.self) { return x < y }
        if let x = a.cast(to: Bool.self), let y = b.cast(to: Bool.self) { return !x && y }
        return a.debugDescription < b.debugDescription
    }
}

/// What a value is, for the places that lay values out: the shell's own taxonomy, made from what
/// the interpreter says of a value (its type, and the views of a tuple, a struct and an enum).
enum ValueKind {
    case nothing, bool, int, double, string, list, dictionary
    case tuple, structure, enumeration, function, object
}

extension Value {
    var kind: ValueKind {
        guard let id = typeID else {
            if tuple != nil { return .tuple }
            return function != nil ? .function : .object
        }
        if id == .int { return .int }
        if id == .string { return .string }
        if id == .bool { return .bool }
        if id == .double { return .double }
        if id == .array { return .list }
        if id == .dictionary { return .dictionary }
        if id == .optional && self == .nothing { return .nothing }
        if structure != nil { return .structure }
        if enumCase != nil { return .enumeration }
        return .object
    }
}
