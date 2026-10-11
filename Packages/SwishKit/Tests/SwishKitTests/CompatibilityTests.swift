import SwishKit
import Testing

// Code written against SwishKit, SwiitKit's old name, still builds.

/// Greets someone, as a plugin written against SwishKit exports it.
@SwishExport
public func greetOldStyle(_ name: String) -> String { "hello \(name)" }

public enum OldLevel: String, CaseIterable, SwishEnum {
    case low, high
}

@Test func theOldNamesStillWork() throws {
    let error: SwishError = SwishError("no")
    #expect("\(error)".contains("no"))
    let value: SwishValue = .string("x")
    #expect(value == .string("x"))
    #expect(OldLevel.allCases.count == 2)
}
