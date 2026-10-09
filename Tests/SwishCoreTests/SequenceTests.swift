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
    #expect(try output(data + #"xs | sorted(by: \.n) | reversed | prefix(2) | get s"#) == "c\nb\n")
    #expect(try output(data + "xs | sorted { $0.n > $1.n } | get n") == "3\n2\n1\n")
    #expect(try output("[1, 2, 3, 4] | filter { $0 % 2 == 0 } | map { $0 * 10 }") == "20\n40\n")
    #expect(try output("[1, 2, 3] | count; [1, 2, 3] | count { $0 > 1 }; [1, 2] | reversed") == "3\n2\n2\n1\n")
}

@Test func flowStagesReadOnlyWhatIsAskedFor() throws {
    // Each stage of Flow's reads as the next asks, so an endless stream ends.
    #expect(try output(#"yes | filter { $0 == "y" } | map { $0 + "!" } | prefix 2"#) == "y!\ny!\n")
    #expect(try output(#"yes | compactMap { $0 == "y" ? "got" : nil } | prefix 1"#) == "got\n")
    // A closure's error reaches the one who reads, as it does for a list.
    #expect(try output("[1, 2] | map { 10 / ($0 - 1) }; echo not reached").isEmpty)
    // Where Flow has no such member, the items are collected for Swift's.
    #expect(try output("[1, 2, 3, 1] | prefix(while: { $0 < 3 })") == "1\n2\n")
}

@Test func sequenceMethodsOnValues() throws {
    #expect(try output(data + #"xs.sorted(by: \.s).map { $0.n }"#) == "[1, 2, 3]\n")
    #expect(try output("[3, 1, 2].sorted(); [3, 1, 2].sorted { $0 > $1 }; [3, 1, 2].prefix(2)") == "[1, 2, 3]\n[3, 2, 1]\nArraySlice([3, 1])\n")
    #expect(try output("[1, 2, 3].count(where: { $0 > 1 }); [1, 2, 3].count") == "2\n3\n")
    // An Output's lines are a sequence too.
    #expect(try output(#"$(printf "b\na").sorted()"#) == #"["a", "b"]"# + "\n")
}

@Test func itemMethodsAsStages() throws {
    let point = #"struct Point { var x: Int; func describe() -> String { "p\(x)" }; func scaled(by k: Int) -> Point { Point(x: x * k) }; mutating func bump() { x += 1 } }; "#
    #expect(try output(point + "[Point(x: 1), Point(x: 2)] | describe") == "p1\np2\n")
    #expect(try output(point + "Point(x: 3) | scaled --by 2 | describe; Point(x: 3) | scaled(by: 3) | describe") == "p6\np9\n")
    // A piped value isn't a variable, so it can't be changed.
    #expect(status(point + "Point(x: 1) | bump") == 2)
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
    #expect(status("sorted") == 2)
    #expect(status("ls | surely-nothing") == 127)
}

/// The syntax or type error that stops `source` before it runs, or nil.
private func checkError(_ source: String) -> String? {
    let shell = Shell()
    guard let program = try? Parser.parse(source, bound: shell.interpreter.globalNames()) else { return "syntax error" }
    do {
        _ = try TypeChecker(interpreter: shell.interpreter, shell: shell).check(program)
        return nil
    } catch {
        return error.message
    }
}

@Test func swiftMembersAsStages() throws {
    // A member of the items collected, as an Array, in either syntax.
    #expect(try output(#"[3, 1, 2] | max; [3, 1, 2] | min(); [1, 2] | contains(2); [1, 2, 3] | reduce(0) { $0 + $1 }"#)
        == "3\n1\ntrue\n6\n")
    #expect(try output(#"["a", "b"] | joined(separator: "-"); ["a", "b"] | joined --separator +; [4, 5] | first"#) == "a-b\na+b\n4\n")
    // A word converts to the Element it's compared with.
    #expect(try output(#"[1, 2] | contains 2; ["a"] | contains a"#) == "true\ntrue\n")
    // A list it gives flows as its items.
    #expect(try output("[1, 2, 3] | dropFirst | count") == "2\n")
    // A member of each item, when the collected items have none by that name.
    #expect(try output(#"["abc", "de"] | uppercased; ["abc"] | hasPrefix("a")"#) == "ABC\nDE\ntrue\n")
    // A single value that isn't a sequence is the receiver itself.
    #expect(try output(#""a b c" | split(separator: " ") | count; "abc" | count; let p: FilePath = "/a/b.txt"; p | lastComponent"#)
        == "3\n3\nb.txt\n")
    // A word becomes a Character through Swift's LosslessStringConvertible.
    #expect(try output(#""a b c" | split --separator " " | count; "a-b" | split --separator - | count"#) == "3\n2\n")
    #expect(checkError(#""a b" | split --separator ab"#) != nil)
    // A command's output has its lines' members.
    #expect(try output(#"$(printf "b\na").sorted()"#) == #"["a", "b"]"# + "\n")
    // Nothing by that name, and a program can't take a closure.
    #expect(checkError("[1, 2] | nosuch(1)") == "nosuch isn't a method of [Int] or a function, and a program can't take a closure or (…)")
}

@Test func mapAndSortedAreSwifts() throws {
    // map keeps nils, as Swift's does; compactMap drops them.
    #expect(try output("[1, 2, 3] | map { $0 > 1 ? $0 : nil } | count; [1, 2, 3] | compactMap { $0 > 1 ? $0 : nil } | count") == "3\n2\n")
    // Still a stream, so it stops reading once what's after it has enough.
    #expect(try output(#"yes | map { $0 + "!" } | prefix 2"#) == "y!\ny!\n")
    // sorted() and sorted(by:) are Swift's; sorting by a key path is the shell's addition.
    #expect(try output("[3, 1, 2] | sorted; [3, 1, 2] | sorted { $0 > $1 }; [3, 1, 2] | sorted | reversed")
        == "1\n2\n3\n3\n2\n1\n3\n2\n1\n")
    #expect(try output(#"[(n: 2), (n: 1)] | sorted --by n | get n"#) == "1\n2\n")
    #expect(checkError("[(n: 1)] | sorted") == "sorted needs Element to be Comparable, and (n: Int) isn't")
    #expect(checkError("ls | sorted --reverse") != nil)
}
