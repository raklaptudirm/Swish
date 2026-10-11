@_spi(Shell) import Swiit
@_spi(Shell) @testable import SwishShell
import SwishKit
import Testing

// What waits only through the shell's constructs is implicitly async: it is
// called with no `await`, by name or through a value (Docs/Design/async.md).

private func effect(of name: String, after source: String) throws -> Effect? {
    let shell = Shell()
    _ = try onLargeStack { try shell.capturing { shell.execute(source) } }
    guard case .function(let set as OverloadSet)? = shell.interpreter.lookup(name)?.value else { return nil }
    return set.candidates.first?.effect
}

private func run(_ source: String, in shell: Shell = Shell()) throws -> (output: String, status: Int32) {
    let output = try onLargeStack { try shell.capturing { shell.execute(source) } }
    return (output, shell.lastStatus)
}

@Test func whatWaitsOnTheShellIsImplicitlyAsync() throws {
    #expect(try effect(of: "build", after: "func build() { echo hi }") == .implicitAsync)
    #expect(try effect(of: "text", after: "func text() -> String { $(echo hi).text }") == .implicitAsync)
    #expect(try effect(of: "pure", after: "func pure() -> Int { 1 }") == .sync)
    #expect(try effect(of: "f", after: "func f() async -> Int { 1 }") == .async)
    // And what calls it, even declared before it.
    #expect(try effect(of: "outer", after: "func outer() { build() }; func build() { echo hi }") == .implicitAsync)
}

@Test func anImplicitlyAsyncFunctionIsCalledWithNoAwait() throws {
    #expect(try run("func build() { echo hi }; build(); let f = build; f()").output == "hi\nhi\n")
    // A closure that waits on the shell is implicitly async too.
    let shell = Shell()
    _ = try run("let c = { $(echo hi) }", in: shell)
    guard case .functionType(_, _, _, let effect)? = shell.interpreter.staticTypes["c"] else { Issue.record("not a function"); return }
    #expect(effect == .implicitAsync)
}

@Test func becomingAsyncIsRefusedWhileCallersDontAwait() throws {
    let shell = Shell()
    #expect(try run("func fetch() -> Int { 1 }; func use() -> Int { fetch() }", in: shell).status == 0)
    #expect(try run("func fetch() async -> Int { 2 }", in: shell).status == 2)
    // Redeclaring its caller with an `await` too is fine.
    #expect(try run("func use() async -> Int { await fetch() }; func fetch() async -> Int { 2 }; print(await use())", in: shell).output == "2\n")
}

@Test func becomingAsyncSaysWhoCallsIt() throws {
    let shell = Shell()
    _ = try run("func fetch() -> Int { 1 }; func use() -> Int { fetch() }", in: shell)
    guard case .success(let program) = shell.interpreter.parse("func fetch() async -> Int { 2 }") else { Issue.record(); return }
    #expect(throws: TypeError.self) { try TypeChecker(interpreter: shell.interpreter).check(program) }
    do {
        _ = try TypeChecker(interpreter: shell.interpreter).check(program)
    } catch {
        #expect(error.message == "fetch can't become async: 'use' calls it without 'await'")
    }
}
