@testable import SwishCore
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    return shell.lastStatus
}

private let data = #"let xs = [(n: 2, s: "b"), (n: 1, s: "a"), (n: 3, s: "c")]; "#

@Test func sequenceMethodsAsStages() throws {
    // Command syntax, call syntax and trailing closures, all after a `|`.
    #expect(try output(data + "xs | sorted --by n | get s") == "a\nb\nc\n")
    #expect(try output(data + #"xs | sorted(by: "n", reverse: true) | prefix(2) | get s"#) == "c\nb\n")
    #expect(try output(data + "xs | sorted { $0.n > $1.n } | get n") == "3\n2\n1\n")
    #expect(try output("[1, 2, 3, 4] | filter { $0 % 2 == 0 } | map { $0 * 10 }") == "20\n40\n")
    #expect(try output("[1, 2, 3] | count; [1, 2, 3] | count { $0 > 1 }; [1, 2] | reversed") == "3\n2\n2\n1\n")
}

@Test func sequenceMethodsOnValues() throws {
    #expect(try output(data + #"xs.sorted(by: "s").map { $0.n }"#) == "[1, 2, 3]\n")
    #expect(try output("[3, 1, 2].sorted(); [3, 1, 2].sorted { $0 > $1 }; [3, 1, 2].prefix(2)") == "[1, 2, 3]\n[3, 2, 1]\n[3, 1]\n")
    #expect(try output("[1, 2, 3].count(where: { $0 > 1 }); [1, 2, 3].count") == "2\n3\n")
    // An Output's lines are a sequence too.
    #expect(try output(#"$(printf "b\na").sorted()"#) == #"["a", "b"]"# + "\n")
}

@Test func itemMethodsAsStages() throws {
    let point = #"struct Point { var x: Int; func describe() -> String { "p\(x)" }; func scaled(by k: Int) -> Point { Point(x: x * k) }; mutating func bump() { x += 1 } }; "#
    #expect(try output(point + "[Point(x: 1), Point(x: 2)] | describe") == "p1\np2\n")
    #expect(try output(point + "Point(x: 3) | scaled --by 2 | describe; Point(x: 3) | scaled(by: 3) | describe") == "p6\np9\n")
    // A piped value isn't a variable, so it can't be changed.
    #expect(status(point + "Point(x: 1) | bump") == 1)
    // Objects' methods too, found when the items arrive.
    let shell = Shell()
    #expect(try output("async sleep 5; jobs | cancel; let j = jobs.first; await j!; j!.state", in: shell) == "[1] running  sleep 5\nJobState.cancelled\n")
}

@Test func methodsComeFirstAfterAPipe() throws {
    // A function of the same name doesn't hide the method…
    #expect(try output("func sorted() -> String { \"mine\" }; [2, 1] | sorted; sorted") == "1\n2\nmine\n")
    // …and `foreign` still reaches the program.
    #expect(try output("printf '2\\n1\\n' | foreign sort") == "1\n2\n")
    // Without a `|`, a method has nothing to work on.
    #expect(status("sorted") == 1)
    #expect(status("ls | surely-nothing") == 1)
}
