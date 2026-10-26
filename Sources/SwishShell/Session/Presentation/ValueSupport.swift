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
        ((try? unboxing((any Presentable).self))?.shape) ?? DisplayShape()
    }

    /// Text with styles, held as the Swift value it is.
    static func attributed(_ text: AttributedString) -> Value {
        Value(boxing: text)
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
            value.casting(to: Int.self).map(Double.init) ?? value.casting(to: Double.self)
        }
        if let x = number(a), let y = number(b) { return x < y }
        if let x = a.casting(to: String.self), let y = b.casting(to: String.self) { return x < y }
        if let x = a.casting(to: Bool.self), let y = b.casting(to: Bool.self) { return !x && y }
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
    /// What it is made of, read as any Swift value is: its shape (`displayStyle`) and children.
    var mirror: Mirror { Mirror(reflecting: self) }

    /// A structured value's fields as ordered pairs: a dictionary's (in no particular order), the
    /// fields of a tuple or a struct by name (a tuple's unlabeled ones by position, "0", "1"), or
    /// the data of a host's object. Nil for any other value.
    var entries: [(key: Value, value: Value)]? {
        let mirror = self.mirror
        switch mirror.displayStyle {
        case .dictionary:
            return mirror.children.compactMap { $0.value as? (key: Value, value: Value) }
        case .tuple, .struct, .class:
            return mirror.children.enumerated()
                .compactMap { index, child in
                    (child.value as? Value)
                        .map { (key: Value(child.label ?? String(index)), value: $0) }
                }
        default:
            return nil
        }
    }

    /// What a case of an enum carries, as `entries` has a tuple's: each value under its label or
    /// its position. Swift's mirror of an enum has one child, labeled with the case's name, whose
    /// value is the one thing carried or a tuple of them.
    var enumPayload: [(key: String, value: Value)] {
        guard let carried = mirror.children.first?.value as? Value else { return [] }
        if carried.mirror.displayStyle == .tuple, let fields = carried.entries {
            return fields.map { (key: $0.key.description, value: $0.value) }
        }
        return [(key: "0", value: carried)]
    }

    /// The name of its type, as errors and tables say it: the type's name, `Tuple` or `Function`,
    /// or what a host's object calls itself.
    var typeName: String {
        if let id = typeID { return id.name }
        if mirror.displayStyle == .tuple { return "Tuple" }
        if isInstance(of: .function) { return "Function" }
        return (try? unboxing((any HostObject).self))?.typeName ?? "Object"
    }

    /// The name of the case of an enum this is, if it is one. Swift's own mirror of an enum has one
    /// child, labeled with the case's name, for a case that carries something; one that carries
    /// nothing is its name when described.
    var enumCaseName: String? {
        let mirror = self.mirror
        guard mirror.displayStyle == .enum else { return nil }
        return mirror.children.first?.label ?? description
    }

    var kind: ValueKind {
        guard let id = typeID else {
            if mirror.displayStyle == .tuple { return .tuple }
            return isInstance(of: .function) ? .function : .object
        }
        if id == .int { return .int }
        if id == .string { return .string }
        if id == .bool { return .bool }
        if id == .double { return .double }
        if id == .array { return .list }
        if id == .dictionary { return .dictionary }
        if id == .optional && self == .nothing { return .nothing }
        switch mirror.displayStyle {
        case .struct: return .structure
        case .enum: return .enumeration
        default: return .object
        }
    }
}
