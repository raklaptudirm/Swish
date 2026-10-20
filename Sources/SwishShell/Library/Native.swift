import Foundation
import Swiit

// The Swift types the shell gives scripts, described to the interpreter: a size, a column, a command's output.

extension FileSize {
    static let native = NativeType.Builder<FileSize>(
        "FileSize", conformances: ["Equatable", "Hashable", "Comparable", "CustomStringConvertible", "Encodable"],
        parse: { FileSize($0) }
    )
    .property("bytes", \.bytes)
    .property("description", \.description)
    .initializer(labels: ["bytes"]) { (bytes: Int) in FileSize(bytes: bytes) }
    .initializer(labels: [nil, "multiplier"]) { (amount: Double, multiplier: Int) in FileSize(amount, multiplier: multiplier) }
    .failableInitializer(labels: [nil, "unit"]) { (amount: Double, unit: String) in FileSize(amount, unit: unit) }
    .failableInitializer { (text: String) in FileSize(text) }
    .static("+", labels: [nil, nil], throwing: true) { (a: FileSize, b: FileSize) throws -> FileSize in try a + b }
    .static("-", labels: [nil, nil], throwing: true) { (a: FileSize, b: FileSize) throws -> FileSize in try a - b }
    .static("-", labels: [nil], throwing: true) { (a: FileSize) throws -> FileSize in try -a }
    .static("*", labels: [nil, nil], throwing: true) { (a: FileSize, b: Int) throws -> FileSize in try a * b }
    .static("*", labels: [nil, nil], throwing: true) { (a: FileSize, b: Double) throws -> FileSize in try a * b }
    .static("*", labels: [nil, nil], throwing: true) { (a: Int, b: FileSize) throws -> FileSize in try a * b }
    .static("*", labels: [nil, nil], throwing: true) { (a: Double, b: FileSize) throws -> FileSize in try a * b }
    .static("/", labels: [nil, nil], throwing: true) { (a: FileSize, b: Int) throws -> FileSize in try a / b }
    .static("/", labels: [nil, nil], throwing: true) { (a: FileSize, b: Double) throws -> FileSize in try a / b }
    .static("/", labels: [nil, nil]) { (a: FileSize, b: FileSize) -> Double in a / b }
}

extension DisplayColumn {
    static let native = NativeType.Builder<DisplayColumn>(
        "DisplayColumn", conformances: ["ExpressibleByStringLiteral"], literal: { DisplayColumn($0) }
    )
    .property("name", \.name)
    .property("styledBy", \.styledBy)
}

extension Status: ValueConvertible {
    static var valueType: ValueType { .named("Status") }
    init(_ value: Value) throws {
        guard value.typeName == "Status", let succeeded = value.field("succeeded")?.cast(to: Bool.self) else {
            throw LibraryError("expected a Status, not \(value)")
        }
        self.init(code: value.field("code")?.cast(to: Int.self), signal: value.field("signal")?.cast(to: Int.self), succeeded: succeeded)
    }
}

extension Output {
    static let native = NativeType.Builder<Output>(
        "Output", conformances: ["Equatable", "Hashable", "Sequence", "StandsForText", "CustomStringConvertible"],
        associatedTypes: ["Element": .string, "Index": .int]
    )
    .property("text", \.text)
    .property("lines", \.lines)
    .property("code", \.code)
    .property("signal", \.signal)
    .property("succeeded", \.succeeded)
    .property("status", \.status)
    .property("count", \.count)
    .property("isEmpty", \.isEmpty)
    .property("first", \.first)
    .property("last", \.last)
    .property("startIndex", \.startIndex)
    .property("endIndex", \.endIndex)
    .property("description", \.description)
    .property("debugDescription", \.debugDescription)
    .initializer(labels: ["text", "code", "signal"]) { (text: String, code: Int?, signal: Int?) in
        Output(text: text, code: code, signal: signal)
    }
}
