@_spi(Layer) import Swiit
@_spi(Shell) @_spi(Layer) @testable import SwishShell
import SwiitKit
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

@Test func capturedVariablesAreShared() throws {
    #expect(try output("func makeCounter() -> () -> Int { var n = 0; return { n += 1; return n } }; let c = makeCounter(); c(); c()") == "1\n2\n")
    #expect(try output("func f() -> Int { var n = 0; let inc = { n += 1 }; inc(); inc(); return n }; f()") == "2\n")
    // A nested function reaches itself when called after its maker returned.
    #expect(try output("func make() -> (Int) -> Int { func fact(_ n: Int) -> Int { if n <= 1 { return 1 }; return n * fact(n - 1) }; return fact }; make()(5)") == "120\n")
}
