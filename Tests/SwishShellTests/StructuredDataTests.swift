import Swiit
import Testing

@testable import SwishShell

// Records, tables and the builtins that make them: `ls`, `ps`, `json`, sorting and slicing.

/// Runs `source` in `shell`, returning what it wrote to standard output.
private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.enter(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    return shell.lastStatus.number
}

/// A directory with known files, for `ls`. (Built with commands, since
/// Foundation can't be imported next to Testing with the Command Line Tools.)
private func fixture() throws -> String {
    let shell = Shell()
    let directory = try output("mktemp -d", in: shell).trimmingCharacters(in: .newlines)
    shell.execute(
        """
        mkdir \(directory)/sub
        head -c 1500 /dev/zero | dd of=\(directory)/big.bin status=none
        printf hi | dd of=\(directory)/small.txt status=none
        touch \(directory)/.hidden
        """
    )
    return directory
}

@Test func recordsAndMembers() throws {
    let r = #"let r = (name: "x", size: 2.mb);"#
    #expect(try output(r + "r.name; r.size * 2; r.1") == "\"x\"\n4.0 MB\n2.0 MB\n")
    #expect(try output(r + "r") == #"(name: "x", size: 2.0 MB)"# + "\n")
    #expect(status(r + "r.nope") == 2)
    #expect(try output(#""a\nb".lines.count; [1, 2].last; "abc".count"#) == "2\n2\n3\n")
}

@Test func textIsStyledOnlyWhereColorIsOn() throws {
    // A method the shell's library adds to String; plain here, as the output is no terminal.
    #expect(try output(#"print("x".styled(.bold, .red)); "y".styled(.green).count"#) == "x\n1\n")
}

@Test func fileSizes() throws {
    #expect(
        try output("1.5.gb + 500.mb; 1.kib.bytes; 10.mb / 4; 1.mb > 999.kb; 4.mb / 2.mb; -1.kb")
            == "2.0 GB\n1024\n2.5 MB\ntrue\n2.0\n-1.0 KB\n"
    )
    #expect(
        try output(#"func f(_ s: FileSize) -> FileSize { s }; f 1.5mb; f 2048"#)
            == "1.5 MB\n2.0 KB\n"
    )
    // A unit is a property of a number, so it works on a variable too; one that isn't a unit is a
    // number's missing member.
    #expect(try output("let n = 3; n.mb; (n * 2).kib; n.mb.bytes") == "3.0 MB\n6.1 KB\n3000000\n")
    #expect(status("1.parsecs") == 2)
}

@Test func listsOfRecordsDisplayAsTables() throws {
    #expect(
        try output(#"let rows: [Any] = [(n: 5, s: "a"), (n: 100, t: "b")]; rows"#)
            == "  n  s  t\n  5  a\n100     b\n"
    )
    #expect(try output(#"[(n: 5), (n: 100)] | filter { $0.n > 10 }"#) == "  n\n100\n")
}

@Test func lsGivesTypedRecords() throws {
    let dir = try fixture()
    #expect(try output("ls \(dir) | get type") == "file\nfile\ndirectory\n")
    #expect(
        try output("ls \(dir) | filter { $0.type == .file } | select name size")
            == "name         size\nbig.bin    1.5 KB\nsmall.txt     2 B\n"
    )
    #expect(try output("ls \(dir) | filter { $0.type != FileType.file } | get name") == "sub\n")
    #expect(try output("ls -a \(dir) | count; ls \(dir) | count") == "4\n3\n")
    #expect(
        try output(
            "ls \(dir) | prefix 1 | members | filter { $0.name == \"size\" } | get declaration"
        )
            == "size: FileSize\n"
    )
    #expect(try output("ls \(dir)/small.txt | get path") == "\(dir)/small.txt\n")
}

@Test func lsReportsBadPathsAndCarriesOn() throws {
    let dir = try fixture()
    let shell = Shell()
    #expect(
        try output("ls \(dir)/nope \(dir)/small.txt | get name", in: shell) == "\(dir)/small.txt\n"
    )
    #expect(shell.lastStatus.number == 1)
}

@Test func psListsProcesses() throws {
    // The test's own process is one of them, by whatever name its platform
    // gives it (process 1 is launchd on macOS, and anything in a container).
    let pid = currentProcessID()
    #expect(try output("ps | filter { $0.pid == \(pid) } | count") == "1\n")
    #expect(try output("ps | filter { $0.pid == \(pid) } | get name") != "\n")
}

@Test func sortingAndSlicing() throws {
    let data = #"let xs = [(n: 3, s: "c"), (n: 1, s: "a"), (n: 2, s: "b")];"#
    #expect(try output(data + "xs | sorted --by n | get s") == "a\nb\nc\n")
    #expect(try output(data + "xs | sorted -b s | reversed | prefix 2 | get n") == "3\n2\n")
    #expect(try output(data + "xs | reversed | get n; xs | count") == "2\n1\n3\n3\n")
    #expect(errorText(data + "xs | sorted")?.contains("Comparable") == true)  // tuples aren't Comparable: sort them by a field
    #expect(
        try output("printf 'b\\n10\\n9\\na\\n' | sorted; printf '10\\n9\\n9\\n10\\n' | uniqued")
            == "10\n9\na\nb\n10\n9\n"
    )
    #expect(try output("[3, 1.5, 2] | sorted") == "1.5\n2\n3\n")
    #expect(try output("seq 1000000 | prefix 2; yes | prefix 1") == "1\n2\ny\n")
}

@Test func json() throws {
    #expect(
        try output(
            #"echo '{"z": 1, "a": {"b": [1, 2.5, null, true]}, "u": "é\n"}' | from json | to json"#
        ) == """
            {
              "z": 1,
              "a": {
                "b": [
                  1,
                  2.5,
                  null,
                  true
                ]
              },
              "u": "é\\n"
            }

            """
    )
    #expect(try output(#"echo '[{"n": 1}, {"n": 2}]' | from json | get n"#) == "1\n2\n")
    #expect(status(#"echo '{"a": }' | from json"#) == 1)
}

@Test func textConversions() throws {
    let data = #"let xs = [(a: 1, b: "x"), (a: 22, b: "y")];"#
    #expect(try output(data + "xs | to text | tr a-z A-Z") == " A  B\n 1  X\n22  Y\n")
    #expect(try output(data + "xs | list") == "a  1\nb  x\n\na  22\nb  y\n")
}

@Test func recordsReachProgramsAsRows() throws {
    // As displayed, minus the header, and never cut short.
    let long = String(repeating: "x", count: 60)
    #expect(
        try output(#"[(a: 1, b: "x y"), (a: 22, b: "\#(long)")] | cat"#) == " 1  x y\n22  \(long)\n"
    )
    #expect(try output(#"[["a": 1]] | to json | tr -d ' \n'"#) == #"{"a":1}"#)
    #expect(status("func f() {}; [f] | cat") == 1)  // functions have no text form
}

@Test func formatterFitsTheWidth() throws {
    var lines: [String] = []
    let formatter = DisplayFormatter(maxWidth: 20) {
        lines.append($0); return true
    }
    let interpreter = Interpreter()
    interpreter["size"] = FileSize(bytes: 1).value
    formatter.add(try interpreter.evaluate(#"(name: "a-rather-long-file-name", size: size)"#))
    formatter.finish()
    // The name column shrinks from 23 to 14 so the table fits in 20.
    #expect(lines == ["name            size\n", "a-rather-long…   1 B\n"])
}

@Test func formatterDropsColumnsThatCantFit() throws {
    var lines: [String] = []
    let formatter = DisplayFormatter(maxWidth: 20) {
        lines.append($0); return true
    }
    formatter.add(
        try Interpreter()
            .evaluate(
                #"(alpha: "aaaaaaaa", bravo: "bbbbbbbb", charlie: "cccccccc")"#
            )
    )
    formatter.finish()
    // Even at 6 wide, three columns need 22; the last is left off.
    #expect(lines == ["alpha   bravo  …\n", "aaaaa…  bbbbb…\n"])
}

@Test func jsonObjectsKeepTheirOrderAndCompareByWhatTheyHold() throws {
    let rows =
        #"echo '[{"name": "a", "age": 3, "city": "x"}, {"name": "b", "age": 5, "city": "y"}]' | from json | "#
    // Columns are the keys, in the order the text gave them.
    #expect(try output(rows + "to text") == "name  age  city\na       3  x\nb       5  y\n")
    #expect(try output(rows + "select city name | get city") == "x\ny\n")
    #expect(try output(rows + "filter { $0.age > 3 } | get name") == "b\n")
    // Equal objects are equal: a document's repeats are one.
    #expect(
        try output(#"echo '[{"a": 1}, {"a": 1}, {"a": 2}]' | from json | uniqued | get a"#)
            == "1\n2\n"
    )
}
