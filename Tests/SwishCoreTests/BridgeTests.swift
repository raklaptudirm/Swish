@testable import SwishCore
import SwishKit
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

private func typeError(_ source: String) -> String? {
    let shell = Shell()
    guard case .success(let program) = Result(catching: { try Parser.parse(source, bound: shell.globalNames()) }) else {
        return "syntax error"
    }
    do {
        _ = try TypeChecker(shell: shell).check(program)
        return nil
    } catch {
        return error.message
    }
}

@Test func swiftsOwnMembersOnSwishValues() throws {
    #expect(try output(#""swish".uppercased(); "swish".hasPrefix("sw"); "swish".count; (2.5).rounded(); (12).isMultiple(of: 4)"#)
        == "\"SWISH\"\ntrue\n5\n3.0\ntrue\n")
    #expect(try output("[3, 1, 2].contains(2); [3, 1, 2].firstIndex(of: 1); [3, 1, 2].max(); [1, 2, 3].reduce(0) { $0 + $1 }; [1, 2].map { $0 * 2 }")
        == "true\n1\n3\n6\n[2, 4]\n")
    #expect(try output("Int.max") == "9223372036854775807\n")
}

@Test func swiftTypesAreRealTypes() throws {
    // split gives Substrings, as in Swift; String(_:) turns one back.
    let parts = #"let parts = "a,b,c".split(separator: ","); "#
    #expect(try output(parts + "parts; parts.count; parts[0] == \"a\"; String(parts[1])") == #"["a", "b", "c"]"# + "\n3\ntrue\n\"b\"\n")
    #expect(typeError(parts + "let s: String = parts[0]") == "the value must be String, not Substring")
    // A literal is a Character where one is wanted, and a Character is one.
    #expect(try output(#""swish".first; "swish".first?.isLetter; "a b".contains(" ")"#) == "\"s\"\ntrue\ntrue\n")
    #expect(typeError(#""a,b".split(separator: "ab")"#) == "a Character is one character, not 2")
    // Constrained members are there only when the constraint holds.
    #expect(try output(#"["a", "b"].joined(separator: "-")"#) == "\"a-b\"\n")
    #expect(typeError("[1, 2].joined(separator: \"-\")") != nil)
}

@Test func boxedValuesCompareAndSort() throws {
    #expect(try output(#"let parts = "c,a,b".split(separator: ","); parts.sorted(); parts.contains("a")"#) == #"["a", "b", "c"]"# + "\ntrue\n")
}
