@testable import SwishCore
import SwishKit
import Testing

/// The syntax error that stops `source`, or nil if it parses.
private func syntaxError(_ source: String, _ dialect: Parser.Dialect, bound: [String: NameKind] = [:]) -> String? {
    do {
        _ = try Parser.parse(source, bound: bound, dialect: dialect)
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
        ("ls -la", "no variable named 'ls'"),
        ("git status", "no variable named 'git'"),
        ("try make", "no variable named 'make'"),
        ("let xs = [3, 1]\nxs | sorted", "'|' pipes commands"),
        ("let h = $(echo hi)", "$(…) runs commands"),
        ("let h = $HOME", "$name reads the environment"),
        ("async sleep 1", "'async' starts a command"),
        (#"import Tools from "./Tools""#, "importing a package from a path is shell syntax"),
    ]
    for (source, says) in cases {
        let error = syntaxError(source, .swift)
        #expect(error?.contains(says) == true, "\(source) -> \(error ?? "parsed")")
        #expect(syntaxError(source, .shell) == nil, "\(source) should parse as the shell's")
    }
}

@Test func aFunctionNamedAsACommandIsNotOneInSwiftOnlyCode() {
    // `greet Rak` is a call in the shell, and two things side by side in Swift.
    let bound: [String: NameKind] = ["greet": .function]
    #expect(syntaxError("greet Rak", .shell, bound: bound) == nil)
    #expect(syntaxError("greet Rak", .swift, bound: bound) != nil)
    #expect(syntaxError(#"greet("Rak")"#, .swift, bound: bound) == nil)
}

@Test func theShellSpeaksTheShellsDialectAndTheCoreSpeaksSwift() {
    #expect(Interpreter().dialect == .swift)
    #expect(Shell().interpreter.dialect == .shell)
}

/// What a script wrote and how it ended, run on an `Interpreter` alone: no
/// `Shell`, no layer, only a host that collects output.
private func runOnTheCore(_ source: String) -> (output: String, problem: String?) {
    var output = ""
    let host = SwishHost(output: OutputSink(write: { output += $0; return true }),
                         error: OutputSink(write: { output += "err: " + $0; return true }))
    let interpreter = Interpreter(host: host)
    // The prelude declares the shell's `help`, and the shell supplies its body.
    interpreter.installBuiltinFunctions(providing: ["help": .native { _, _ in .nothing }])
    switch interpreter.parse(source) {
    case .failure(let error):
        return (output, "syntax error: \(error)")
    case .success(let program):
        do {
            let checked = try TypeChecker(interpreter: interpreter).check(program)
            _ = try interpreter.run(checked)
            return (output, nil)
        } catch let error as TypeError {
            return (output, "error: \(error.message)")
        } catch {
            return (output, "error: \(error)")
        }
    }
}

@Test func theCoreRunsSwiftWithoutAShell() {
    let (output, problem) = runOnTheCore("""
    let xs = [3, 1, 2]
    xs.sorted()
    struct P { var x: Int; static let origin = P(x: 0) }
    P(x: 1)
    P.origin
    func double(_ n: Int) -> Int { n * 2 }
    xs.map { double($0) }
    """)
    #expect(problem == nil)
    #expect(output == "[1, 2, 3]\nP(x: 1)\nP(x: 0)\n[6, 2, 4]\n")
}

@Test func theCoreRefusesWhatItWasNotGiven() {
    // Shell syntax doesn't parse, and the environment, which no layer gives, reads as empty.
    #expect(runOnTheCore("git status").problem?.contains("no variable named 'git'") == true)
    #expect(runOnTheCore("let h = $(echo hi)").problem?.contains("runs commands") == true)
    let (output, problem) = runOnTheCore(#"let h = env.HOME; h ?? "none""#)
    #expect(problem == nil)
    #expect(output == "\"none\"\n")
}
