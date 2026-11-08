import Foundation
import Swiit

// The Swift types the shell gives scripts, described to the interpreter: a size, a column, a
// command's output.

extension FileSize {
    static let native = HostTypeBuilder<FileSize>("FileSize")
        .property("bytes", \.bytes)
        .property("description", \.description)
        .initializer(labels: ["bytes"]) { (bytes: Int) in FileSize(bytes: bytes) }
        .initializer(labels: [nil, "multiplier"]) { (amount: Double, multiplier: Int) in
            FileSize(amount, multiplier: multiplier)
        }
        .failableInitializer(labels: [nil, "unit"]) { (amount: Double, unit: String) in
            FileSize(amount, unit: unit)
        }
        .failableInitializer { (text: String) in FileSize(text) }
        .static("+", labels: [nil, nil], throwing: true) {
            (a: FileSize, b: FileSize) throws -> FileSize in try a + b
        }
        .static("-", labels: [nil, nil], throwing: true) {
            (a: FileSize, b: FileSize) throws -> FileSize in try a - b
        }
        .static("-", labels: [nil], throwing: true) { (a: FileSize) throws -> FileSize in try -a }
        .static("*", labels: [nil, nil], throwing: true) {
            (a: FileSize, b: Int) throws -> FileSize in
            try a * b
        }
        .static("*", labels: [nil, nil], throwing: true) {
            (a: FileSize, b: Double) throws -> FileSize in try a * b
        }
        .static("*", labels: [nil, nil], throwing: true) {
            (a: Int, b: FileSize) throws -> FileSize in
            try a * b
        }
        .static("*", labels: [nil, nil], throwing: true) {
            (a: Double, b: FileSize) throws -> FileSize in try a * b
        }
        .static("/", labels: [nil, nil], throwing: true) {
            (a: FileSize, b: Int) throws -> FileSize in
            try a / b
        }
        .static("/", labels: [nil, nil], throwing: true) {
            (a: FileSize, b: Double) throws -> FileSize in try a / b
        }
        .static("/", labels: [nil, nil]) { (a: FileSize, b: FileSize) -> Double in a / b }
}

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

extension FileEntry {
    static let native = HostTypeBuilder<FileEntry>("FileEntry")
        .property("name", \.name)
        .property("type", \.type)
        .property("size", \.size)
        .property("modified", \.modified)
        .property("permissions", \.permissions)
        .property("owner", \.owner)
        .property("created", \.created)
        .property("accessed", \.accessed)
        .property("path", \.path)
        .property("target", \.target)
}

extension ProcessEntry {
    static let native = HostTypeBuilder<ProcessEntry>("ProcessEntry")
        .property("pid", \.pid)
        .property("ppid", \.ppid)
        .property("name", \.name)
        .property("user", \.user)
        .property("memory", \.memory)
        .property("cpuTime", \.cpuTime)
        .property("threads", \.threads)
}

extension DisplayColumn {
    static let native = HostTypeBuilder<DisplayColumn>("DisplayColumn")
        .property("name", \.name)
        .property("styledBy", \.styledBy)
}

extension Output {
    static let native = HostTypeBuilder<Output>("Output")
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
