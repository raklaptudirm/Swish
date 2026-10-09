@testable import SwishCore
import SwishKit
import Testing

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    return shell.lastStatus
}

private func typeError(_ source: String) -> String? {
    let shell = Shell()
    guard case .success(let program) = Result(catching: { try Parser.parse(source, bound: shell.interpreter.globalNames()) }) else {
        return "syntax error"
    }
    do {
        _ = try TypeChecker(interpreter: shell.interpreter, shell: shell).check(program)
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
    #expect(typeError(#""a,b".split(separator: "ab")"#) == #""ab" isn't a Character literal"#)
    // Constrained members are there only when the constraint holds.
    #expect(try output(#"["a", "b"].joined(separator: "-")"#) == "\"a-b\"\n")
    #expect(typeError("[1, 2].joined(separator: \"-\")") != nil)
}

@Test func boxedValuesCompareAndSort() throws {
    #expect(try output(#"let parts = "c,a,b".split(separator: ","); parts.sorted(); parts.contains("a")"#) == #"["a", "b", "c"]"# + "\ntrue\n")
}

@Test func rangesAreSwiftRanges() throws {
    #expect(try output("let r = 1...5; r; r.count; r.contains(3); r.map { $0 * 2 }; r.filter { $0 % 2 == 0 }")
        == "ClosedRange(1...5)\n5\ntrue\n[2, 4, 6, 8, 10]\n[2, 4]\n")
    #expect(try output("0..<3; (0..<3).lowerBound; Array(0..<3); (1...3) | map { $0 * 10 }") == "Range(0..<3)\n0\n[0, 1, 2]\n10\n20\n30\n")
    #expect(try output("for i in 0..<2 { i }; let r = 5...6; for i in r { i }") == "0\n1\n5\n6\n")
    // Any bounds that compare make a range; only Int bounds make a sequence.
    #expect(try output("(1.0...2.0).contains(1.5); (\"a\"...\"f\").contains(\"c\")") == "true\ntrue\n")
    #expect(typeError("for x in 1.0...2.0 {}") == "can't iterate over ClosedRange<Double>: it isn't a Sequence")
    #expect(typeError("let r: [Int] = 1...3") == "the value must be [Int], not ClosedRange<Int>")
    #expect(status("let r = 3...1") == 1)
}

@Test func setsAreSwiftSets() throws {
    #expect(try output("let s = Set([3, 1, 2, 3]); s.count; s.contains(2); s.sorted(); s.union([9]).sorted()")
        == "3\ntrue\n[1, 2, 3]\n[1, 2, 3, 9]\n")
    // `some Sequence<Int>`: a list, a range or another set.
    #expect(try output("let s = Set([1, 2]); s.isSubset(of: 1...5); s.intersection(Set([2, 3])); Set(\"hello\").count")
        == "true\nSet([2])\n4\n")
    #expect(try output("let s: Set<String> = Set([\"a\"]); s.contains(\"a\"); Set([1]) == Set([1])") == "true\ntrue\n")
    #expect(typeError("Set([1]).union([\"a\"])") == "union: 'other' must be some Sequence<Int>, not [String]")
    #expect(try output("Set([2, 1]) | sorted") == "1\n2\n")
}

@Test func dictionariesAndOptionalsHaveSwiftsMembers() throws {
    let d = #"let d = ["b": 2, "a": 1]; "#
    // Swift's own Dictionary: shown sorted by key, iterated in Swift's order.
    #expect(try output(d + "d; d.filter { $0.value > 1 }; d.mapValues { $0 * 10 }")
        == #"["a": 1, "b": 2]"# + "\n" + #"["b": 2]"# + "\n" + #"["a": 10, "b": 20]"# + "\n")
    #expect(try output(d + "d.map { $0.key }.sorted(); d.keys.sorted(); d.values.sorted()")
        == #"["a", "b"]"# + "\n" + #"["a", "b"]"# + "\n[1, 2]\n")
    #expect(try output(d + "d.count; d.isEmpty; d.sorted { $0.key < $1.key }.map { $0.value }; d.first!.key == d.keys.first!")
        == "2\nfalse\n[1, 2]\ntrue\n")
    // Keys of other types sort by value too, and JSON's objects by key.
    #expect(try output(#"[10: "x", 2: "y"]; ["b": 1, "a": 2] | to json"#) == #"[2: "y", 10: "x"]"# + "\n{\n  \"a\": 2,\n  \"b\": 1\n}\n")
    #expect(try output(#"Dictionary(uniqueKeysWithValues: [("x", 1), ("y", 2)])"#) == #"["x": 1, "y": 2]"# + "\n")
    #expect(try output("let o: Int? = 4; o.map { $0 + 1 }; let n: Int? = nil; n.map { $0 + 1 } ?? 0") == "5\n0\n")
    #expect(typeError("let n: Int? = nil; n.count") == "Int? might be nil: unwrap it (if let, ??, ?. or !) before using .count")
}

@Test func slicesAndKeyPathsUseSwiftsMembers() throws {
    #expect(try output("[1, 2, 3, 4].dropFirst(); [1, 2, 3].split(separator: 2); Array([1, 2, 3].suffix(2))")
        == "ArraySlice([2, 3, 4])\n[ArraySlice([1]), ArraySlice([3])]\n[2, 3]\n")
    #expect(try output(#"[[1, 2], [3]] | map(\.count); ["ab"] | map(\.isEmpty); [1, 2].last"#) == "2\n1\nfalse\n2\n")
    #expect(try output("[[1, 2], [3]].flatMap { $0 }; [1, 2].elementsEqual([1, 2])") == "[1, 2, 3]\ntrue\n")
}

@Test func filePathsAreSwiftSystems() throws {
    let p = #"let p: FilePath = "/usr/local/bin/swish.tar.gz"; "#
    // A string literal is a FilePath where one is wanted; its members are swift-system's.
    #expect(try output(p + "p.lastComponent!; p.extension; p.stem; p.removingLastComponent(); p.appending(\"x\"); p.isAbsolute")
        == "swish.tar.gz\n" + #""gz""# + "\n" + #""swish.tar""# + "\n/usr/local/bin\n/usr/local/bin/swish.tar.gz/x\ntrue\n")
    // Nested types by their full name, and a path's components as a sequence.
    #expect(try output(#"let c: FilePath.Component = "a.b"; c.extension; c.stem"#) == "\"b\"\n\"a\"\n")
    #expect(try output(p + "p.components.count; p.components | map { $0.stem }; for c in p.components { echo $c }")
        == "4\nusr\nlocal\nbin\nswish.tar\nusr\nlocal\nbin\nswish.tar.gz\n")
    // In text, a path is its description.
    #expect(try output(p + #"echo $p; "\(p.lastComponent!)""#) == "/usr/local/bin/swish.tar.gz\n\"swish.tar.gz\"\n")
    #expect(try output(p + #"p == FilePath("/usr/local/bin/swish.tar.gz"); p.starts(with: "/usr")"#) == "true\ntrue\n")
    // Only a literal converts, as in Swift; a String's doesn't have a path's members.
    #expect(typeError(#"let s = "a"; let q: FilePath = s"#) == "the value must be FilePath, not String")
    #expect(typeError(#""a.txt".extension"#) == "String has no member 'extension'")

    // Shown unquoted, unlike a String; in JSON, a string.
    #expect(try output(p + #"[p]; [p] | to json"#) == "[/usr/local/bin/swish.tar.gz]\n\"/usr/local/bin/swish.tar.gz\"\n")

    // pwd and ls give paths.
    #expect(try output("pwd().isAbsolute; ls().first!.path.isAbsolute") == "true\nfalse\n")
    #expect(try output("let d = pwd().removingLastComponent(); ls(d).first!.path.starts(with: d); ls(\"/\").count > 0") == "true\ntrue\n")

    // A FilePath parameter takes a word on the command line, and --help
    // shows a literal default as it's written.
    let shell = Shell()
    _ = try output(#"func show(_ path: FilePath, to other: FilePath = "/tmp") { echo "\(path.lastComponent!) \(other)" }"#, in: shell)
    #expect(try output("show a/b.txt; show a/b.txt --to /x", in: shell) == "b.txt /tmp\nb.txt /x\n")
    #expect(try output("show --help", in: shell).contains(#"(default: "/tmp")"#))
}

@Test func mutatingMembersChangeTheirVariable() throws {
    #expect(try output("var xs = [3, 1]; xs.append(2); xs.append(contentsOf: [5]); xs.insert(0, at: 0); xs.sort(); xs")
        == "[0, 1, 2, 3, 5]\n")
    #expect(try output("var xs = [3, 1, 2]; xs.removeAll { $0 > 2 }; let last = xs.removeLast(); xs; last") == "[1]\n2\n")
    #expect(try output(#"var d = ["a": 1]; d.updateValue(2, forKey: "b"); d.removeValue(forKey: "a"); d"#) == #"["b": 2]"# + "\n")
    // A concrete overload wins over a generic sequence one, as in Swift.
    #expect(try output(#"var d = ["a": 1]; d.merge(["b": 2]) { a, b in b }; d"#) == #"["a": 1, "b": 2]"# + "\n")
    #expect(try output(#"var s = Set([1]); s.insert(2); s.remove(1); var t = "ab"; t.append("c"); s; t"#) == "Set([2])\n\"abc\"\n")
    // Through a struct's field or a list's element, back into the variable.
    #expect(try output("struct S { var xs: [Int] }; var s = S(xs: []); s.xs.append(4); var m = [[1], [2]]; m[0].append(9); s; m")
        == "S(xs: [4])\n[[1, 9], [2]]\n")
    // @discardableResult ones don't show what they give as a statement.
    #expect(try output("var xs = [1, 2, 3]; xs.removeLast(); xs.popLast()") == "2\n")
    // Only on a var, as in Swift.
    #expect(typeError("let xs = [1]; xs.append(2)") == "cannot use mutating method 'append' on 'xs': it's a 'let' constant")
    #expect(typeError("[1].append(2)") == "cannot use mutating method 'append' on a value that isn't in a variable")
}

@Test func settablePropertiesCanBeAssigned() throws {
    #expect(try output(#"var p: FilePath = "/a/b.txt"; p.extension = "md"; p; p.extension = nil; p"#) == "/a/b.md\n/a/b\n")
    #expect(try output(#"struct W { var path: FilePath }; var w = W(path: "/x/y.c"); w.path.extension = "h"; w.path"#) == "/x/y.h\n")
    #expect(typeError(#"var p: FilePath = "/a"; p.isAbsolute = false"#) == "cannot assign to 'isAbsolute': it's a get-only property of FilePath")
    #expect(typeError(#"let p: FilePath = "/a"; p.extension = "md""#) == "cannot assign to 'p': it's a 'let' constant")
}

@Test func protocolMembersCompleteWhatATypeHasItself() throws {
    // String's own `reversed` gives a ReversedCollection, which Swish has no
    // value for; Sequence's, an array, is what's left.
    #expect(try output(#""abc".reversed(); "abc".sorted()"#) == #"["c", "b", "a"]"# + "\n" + #"["a", "b", "c"]"# + "\n")
    // A type's own member hides the protocol's of the same name and labels.
    #expect(try output("Set([1, 2]).union([9]).sorted(); (1...5).contains(3)") == "[1, 2, 9]\ntrue\n")
    // What another module adds to a type is an overload: `_StringProcessing`'s
    // `contains(_: String)` beside Sequence's `contains(_: Character)`.
    #expect(try output(#""abc".contains("bc"); "abc".contains("b"); "hello" | contains "ell""#) == "true\ntrue\ntrue\n")
}

@Test func datesAreSwiftDates() throws {
    // Foundation's own members and operators, and the text a date shows as.
    #expect(try output("Date(timeIntervalSince1970: 0) < Date(); Date(timeIntervalSince1970: 0).timeIntervalSince1970") == "true\n0.0\n")
    #expect(try output("let d = Date(timeIntervalSince1970: 100); (d + 60) - d; (d - 60) < d") == "60.0\ntrue\n")
    // ISO 8601 text is a date, as a word or by `Date(…)`; JSON gives it back.
    #expect(try output(#"Date("2026-09-27T14:03:00Z")! | to json"#) == "\"2026-09-27T14:03:00Z\"\n")
    #expect(try output(#"Date("someday") == nil"#) == "true\n")
    #expect(typeError("Date() * 2") == "'*' can't be applied to Date and Int")
}
