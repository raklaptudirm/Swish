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

extension Output {
    static let native = HostType.Builder<Output>("Output")
        .property("text", \.text)
        .property("lines", \.lines)
        .property("code", \.status.code)
        .property("signal", \.status.signal)
        .property("succeeded", \.status.succeeded)
        .property("count", \.count)
        .property("isEmpty", \.isEmpty)
        .property("first", \.first)
        .property("last", \.last)
        .property("startIndex", \.startIndex)
        .property("endIndex", \.endIndex)
        .property("description", \.description)
        .property("debugDescription", \.debugDescription)
        .initializer(labels: ["text", "code", "signal"]) {
            (text: String, code: Int?, signal: Int?) in
            let status = signal.map { Status.signaled(Int32($0)) } ?? .exited(Int32(code ?? 0))
            return Output(text: text, status: status)
        }
        // A command's output compares with text as its text does, on either side.
        .static("==", labels: [nil, nil]) { (a: Output, b: String) -> Bool in a.text == b }
        .static("==", labels: [nil, nil]) { (a: String, b: Output) -> Bool in a == b.text }
        .static("!=", labels: [nil, nil]) { (a: Output, b: String) -> Bool in a.text != b }
        .static("!=", labels: [nil, nil]) { (a: String, b: Output) -> Bool in a != b.text }
        .static("<", labels: [nil, nil]) { (a: Output, b: String) -> Bool in a.text < b }
        .static("<", labels: [nil, nil]) { (a: String, b: Output) -> Bool in a < b.text }
        .static(">", labels: [nil, nil]) { (a: Output, b: String) -> Bool in a.text > b }
        .static(">", labels: [nil, nil]) { (a: String, b: Output) -> Bool in a > b.text }
        .static("<=", labels: [nil, nil]) { (a: Output, b: String) -> Bool in a.text <= b }
        .static("<=", labels: [nil, nil]) { (a: String, b: Output) -> Bool in a <= b.text }
        .static(">=", labels: [nil, nil]) { (a: Output, b: String) -> Bool in a.text >= b }
        .static(">=", labels: [nil, nil]) { (a: String, b: Output) -> Bool in a >= b.text }
}
