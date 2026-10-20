import Foundation
import Swiit

/// Parsed JSON: whatever it parsed as, a `Value`, which Swish reads by field
/// and element. Object keys are kept in order, which Foundation's parser
/// doesn't do and which tables need: key order is column order.
struct JSON {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public static func parse(_ text: String) throws -> Value {
        var parser = JSONParser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("unexpected text after the JSON value") }
        return value
    }

    /// A value as JSON text, indented two spaces to a level.
    public static func text(_ value: Value, indent: String = "") throws -> String {
        let inner = indent + "  "
        switch value.kind {
        case .nothing: return "null"
        case .bool: return String(value.cast(to: Bool.self)!)
        case .int: return String(value.cast(to: Int.self)!)
        case .double:
            let double = value.cast(to: Double.self)!
            guard double.isFinite else { throw LibraryError("to json: \(double) isn't valid JSON") }
            return String(double)
        case .string: return quoted(value.description)
        case .enumeration:
            // A raw value, or the case's name; with associated values, a
            // struct of them under the case's name.
            guard let found = value.enumCase else { return "null" }
            if let raw = value.rawValue { return try text(raw, indent: indent) }
            guard !found.values.isEmpty else { return quoted(found.name) }
            let fields = found.values.enumerated().map { index, item in (name: (found.labels.indices.contains(index) ? found.labels[index] : nil) ?? String(index), value: item) }
            return try text(Value(struct: nil, fields: [(name: found.name, value: Value(struct: nil, fields: fields))]), indent: indent)
        case .list:
            let items = value.cast(to: [Value].self) ?? []
            guard !items.isEmpty else { return "[]" }
            return "[\n" + (try items.map { inner + (try text($0, indent: inner)) }).joined(separator: ",\n") + "\n\(indent)]"
        case .structure, .tuple:
            guard let record = value.fields, record.count > 0 else { return "{}" }
            let fields = try record.map { inner + quoted($0.key) + ": " + (try text($0.value, indent: inner)) }
            return "{\n" + fields.joined(separator: ",\n") + "\n\(indent)}"
        case .dictionary:
            guard let dictionary = value.entries, dictionary.count > 0 else { return "{}" }
            let fields = try dictionary.sortedForDisplay.map { key, value in
                guard let name = key.cast(to: String.self) else {
                    throw LibraryError("to json: an object's keys are Strings, and \(key.debugDescription) isn't one")
                }
                return inner + quoted(name) + ": " + (try text(value, indent: inner))
            }
            return "{\n" + fields.joined(separator: ",\n") + "\n\(indent)}"
        case .function:
            throw LibraryError("to json: a function has no JSON form")
        case .object:
            if let fields = value.fields { return try text(Value(struct: nil, fields: fields.entries.map { ($0.key, $0.value) }), indent: indent) }
            // What stands for text is its text; else a Swift value is as Swift
            // encodes it (a file size is its bytes).
            if let held = try? value.unboxed(Any.self) {
                if let text = (held as? any StandsForText)?.text { return quoted(text) }
                // What a text literal can be, like a FilePath.
                if held is any ExpressibleByUnicodeScalarLiteral { return quoted(value.description) }
                if let encodable = held as? any Encodable {
                    // A date as ISO 8601 text, not Swift's number of seconds.
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    return String(decoding: try encoder.encode(AnyEncodable(value: encodable)), as: UTF8.self)
                }
            }
            throw LibraryError("to json: a \(value.typeName) has no JSON form")
        }
    }

    private struct AnyEncodable: Encodable {
        let value: any Encodable
        // Through a container, which is what applies the encoder's strategy for dates.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }
    }

    private static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0

    func error(_ message: String) -> LibraryError {
        LibraryError("from json: \(message) at byte \(index)")
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func expect(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard bytes[index...].starts(with: expected) else { throw error("expected '\(literal)'") }
        index += expected.count
    }

    mutating func parseValue() throws -> Value {
        guard index < bytes.count else { throw error("unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return Value(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return Value(true)
        case UInt8(ascii: "f"): try expect("false"); return Value(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        default: return try parseNumber()
        }
    }

    private mutating func parseObject() throws -> Value {
        index += 1
        var fields: [(name: String, value: Value)] = []
        skipWhitespace()
        if index < bytes.count && bytes[index] == UInt8(ascii: "}") {
            index += 1
            return Value(struct: nil, fields: fields)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key") }
            let key = try parseString()
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            let value = try parseValue()
            if let existing = fields.firstIndex(where: { $0.name == key }) { fields[existing].value = value } else { fields.append((key, value)) }
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated object") }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return Value(struct: nil, fields: fields)
            }
            try expect(",")
        }
    }

    private mutating func parseArray() throws -> Value {
        index += 1
        var items: [Value] = []
        skipWhitespace()
        if index < bytes.count && bytes[index] == UInt8(ascii: "]") {
            index += 1
            return Value(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated array") }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return Value(items)
            }
            try expect(",")
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var run: [UInt8] = []
        func flushRun() {
            scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars)
            run = []
        }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                flushRun()
                return String(scalars)
            case UInt8(ascii: "\\"):
                flushRun()
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "u"):
                    var code = try parseHex4()
                    // A surrogate pair encodes one scalar beyond the BMP.
                    if (0xD800..<0xDC00).contains(code), bytes[index...].starts(with: Array("\\u".utf8)) {
                        index += 2
                        let low = try parseHex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: scalars.append(Unicode.Scalar(escape))
                }
            default:
                run.append(byte)
            }
        }
        throw error("unterminated string")
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let code = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else {
            throw error("invalid \\u escape")
        }
        index += 4
        return code
    }

    private mutating func parseNumber() throws -> Value {
        let start = index
        while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) { index += 1 }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if let int = Int(text) { return Value(int) }
        if let double = Double(text), !text.isEmpty { return Value(double) }
        index = start
        throw error("unexpected character")
    }
}
