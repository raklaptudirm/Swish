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
