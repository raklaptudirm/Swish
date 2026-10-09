@_spi(Shell) import Swiit
@_spi(Shell) @testable import SwishShell
import SwishKit
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

/// A closure keeps only the variables it names, not the scopes around it:
/// keeping the scope it's stored in was a cycle, leaked on every call.
@Test func closuresKeepOnlyWhatTheyUse() throws {
    let shell = Shell()
    #expect(try output("func f(_ i: Int) -> () -> Int { let g = { i + 1 }; let unused = [1, 2]; return g }; let h = f(1); h()", in: shell) == "2\n")
    guard case .function(let closure as Function)? = shell.interpreter.lookup("h")?.value else {
        Issue.record("h isn't a closure")
        return
    }
    let capture = try #require(closure.captured.last)
    #expect(capture.bindings.keys.sorted() == ["i"])
    // The call's scope, which held `g` and `unused`, is gone once it returned.
    #expect(!capture.fallbacks.isEmpty && capture.fallbacks.allSatisfy { $0.scope == nil })
}

@Test func capturedVariablesAreShared() throws {
    #expect(try output("func makeCounter() -> () -> Int { var n = 0; return { n += 1; return n } }; let c = makeCounter(); c(); c()") == "1\n2\n")
    #expect(try output("func f() -> Int { var n = 0; let inc = { n += 1 }; inc(); inc(); return n }; f()") == "2\n")
    // A nested function reaches itself when called after its maker returned.
    #expect(try output("func make() -> (Int) -> Int { func fact(_ n: Int) -> Int { if n <= 1 { return 1 }; return n * fact(n - 1) }; return fact }; make()(5)") == "120\n")
}
