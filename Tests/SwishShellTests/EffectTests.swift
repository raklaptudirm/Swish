@testable @_spi(Layer) import Swiit
@_spi(Shell) @_spi(Layer) @testable import SwishShell
import SwiitKit
import Testing

// The shell's waits (`$(…)`, commands, `await job`) are blocking calls, not
// effects: a function that runs commands is an ordinary function, and only
// Swift's own `async` needs `await` (https://github.com/raklaptudirm/Swiit/blob/main/Docs/async.md).

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

@Test func theShellsWaitsAreBlockingCalls() throws {
    #expect(try effect(of: "build", after: "func build() { echo hi }") == .sync)
    #expect(try effect(of: "text", after: "func text() -> String { $(echo hi).text }") == .sync)
    #expect(try effect(of: "f", after: "func f() async -> Int { 1 }") == .async)
    // Called by name or through a value, with no `await`; passed to Swift as any closure is.
    #expect(try run("func build() { echo hi }; build(); let f = build; f()").output == "hi\nhi\n")
    #expect(try run(#"print(["a", "b"].map { x in $(echo \(x)).text })"#).output == "[\"a\", \"b\"]\n")
    // `async $(…)` is what runs it in the background; `await` joins it.
    #expect(try run("let j = async $(echo hi); print((await j).text)").output == "hi\n")
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

// Errors of your own, in the shell: thrown, caught by pattern, and a failed
// command's among them.

@Test func errorsOfYourOwnInTheShell() throws {
    let source = """
    struct Oops: Error { let code: Int }
    func f() throws { throw Oops(code: 4) }
    do { try f() } catch let e as Oops { echo "oops \\(e.code)" }
    do { try $(sh -c 'exit 3') } catch let failure as CommandFailure { echo "status \\(failure.status.code)" }
    """
    #expect(try run(source).output == "oops 4\nstatus 3\n")
    // Nothing catching it, it's reported, and the status is a failure.
    let uncaught = try run("struct Oops: Error {}; throw Oops()")
    #expect(uncaught.status == 1)
}
