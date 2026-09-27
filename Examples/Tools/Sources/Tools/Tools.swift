import Foundation
import SwishKit

/// Greets someone.
/// - Parameter times: how many times to greet
@SwishExport
public func greet(_ name: String, @Flag("n") times: Int = 1, loud: Bool = false) -> [String] {
    Array(repeating: loud ? "HELLO \(name.uppercased())" : "hello \(name)", count: times)
}

/// The longest line piped in.
@SwishExport
public func longest(@Input _ lines: [String]) -> String? {
    lines.max { $0.count < $1.count }
}

/// Doubles each number piped in.
@SwishExport
public func double(@Input _ n: Int) -> Int {
    n * 2
}

public enum Level: String, CaseIterable, SwishEnum {
    case low, high
}

/// Says how loud a level is.
@SwishExport
public func volume(_ level: Level = .low) -> Int {
    level == .low ? 1 : 11
}

/// A word and how often it appears.
public struct WordCount: Encodable {
    public let word: String
    public let count: Int
}

/// Counts words in the text piped in.
@SwishExport
public func words(@Input _ text: [String]) -> [WordCount] {
    var counts: [String: Int] = [:]
    for line in text {
        for word in line.split(separator: " ") { counts[String(word), default: 0] += 1 }
    }
    return counts.map { WordCount(word: $0.key, count: $0.value) }.sorted { ($0.count, $1.word) > ($1.count, $0.word) }
}

/// Fails, to show how plugin errors read.
@SwishExport
public func fail(_ message: String) throws {
    throw SwishError(message)
}

/// A running tally: a live object.
@SwishObject
public final class Counter {
    public private(set) var total = 0
    public let name: String

    init(name: String) { self.name = name }

    /// Adds to the tally.
    public func add(_ amount: Int = 1) -> Int {
        total += amount
        return total
    }
}

/// Starts a tally.
@SwishExport
public func counter(_ name: String, since: Date = Date()) -> Counter {
    Counter(name: name)
}

