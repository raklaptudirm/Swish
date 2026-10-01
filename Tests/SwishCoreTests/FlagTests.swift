@testable import SwishCore
import SwishKit
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

@Test func wordsConvertByWhatTheParameterIs() throws {
    // Through the type's own declarations: Int's failable initializer,
    // Character's literal rules, a FilePath literal.
    #expect(try output(#"func f(n: Int, c: Character, p: FilePath) { echo "\(n + 1) \(c) \(p.lastComponent!)" }; f --n 2 --c x --p /a/b"#)
        == "3 x b\n")
    // A type no word can be points to call syntax.
    let shell = Shell()
    _ = try output(#"func f(r: ClosedRange<Int>) { echo "\(r)" }"#, in: shell)
    _ = try output("f --r 1...3", in: shell)
    #expect(shell.lastStatus != 0)
    #expect(try output("f(r: 1...3)", in: shell) == "1...3\n")
}

@Test func optionalParametersAreOptionalFlags() throws {
    #expect(try output(#"func f(n: Int?) { echo "\(n ?? 0)" }; f --n 3; f"#) == "3\n0\n")
    #expect(try output(#"func f(_ p: FilePath?) { echo "\(p == nil)" }; f; f /a"#) == "true\nfalse\n")
}

@Test func collectionsTakeSeveralWords() throws {
    // Labeled: a repeated flag. Unlabeled: the remaining words.
    #expect(try output(#"func f(xs: [Int]) { echo "\(xs)" }; f --xs 1 --xs 2; f"#) == "[1, 2]\n[]\n")
    #expect(try output(#"func f(_ n: Int, _ rest: [String]) { echo "\(n) \(rest)" }; f 1 a b"#) == "1 [a, b]\n")
    // Any collection an array literal can be, made from the words: a Set too.
    #expect(try output(#"func f(s: Set<Int>) { echo "\(s.count)" }; f --s 1 --s 1 --s 2"#) == "2\n")
    #expect(try output(#"func f(_ s: Set<String>) { echo "\(s.count)" }; f a a b"#) == "2\n")
}

@Test func boolFlagsTakeAValueToo() throws {
    #expect(try output(#"func f(v: Bool) { echo "\(v)" }; f --v; f --v false; f --v true; f"#) == "true\nfalse\ntrue\nfalse\n")
    #expect(try output(#"func f(v: Bool = true) { echo "\(v)" }; f --no-v; f --v=false; f"#) == "false\nfalse\ntrue\n")
}

@Test func aLiteralPrefersItsOwnType() throws {
    // "x" fits a Character, a Substring and any sequence of Characters; as
    // in Swift, the overload taking it as a String wins.
    #expect(try output(#"String("x"); let c: Character = "z"; String(c)"#) == "\"x\"\n\"z\"\n")
}
