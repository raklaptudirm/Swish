import SwishKit
import Testing

private enum Level: String, CaseIterable, SwishEnum {
    case low, high
}

private struct Entry: Encodable {
    let name: String
    let size: Int
}

@Test func swiftValuesConvert() throws {
    #expect(try [Int](swishValue: .list([.int(1), .int(2)])) == [1, 2])
    #expect(try Int?(swishValue: .nothing) == nil)
    #expect(try Double(swishValue: .int(3)) == 3)
    #expect(try String(swishValue: .output(Output(text: "hi", code: 0))) == "hi")
    #expect([String].swishType == .list(.string))
    #expect(throws: SwishError.self) { try Int(swishValue: .string("x")) }
}

@Test func swishEnumsBridgeTheirCases() throws {
    let type = Level.swishEnumType
    #expect(type === Level.swishEnumType) // One type, so values compare equal.
    #expect(type.name == "Level")
    #expect(type.cases.map(\.name) == ["low", "high"])
    #expect(type.cases.map(\.rawValue) == [.string("low"), .string("high")])
    #expect(Level.high.swishValue == .enumValue(EnumValue(type: type, name: "high")))
    #expect(try Level(swishValue: .enumValue(EnumValue(type: type, name: "low"))) == .low)
    #expect([Level].swishEnums.map(\.name) == ["Level"])
}

@Test func resultsOfAnyKindBecomeValues() throws {
    #expect(try Value(returning: ()) == .nothing)
    #expect(try Value(returning: [1, 2]) == .list([.int(1), .int(2)]))
    #expect(try Value(returning: Entry(name: "a", size: 2)) == .record(Record(["name": .string("a"), "size": .int(2)])))
    #expect(try Value(returning: Level.low) == Level.low.swishValue)
}
