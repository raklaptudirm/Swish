@testable @_spi(Layer) import Swiit
@_spi(Shell) @_spi(Layer) @testable import SwishShell
import Testing

/// Swift's syntax alone, or with the shell's added.
private enum Dialect {
    case swift, shell

    var plugin: (any SyntaxPlugin)? { self == .shell ? LayerPlugin(ShellSyntax()) : nil }
}

/// The syntax error that stops `source`, or nil if it parses.
private func syntaxError(_ source: String, _ dialect: Dialect, bound: [String: NameKind] = [:]) -> String? {
    do {
        _ = try SwiftSyntaxFrontEnd().parse(source, bound: bound, plugin: dialect.plugin)
        return nil
    } catch {
        return error.description
    }
}

@Test func swiftCodeParsesInBothDialects() {
    let program = """
    let x = 1 + 2
    func double(_ n: Int) -> Int { n * 2 }
    struct P { var a: Int; static let origin = P(a: 0) }
    enum Level { case low, high }
    let ys = [3, 1, 2].map { $0 * 2 }.sorted { $0 > $1 }
    for i in 0..<3 { i }
    if x > 1 && ys.count == 3 { double(x) } else { P.origin }
    let r = try? double(x)
    switch x { case 3: x; default: 0 }
    """
    #expect(syntaxError(program, .swift) == nil)
    #expect(syntaxError(program, .shell) == nil)
}

@Test func shellSyntaxIsRefusedInSwiftOnlyCode() {
    // Each of these is the shell's: the Swift dialect says so, where the shell dialect parses it.
    let cases: [(source: String, says: String)] = [
        // Two words side by side are two statements in Swift, and swiftc says the same.
        ("ls -la", "expected ';'"),
        ("git status", "expected ';'"),
        ("let h = $(echo hi)", "$(…) runs commands"),
        ("let h = $HOME", "$name reads the environment"),
        ("async sleep 1", "'async' starts a command"),
    ]
    for (source, says) in cases {
        let error = syntaxError(source, .swift)
        #expect(error?.contains(says) == true, "\(source) -> \(error ?? "parsed")")
        #expect(syntaxError(source, .shell) == nil, "\(source) should parse as the shell's")
    }
}

@Test func aBarIsBitwiseOrInSwiftOnlyCodeAndAPipeInTheShells() {
    // The same text: Swift reads an operator, which the checker would refuse
    // between a list and a name; the shell reads a pipe.
    let source = "let xs = [3, 1]\nxs | sorted"
    #expect(syntaxError(source, .swift) == nil)
    #expect(syntaxError(source, .shell) == nil)
    #expect(syntaxError("let a = 6 | 1", .swift) == nil)
}

@Test func aFunctionNamedAsACommandIsNotOneInSwiftOnlyCode() {
    // `greet Rak` is a call in the shell, and two things side by side in Swift.
    let bound: [String: NameKind] = ["greet": .function]
    #expect(syntaxError("greet Rak", .shell, bound: bound) == nil)
    #expect(syntaxError("greet Rak", .swift, bound: bound) != nil)
    #expect(syntaxError(#"greet("Rak")"#, .swift, bound: bound) == nil)
}

@Test func theShellSpeaksTheShellsDialectAndTheCoreSpeaksSwift() {
    #expect(Interpreter().syntax == nil)
    #expect(Shell().interpreter.syntax != nil)
}
