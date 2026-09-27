import SwishKit
import Testing

@Test func rendersScalars() {
    #expect(Value.int(42).description == "42")
    #expect(Value.string("hi").description == "hi")
    #expect(Value.nothing.description == "")
}

@Test func rendersNestedLists() {
    let value = Value.list([.int(1), .list([.bool(true), .string("x")])])
    #expect(value.description == "[1, [true, x]]")
}

private final class Stub: Callable {
    var description: String { "stub" }
}

@Test func functionsCompareByIdentity() {
    let stub = Stub()
    #expect(Value.function(stub) == .function(stub))
    #expect(Value.function(stub) != .function(Stub()))
    #expect(Set([Value.function(stub), .function(stub)]).count == 1)
    #expect(Value.function(stub).description == "stub")
}

@Test func commandOutputIsLines() {
    let output = CommandOutput(text: "a\nb", code: 0)
    #expect(output.lines == ["a", "b"])
    #expect(CommandOutput(text: "", code: 0).lines.isEmpty)
    #expect(Value.output(output).description == "a\nb")
    #expect(!CommandOutput(text: "", code: nil, signal: 15).succeeded)
}

private final class Thing: SwishObject {
    var typeName: String { "Thing" }
    var memberNames: [String] { ["size"] }
    var description: String { "a thing" }
    func member(_ name: String) -> Value? { name == "size" ? .int(3) : nil }
}

@Test func objectsCompareByIdentity() {
    let thing = Thing()
    #expect(Value.object(thing) == .object(thing))
    #expect(Value.object(thing) != .object(Thing()))
    #expect(Value.object(thing).description == "a thing")
}
