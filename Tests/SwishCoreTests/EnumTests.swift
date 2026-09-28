@testable import SwishCore
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try shell.capturing { shell.execute(source) }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? shell.capturing { shell.execute(source) }
    return shell.lastStatus
}

// MARK: Enums

@Test func plainCases() throws {
    let kind = "enum Kind { case file, directory };"
    #expect(try output(kind + "let k = Kind.directory; k; k == .directory; k != .file; Kind.allCases") == "Kind.directory\ntrue\ntrue\n[Kind.file, Kind.directory]\n")
    #expect(status(kind + "Kind.socket") == 1)
    #expect(status(kind + "Kind.file == \"file\"") == 1) // compare with a case, not a String
}

@Test func rawValues() throws {
    #expect(try output("enum Level: Int { case low = 1, mid, high = 10 }; Level.mid.rawValue; Level(rawValue: 10); Level(rawValue: 5) == nil") == "2\nLevel.high\ntrue\n")
    #expect(try output(#"enum Code: String { case ok, bad = "BAD" }; Code.ok.rawValue; Code.bad.rawValue"#) == "\"ok\"\n\"BAD\"\n")
    #expect(status("enum L: Int { case a = 1, b = 1 }") == 1) // raw values are unique
    #expect(status("enum L { case a = 1 }") == 1)             // raw values need a raw type
    #expect(status("enum K { case a }; K.a.rawValue") == 1)
}

@Test func associatedValues() throws {
    let result = "enum Result { case ok, failed(code: Int, String) };"
    #expect(try output(result + #"Result.failed(code: 2, "boom")"#) == #"Result.failed(code: 2, "boom")"# + "\n")
    #expect(status(result + "Result.failed") == 1)                  // needs its values
    #expect(status(result + #"Result.failed(2, "boom")"#) == 1)    // and their labels
    #expect(status(result + #"Result.failed(code: "x", "boom")"#) == 1) // and types
    #expect(status(result + "Result.allCases") == 1)                // not CaseIterable
}

@Test func caseLiteralsTakeTheirTypeFromContext() throws {
    let kind = "enum K { case a, b };"
    #expect(try output(kind + "func f(_ k: K) -> K { k }; f(.b); func g() -> K { .a }; g(); func h(kind: K = .b) -> K { kind }; h") == "K.b\nK.a\nb\n")
    #expect(status(kind + "let x = .a") == 1) // nothing to take a type from
}

@Test func enumParametersOnTheCommandLine() throws {
    let pick = "enum K { case a, b }; func pick(kind: K = .a) -> K { kind };"
    #expect(try output(pick + "pick --kind b; pick --kind .b; pick") == "b\nb\na\n")
    #expect(status(pick + "pick --kind c") == 1)
    #expect(try output(pick + "pick --help").contains("--kind <a|b>"))
}

@Test func enumsSortByDeclarationAndBecomeJSON() throws {
    #expect(try output("enum K { case b, a }; [K.a, K.b] | sorted") == "b\na\n")
    #expect(try output(#"enum L: Int { case one = 1 }; enum R { case failed(code: Int) }; L.one | to json; R.failed(code: 2) | to json | tr -d ' \n'"#) == #"1"# + "\n" + #"{"failed":{"code":2}}"#)
}

// MARK: switch

private let result = #"enum Result { case ok, failed(code: Int, String) };"#

@Test func switchOnCasesWithBindingsAndGuards() throws {
    let source = result + #"""
    func describe(_ r: Result) -> String {
        switch r {
        case .ok: return "fine"
        case .failed(let code, let why) where code > 1: return "bad \(code): \(why)"
        case .failed: return "other"
        }
    }
    describe(.ok); describe(.failed(code: 2, "boom")); describe(.failed(code: 1, "meh"))
    """#
    #expect(try output(source) == "\"fine\"\n\"bad 2: boom\"\n\"other\"\n")
}

@Test func switchPatterns() throws {
    let source = """
    func size(_ n: Int) -> String {
        switch n {
        case 0: return "none"
        case 1...5: return "few"
        case 6..<100, 100: return "many"
        case let big where big > 1000: return "huge \\(big)"
        default: return "lots"
        }
    }
    size(0); size(3); size(100); size(5000); size(500)
    """
    #expect(try output(source) == "\"none\"\n\"few\"\n\"many\"\n\"huge 5000\"\n\"lots\"\n")
    #expect(try output("switch \"b\" { case \"a\": echo a\ncase \"b\", \"c\": echo bc\ndefault: break }") == "bc\n")
}

@Test func fallthroughAndBreak() throws {
    #expect(try output("enum K { case a, b, c }; switch K.a { case .a: echo a; fallthrough\ncase .b: echo b\ncase .c: echo c }") == "a\nb\n")
    #expect(try output("for i in 1...3 { switch i { case 2: break\ndefault: echo \\(i) } }") == "1\n3\n")
}

@Test func switchMustMatchSomething() {
    #expect(status(#"switch "x" { case "y": echo y }"#) == 1)
}

@Test func ifCase() throws {
    #expect(try output(result + #"let r = Result.failed(code: 3, "x"); if case .failed(let c, _) = r { echo "code \(c)" }; if case .ok = r { echo no } else { echo "not ok" }"#) == "code 3\nnot ok\n")
}

// MARK: Builtins

@Test func jobsHaveAState() throws {
    #expect(try output("let j = async sleep 0.1; j.state == .running; await j; j.state; j.state == JobState.done") == "true\nJobState.done\ntrue\n")
}
