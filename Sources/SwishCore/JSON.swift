import Foundation
import SwishKit

/// JSON with object keys kept in order, which Foundation's parser doesn't
/// do and which tables need: key order is column order.
enum JSON {
    static func parse(_ text: String) throws -> Value {
        var parser = JSONParser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("unexpected text after the JSON value") }
        return value
    }

    static func text(_ value: Value, indent: String = "") throws -> String {
        let inner = indent + "  "
        switch value {
        case .nothing: return "null"
        case .bool(let bool): return String(bool)
        case .int(let int): return String(int)
        case .double(let double):
            guard double.isFinite else { throw RuntimeError("to json: \(double) isn't valid JSON") }
            return String(double)
        case .string(let string): return quoted(string)
        case .output(let output): return quoted(output.text)
        case .enumValue(let value):
            // A raw value, or the case's name; with associated values, a
            // record of them under the case's name.
            if let raw = value.rawValue { return try text(raw, indent: indent) }
            guard !value.values.isEmpty else { return quoted(value.name) }
            var record = Record()
            for (index, item) in value.values.enumerated() {
                let label = value.definition?.labels[index] ?? nil
                record[label ?? String(index)] = item
            }
            return try text(.record(Record([value.name: .record(record)])), indent: indent)
        case .filesize(let bytes): return String(bytes)
        case .date(let date): return quoted(date.formatted(.iso8601))
        case .list(let items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + (try items.map { inner + (try text($0, indent: inner)) }).joined(separator: ",\n") + "\n\(indent)]"
        case .record(let record):
            guard record.count > 0 else { return "{}" }
            let fields = try record.map { inner + quoted($0.key) + ": " + (try text($0.value, indent: inner)) }
            return "{\n" + fields.joined(separator: ",\n") + "\n\(indent)}"
        case .dictionary(let dictionary):
            guard dictionary.count > 0 else { return "{}" }
            let fields = try dictionary.sortedForDisplay.map { key, value in
                guard case .string(let name) = key else {
                    throw RuntimeError("to json: an object's keys are Strings, not \(key.typeName)")
                }
                return inner + quoted(name) + ": " + (try text(value, indent: inner))
            }
            return "{\n" + fields.joined(separator: ",\n") + "\n\(indent)}"
        case .function:
            throw RuntimeError("to json: a function has no JSON form")
        case .object(let object):
            if let fields = object.fields { return try text(.record(fields), indent: indent) }
            // What a string literal can be (a FilePath, a Character) is its text.
            if let box = object as? SwiftValue, Bridge.isStringLiteral(box.typeName) { return quoted(box.description) }
            throw RuntimeError("to json: a \(object.typeName) has no JSON form")
        @unknown default:
            throw RuntimeError("to json: unsupported value")
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

    func error(_ message: String) -> RuntimeError {
        RuntimeError("from json: \(message) at byte \(index)")
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
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .nothing
        default: return try parseNumber()
        }
    }

    private mutating func parseObject() throws -> Value {
        index += 1
        var record = Record()
        skipWhitespace()
        if index < bytes.count && bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .record(record)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key") }
            let key = try parseString()
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            record[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated object") }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .record(record)
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
            return .list(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("unterminated array") }
            if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .list(items)
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
        if let int = Int(text) { return .int(int) }
        if let double = Double(text), !text.isEmpty { return .double(double) }
        index = start
        throw error("unexpected character")
    }
}
