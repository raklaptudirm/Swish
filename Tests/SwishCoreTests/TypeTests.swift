@testable import SwishCore
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

/// The type error `source` has, or nil if it checks.
private func typeError(_ source: String, in shell: Shell = Shell()) -> String? {
    guard case .success(let program) = Result(catching: { try Parser.parse(source, bound: shell.globalNames()) }) else {
        return "syntax error"
    }
    do {
        try TypeChecker(shell: shell).check(program)
        return nil
    } catch {
        return error.message
    }
}

@Test func typeErrorsStopBeforeAnythingRuns() throws {
    let shell = Shell()
    #expect(try output(#"echo before; let x: Int = "a""#, in: shell) == "")
    #expect(shell.lastStatus == 2)
    #expect(typeError(#"let x: Int = "a""#) == "the value must be Int, not String")
}

@Test func declarationsAndInference() {
    #expect(typeError("let xs: [Int] = []; let d: [String: Int] = [:]; let t: (Int, name: String) = (1, name: \"x\")") == nil)
    #expect(typeError("let xs = []")?.hasPrefix("an empty list needs a type") == true)
    #expect(typeError("let x = nil")?.hasPrefix("'nil' needs a type") == true)
    #expect(typeError(#"let xs = [1, "x"]"#)?.hasPrefix("a list's elements must have one type") == true)
    #expect(typeError(#"let xs: [Any] = [1, "x", nil]"#) == nil)
    #expect(typeError(#"let d = ["a": 1, "b": "x"]"#)?.contains("write a tuple") == true)
    // Later entries at the prompt know what earlier ones declared.
    let shell = Shell()
    shell.execute("let xs: [Int] = []")
    #expect(typeError("xs + [1]", in: shell) == nil)
    #expect(typeError(#"xs + ["a"]"#, in: shell) != nil)
}

@Test func numbersFollowSwift() throws {
    #expect(try output("1 + 2.5; let d: Double = 1; d") == "3.5\n1.0\n")
    #expect(typeError("let i = 1; i * 2.5") == "'*' can't be applied to Int and Double")
    #expect(typeError("1.kb * 2; 2.mb / 1.mb; 3 % 2") == nil)
}

@Test func functionsReturnWhatTheySay() throws {
    #expect(try output("func f() { 42 }; f()") == "")
    #expect(typeError("func f() -> Int { \"no\" }") == "f's result must be Int, not String")
    #expect(typeError("func f(_ b: Bool) -> Int { if b { return 1 } }") == "f must return Int on every path")
    #expect(typeError("func f(_ b: Bool) -> Int { if b { return 1 } else { return 2 } }") == nil)
    #expect(typeError("func f() { return 1 }")?.hasPrefix("a function without '->' returns nothing") == true)
    #expect(typeError("func f(_ x: Int) -> Int { x }; f(\"s\")") == "f: 'x' must be Int, not String")
    #expect(typeError("func f(_ x: Int) -> Int { x }; f(1) + \"s\"") == "'+' can't be applied to Int and String")
}

@Test func tuplesAndDictionaries() throws {
    #expect(try output(#"let t = (name: "x", 2); t.name; t.1; t"#) == "\"x\"\n2\n(name: \"x\", 2)\n")
    #expect(try output(#"[(n: 5, s: "a"), (n: 1, s: "b")] | sorted --by n | get s"#) == "b\na\n")
    #expect(try output(#"var d = ["a": 1]; d["b"] = 2; d["a"]; d["a"]! + 1; d.keys"#) == "1\n2\n[\"a\", \"b\"]\n")
    #expect(typeError(#"let t = (name: "x", 2); t.nope"#) == "(name: String, Int) has no element 'nope'")
}

@Test func optionalsMustBeUnwrapped() throws {
    #expect(try output("let x: Int? = nil; x ?? 3; let s: String? = \"ab\"; s?.count; s!.count") == "3\n2\n2\n")
    #expect(typeError("let s: String? = \"ab\"; s.count")?.hasPrefix("String? might be nil") == true)
    #expect(typeError("let s = \"ab\"; s!")?.hasPrefix("'!' unwraps an optional") == true)
    let shell = Shell()
    _ = try output("let x: Int? = nil; x!", in: shell)
    #expect(shell.lastStatus == 1) // at run time: nil can only be found then
}

@Test func closuresTakeTypesFromContext() throws {
    #expect(try output("[1, 2, 3].filter { $0 > 1 }.map { $0 * 10 }") == "[20, 30]\n")
    #expect(typeError(#"[1, 2].filter { $0 > "a" }"#) == "'>' can't be applied to Int and String")
    #expect(typeError(#"[1, 2].map { $0.count }"#) == "Int has no member 'count'")
}

@Test func structsAndEnumsAreChecked() {
    let point = "struct Point { var x: Int; let id = 0; mutating func move() { x += 1 } }; "
    #expect(typeError(point + #"Point(x: "a")"#) == "Point: 'x' must be Int, not String")
    #expect(typeError(point + "let p = Point(x: 1); p.move()") == "cannot use mutating method 'move' on 'p': it's a 'let' constant")
    #expect(typeError(point + "var p = Point(x: 1); p.id = 2") == "cannot assign to 'id': it's a 'let' property of Point")
    let kind = "enum Kind { case file, dir }; "
    #expect(typeError(kind + "let k: Kind = .file; k == .dir") == nil)
    #expect(typeError(kind + "let k: Kind = .socket") == "Kind has no case 'socket'")
}

@Test func scriptsAreCheckedWholeWithLines() throws {
    let shell = Shell()
    let path = try output("mktemp", in: shell).trimmingCharacters(in: .newlines)
    shell.execute(#"printf '%s\n' 'echo one' '' 'let x: Int = "a"' > \#(path)"#)
    // A fresh shell runs the file: the error on line 3 stops line 1 too.
    let script = Shell()
    let printed = try onLargeStack { try script.capturing { _ = script.runScript(at: path) } }
    #expect(printed == "") // `echo one` didn't run
    #expect(script.lastStatus == 2)
}
