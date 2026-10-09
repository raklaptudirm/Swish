@testable import Swiit
@testable import SwishShell
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

/// The type error `source` has, or nil if it checks.
private func typeError(_ source: String, in shell: Shell = Shell()) -> String? {
    guard case .success(let program) = Result(catching: { try Parser.parse(source, bound: shell.interpreter.globalNames(), plugin: shell.interpreter.syntax) }) else {
        return "syntax error"
    }
    do {
        _ = try TypeChecker(interpreter: shell.interpreter).check(program)
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
    #expect(try output(#"var d = ["a": 1]; d["b"] = 2; d["a"]; d["a"]! + 1; d.keys.sorted()"#) == "1\n2\n[\"a\", \"b\"]\n")
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

// MARK: Phase 2: functions as values, overloads, throws

@Test func overloadsAreChosenStatically() throws {
    let g = #"func g(_ x: Any) -> String { "any" }; func g(_ x: Int) -> String { "int" }; "#
    // The static type decides, as in Swift: `a` is an Any, though it holds an Int.
    #expect(try output(g + "let a: Any = 5; g(a); g(5)") == "\"any\"\n\"int\"\n")
    #expect(try output(#"func f(_ x: Int) -> String { "int" }; func f(_ x: Double) -> String { "double" }; f(5); f(5.5)"#)
        == "\"int\"\n\"double\"\n")
    #expect(typeError("func h(_ x: Int, y: Int = 0) {}; func h(_ x: Int, z: Int = 0) {}; h(1)")?.hasPrefix("h: ambiguous call") == true)
}

@Test func functionsAreValues() throws {
    #expect(try output("func double(_ x: Int) -> Int { x * 2 }; [1, 2].map(double).map { $0 + 1 }") == "[3, 5]\n")
    // An overloaded name is picked by the type wanted.
    let conv = #"func conv(_ x: Int) -> String { "int" }; func conv(_ x: String) -> String { "string" }; "#
    #expect(try output(conv + "let f: (String) -> String = conv; f(\"a\")") == "\"string\"\n")
    #expect(try output("func apply(_ f: (Int) -> Int, _ x: Int) -> Int { f(x) }; apply({ $0 * 3 }, 2)") == "6\n")
    #expect(typeError("func apply(_ f: (Int) -> Int) -> Int { f(1) }; apply({ $0 + \"a\" })") == "'+' can't be applied to Int and String")
}

@Test func closuresInferTheirResult() throws {
    let sign = "let sign = { (x: Int) in\n    if x > 0 { return \"pos\" }\n    return \"neg\"\n}\n"
    #expect(try output(sign + "sign(-1).count") == "3\n")
    #expect(typeError(sign + "sign(1) + 1") == "'+' can't be applied to String and Int")
}

@Test func throwingNeedsTryAndAHandler() throws {
    let risky = "func risky(_ fail: Bool) throws -> Int { if fail { try $(false) }; return 1 }\n"
    #expect(try output(risky + "try risky(false); do { try risky(true) } catch { echo caught }; (try? risky(true)) ?? 0")
        == "1\ncaught\n0\n")
    #expect(typeError(risky + "risky(false)") == "'risky' can throw, but isn't marked with 'try'")
    #expect(typeError(risky + "func safe() -> Int { try risky(false) }")?.hasPrefix("this can throw, but safe isn't 'throws'") == true)
    #expect(typeError(risky + "func safe() -> Int { (try? risky(false)) ?? 0 }") == nil)
    #expect(typeError("func build() { try $(swift build) }")?.contains("build isn't 'throws'") == true)
    #expect(typeError("func build() { try false }")?.contains("build isn't 'throws'") == true)
    // Closures throw if their body does; passing one on makes the call throw.
    #expect(typeError(risky + "[true].map { try risky($0) }") == "'map' can throw, but isn't marked with 'try'")
    #expect(typeError(risky + "let r = try [false].map { try risky($0) }") == nil)
    #expect(typeError(risky + "func apply(_ f: (Bool) -> Int) -> Int { f(true) }; apply({ try risky($0) })")
        == "apply: 'f' must be (Bool) -> Int, not (Bool) throws -> Int")
    #expect(typeError(risky + "func apply(_ f: (Bool) throws -> Int) rethrows -> Int { 0 }") == "syntax error")
    #expect(typeError(risky + "func apply(_ f: (Bool) throws -> Int) throws -> Int { try f(true) }; try apply({ try risky($0) })") == nil)
}

@Test func tryOnAVoidCallTellsSuccessFromFailure() throws {
    let funcs = "func build() throws { try $(true) }; func fail() throws { try $(false) }; "
    #expect(try output(funcs + "(try? build()) != nil; (try? fail()) != nil; try? build()") == "true\nfalse\n")
    #expect(try output(funcs + "if try? build() { echo yes }; if try? fail() { echo no } else { echo failed }") == "yes\nfailed\n")
    #expect(typeError("let x: Int? = 1; if x { echo y }") == "a condition must be a Bool, not Int?")
}

// MARK: Phase 3: protocols, key paths, the prelude, typed pipelines

@Test func protocolsAreDeclaredAndChecked() throws {
    #expect(try output("struct P: Equatable { var x: Int }; P(x: 1) == P(x: 1)") == "true\n")
    #expect(typeError("struct P { var x: Int }; P(x: 1) == P(x: 1)")?.hasPrefix("'==' needs Equatable values") == true)
    #expect(typeError("struct P: Equatable { var f: (Int) -> Int }") == "P can't be Equatable: its 'f' is (Int) -> Int, which isn't")
    #expect(typeError("struct P: Comparable { var x: Int }")?.hasPrefix("P can't be Comparable yet") == true)
    #expect(typeError("struct P: Frobbable {}")?.hasPrefix("syntax error") == true)
    // An enum without associated values is Equatable anyway; one with them says so.
    #expect(typeError("enum K { case a, b }; K.a == .b") == nil)
    #expect(typeError("enum R { case ok, failed(Int) }; R.ok == .ok")?.hasPrefix("'==' needs Equatable values") == true)
    #expect(typeError("enum R: Equatable { case ok, failed(Int) }; R.ok == .ok") == nil)
    #expect(typeError("enum L: Int, Comparable { case low, high }; L.low < .high") == nil)
}

@Test func keyPaths() throws {
    #expect(try output(#"let xs = [(n: 2, s: "b"), (n: 1, s: "a")]; xs.sorted(by: \.n).map(\.s); xs.map(\.n)"#) == "[\"a\", \"b\"]\n[2, 1]\n")
    #expect(typeError(#"let xs = [(n: 2, s: "b")]; xs.sorted(by: \.m)"#) == "(n: Int, s: String) has no element 'm'")
    #expect(typeError("let k = \\.size")?.hasPrefix("\\.size needs a type here") == true)
    #expect(typeError("let k = \\FileEntry.size") == nil)
}

@Test func builtinsHaveTypes() throws {
    // `ls` gives FileEntries, `ps` ProcessEntries: fields are checked.
    #expect(typeError("let files = ls(); files.filter { $0.type == .directory }.map(\\.name)") == nil)
    #expect(typeError("ls().filter { $0.sise > 1.kb }") == "FileEntry has no member 'sise'")
    #expect(typeError("ls().map { $0.size } + [1]") != nil)
    // Generic constraints: sorting needs Comparable items, or a field that is.
    #expect(typeError("[(n: 1)].sorted()") == "sorted needs Element to be Comparable, and (n: Int) isn't")
    #expect(try output("[3, 1, 3, 2].uniqued().sorted()") == "[1, 2, 3]\n")
}

@Test func pipelinesAreTypedStageByStage() throws {
    #expect(typeError("ls | sorted --by sise") == "FileEntry has no member 'sise'")
    #expect(typeError("ls | filter { $0.size > 1 }") == "'>' can't be applied to FileSize and Int")
    #expect(typeError("ls | prefix x") == "prefix: <maxLength> must be Int, got 'x'")
    #expect(typeError("ls | get name | map { $0.count } | filter { $0 > \"a\" }") == "'>' can't be applied to Int and String")
    #expect(typeError("[(n: 1)] | sorted") == "sorted needs Element to be Comparable, and (n: Int) isn't")
    // Programs give lines of text.
    #expect(typeError("printf 'a' | filter { $0.count > 1 }") == nil)
    #expect(typeError("printf 'a' | filter { $0.size > 1 }") == "String has no member 'size'")
    // `select` makes a tuple of the fields it picks.
    #expect(try output("[(n: 2, s: \"b\"), (n: 1, s: \"a\")] | select n | sorted --by n | get n") == "1\n2\n")
    #expect(typeError("ls | select name size | filter { $0.modified > $0.modified }") == "(name: String, size: FileSize) has no element 'modified'")
}

@Test func stagesAreResolvedFromTheirInput() throws {
    let point = #"struct Point { var x: Int; func describe() -> String { "p\(x)" } }; "#
    #expect(try output(point + "[Point(x: 1), Point(x: 2)] | describe") == "p1\np2\n")
    // `cancel` on jobs is the method, not /usr/bin/cancel; on text, the program.
    let shell = Shell()
    _ = try output("func describe() {}", in: shell)
    #expect(typeError(point + "[Point(x: 1)] | describe | filter { $0.count > 1 }") == nil)
}

@Test func comparableEnumsCompareInDeclarationOrder() throws {
    let level = "enum Level: Int, Comparable { case low, mid, high }; "
    #expect(try output(level + "Level.low < .high; Level.high <= .mid; [Level.high, .low] | sorted") == "true\nfalse\nlow\nhigh\n")
}

// MARK: Phase 4: Any and JSON

@Test func anyNeedsACast() throws {
    #expect(try output("let x: Any = 5; x as? Int; x as? String; x is Int; (x as! Int) + 1") == "5\ntrue\n6\n")
    #expect(typeError("let x: Any = 5; x.count")?.hasPrefix("an Any has no members") == true)
    #expect(typeError("let x: Any = 5; x + 1") == "'+' can't be applied to Any and Int")
    #expect(typeError("let x: Any = [1]; x[0]")?.hasPrefix("an Any can't be indexed") == true)
    #expect(typeError("let x = 5; x as String")?.hasPrefix("'as' can't make a Int a String") == true)
    #expect(typeError("let x = 5; let y = x as Any") == nil)
    let shell = Shell()
    _ = try output(#"let a: Any = "s"; a as! Int"#, in: shell)
    #expect(shell.lastStatus == 1) // at run time, as in Swift
    // Casts bind tighter than ??, looser than ranges, as in Swift.
    #expect(try output(#"let a: Any = "s"; a as? Int ?? 0"#) == "0\n")
}

@Test func jsonIsReadByFieldAndElement() throws {
    let json = #"let j = try from(.json, ['{"server": {"port": 8080}, "tags": ["a", "b"], "on": true}']); "#
    #expect(try output(json + #"j.server?.port?.int ?? 1; j.missing?.port?.int ?? 1; j["tags"]?[1]?.string; j.tags?.array?.count; j.on?.bool"#)
        == "8080\n1\n\"b\"\n2\ntrue\n")
    // A missing field and a JSON null are both nil, so isNull is true for either.
    #expect(try output(json + "j.server?.port?.string == nil; j.nothing?.isNull") == "true\ntrue\n")
    #expect(typeError(json + "j.server + 1") != nil)          // a JSON? isn't a number
    #expect(typeError(json + "j.server?.port?.int! + 1") == nil)
    // A document of records flows through a pipeline as JSON items.
    #expect(try output(#"echo '[{"n": 1}, {"n": 2}]' | from json | get n"#) == "1\n2\n")
}

@Test func optionalSubscripts() throws {
    #expect(try output("let xs: [Int]? = [1, 2]; xs?[1]; let none: [Int]? = nil; none?[0] == nil") == "2\ntrue\n")
}
