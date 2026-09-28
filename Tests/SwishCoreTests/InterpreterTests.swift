@testable import SwishCore
import SwishKit
import Testing

/// Runs `source` in `shell`, returning what it wrote to standard output.
private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.capturing { shell.execute(source) } }
    return shell.lastStatus
}

@Test func arithmeticAndDisplay() throws {
    #expect(try output("let n = 3; n * 2 + 1") == "7\n")
    #expect(try output("7 / 2; 7 % 2; 7.0 / 2; -n", in: withVariable("n", 4)) == "3\n1\n3.5\n-4\n")
    #expect(try output(#""a" + "b"; [1, 2] + [3]"#) == "\"ab\"\n[1, 2, 3]\n")
    #expect(try output("1 < 2; 1 == 1.0; [1, 2][1]") == "true\ntrue\n2\n")
}

@Test func boolLiteralsActLikeTheCommands() throws {
    #expect(try output("true; false; nil") == "")
    #expect(status("false") == 1)
    #expect(status("true") == 0)
}

@Test func interpolation() throws {
    let shell = withVariable("name", "Swish")
    #expect(try output(#"echo "hi \(name)!" \(1 + 2)px"#, in: shell) == "hi Swish! 3px\n")
    #expect(try output(#"echo "$name" $name"#, in: shell) == "Swish Swish\n")
}

@Test func interpolationNeverSplitsWords() throws {
    let shell = withVariable("s", "a  b")
    #expect(try output(#"printf '[%s]' $s \(s)"#, in: shell) == "[a  b][a  b]")
}

@Test func environmentVariables() throws {
    #expect(try output("echo $HOME") == (env("HOME") ?? "") + "\n")
}

@Test func commandSubstitution() throws {
    #expect(try output("let b = $(echo hi | tr a-z A-Z); b") == "Output(text: \"HI\", status: Status(code: 0, signal: nil, succeeded: true))\n")
    #expect(try output(#"echo "[$(printf 'x\n\n')]""#) == "[x]\n")
}

@Test func substitutionHandlesLargeOutput() throws {
    // Larger than a pipe buffer, which would deadlock without concurrent draining.
    #expect(try output("let s = $(head -c 300000 /dev/zero | tr '\\0' x); s == s").hasPrefix("true"))
}

@Test func chains() throws {
    #expect(try output("false && echo no || echo yes") == "yes\n")
    #expect(try output("true && echo a; echo b") == "a\nb\n")
    #expect(try output("1 > 2 || echo fallback") == "fallback\n")
}

@Test func ifElse() throws {
    #expect(try output("let n = 3; if n > 2 { echo big } else { echo small }") == "big\n")
    #expect(try output("if false { echo 1 } else if true { echo 2 } else { echo 3 }") == "2\n")
    #expect(try output("if grep -q nope /dev/null { echo found } else { echo none }") == "none\n")
    #expect(try output("if true && 1 < 2 { echo both }") == "both\n")
    #expect(try output("if true {\n  echo a\n  echo b\n}\nelse { echo c }") == "a\nb\n")
}

@Test func conditionsMustBeBool() {
    #expect(status("if 1 { echo x }") == 2)
}

@Test func variablesAndScopes() throws {
    #expect(try output("var i = 1; i = i + 1; i") == "2\n")
    #expect(try output("let x = 1; if true { let x = 2; x }; x") == "2\n1\n")
    #expect(try output("var x = 1; if true { x = 5 }; x") == "5\n")
}

@Test func globalsPersistAcrossInputs() throws {
    let shell = Shell()
    _ = try output("let n = 41", in: shell)
    #expect(try output("n + 1", in: shell) == "42\n")
}

@Test func runtimeErrorsStopTheInput() throws {
    #expect(try output("let c = 1; c = 2; echo unreachable") == "")
    #expect(status("let c = 1; c = 2") == 2)
    #expect(status("1 / 0") == 1)
    #expect(status("[1][5]") == 1)
    #expect(status("(undefined)") == 2) // an unknown name in an expression
    #expect(status("9223372036854775807 + 1") == 1)
    #expect(status("echo $SWISH_SURELY_UNSET") == 1)
}

@Test func failingCommandsDontStopTheInput() throws {
    #expect(try output("false; echo after; foreign false; echo again") == "after\nagain\n")
}

@Test func syntaxErrorsSetStatusTwo() {
    #expect(status("echo (") == 2)
}

private func withVariable(_ name: String, _ value: Any) -> Shell {
    let shell = Shell()
    let literal = value is String ? "\"\(value)\"" : "\(value)"
    shell.execute("let \(name) = \(literal)")
    return shell
}

// MARK: Loops

@Test func forLoops() throws {
    #expect(try output("for i in 1...3 { i }") == "1\n2\n3\n")
    #expect(try output("for i in 0..<2 { i }; for x in [\"a\", \"b\"] { x }") == "0\n1\n\"a\"\n\"b\"\n")
    // Strings iterate by character, as in Swift; command output by `.lines`.
    #expect(try output(#"for c in "héy" { c }"#) == "\"h\"\n\"é\"\n\"y\"\n")
    #expect(try output(#"for line in $(printf 'a b\nc').lines { echo "<\(line)>" }"#) == "<a b>\n<c>\n")
    #expect(try output(#"for line in "" { echo never }"#) == "")
    #expect(try output("for _ in 1...2 { echo x }") == "x\nx\n")
}

@Test func rangesAreLazyInLoops() throws {
    #expect(try output("for i in 1...9_000_000_000_000 { if i == 2 { break } }; echo done") == "done\n")
    #expect(status("let r = 1...9_000_000_000_000") == 1)
    #expect(status("for i in 3...1 {}") == 1)
}

@Test func whileLoops() throws {
    #expect(try output("var n = 0; while n < 3 { n = n + 1 }; n") == "3\n")
    #expect(try output("var n = 0; while test $n -lt 2 { n = n + 1 }; n") == "2\n")
}

@Test func breakAndContinue() throws {
    #expect(try output("for i in 0..<10 { if i == 1 { continue }; if i == 3 { break }; i }") == "0\n2\n")
    #expect(try output("for i in 1...2 { for j in 1...3 { if j == 2 { break }; echo \\(i)\\(j) } }") == "11\n21\n")
}

// MARK: Functions

@Test func functionsInExpressionMode() throws {
    #expect(try output("func square(_ x: Int) -> Int { x * x }; square(7)") == "49\n")
    #expect(try output("func fib(_ n: Int) -> Int { if n < 2 { return n }; return fib(n - 1) + fib(n - 2) }; fib(15)") == "610\n")
    #expect(try output(#"func greet(_ name: String, times: Int = 1) -> String { "\(name)x\(times)" }; greet("a"); greet("b", times: 2)"#) == "\"ax1\"\n\"bx2\"\n")
    #expect(try output("func half(_ x: Double) -> Double { x / 2 }; half(3)") == "1.5\n")
    #expect(try output("func sum(_ xs: Int...) -> Int { var t = 0; for x in xs { t = t + x }; return t }; sum(); sum(1, 2, 3)") == "0\n6\n")
}

@Test func argumentErrors() {
    let f = "func f(_ x: Int, label: String = \"d\") -> Int { x };"
    #expect(status(f + "f()") == 2)
    #expect(status(f + "f(\"s\")") == 2)
    #expect(status(f + "f(1, other: \"x\")") == 2)
    #expect(status(f + "f(1, 2)") == 2)
    #expect(status("func f() -> Int { \"no\" }; f()") == 2)
    #expect(status("func f() -> Int { echo hi }; f()") == 2)
}

@Test func functionsDontDisplay() throws {
    #expect(try output("func f() { 42; echo side }; f()") == "side\n")
}

@Test func closures() throws {
    #expect(try output("let double = { $0 * 2 }; double(21)") == "42\n")
    #expect(try output("let add = { a, b in a + b }; add(1, 2)") == "3\n")
    #expect(try output("func apply(_ f: (Int) -> Int, _ x: Int) -> Int { f(x) }; apply({ $0 + 100 }, 1)") == "101\n")
}

@Test func closuresCaptureByReference() throws {
    #expect(try output("func counter() -> (Int) -> Int { var c = 0; return { c = c + $0; return c } }; let next = counter(); next(1); next(5)") == "1\n6\n")
    #expect(try output("var fs: [() -> Int] = []; for i in 1...3 { fs = fs + [{ i * 10 }] }; fs[0](); fs[2]()") == "10\n30\n")
}

// MARK: Command-mode calls

private let greet = #"func greet(_ name: String, times: Int = 1, loud: Bool = false) { var word = "hi"; if loud { word = "HI" }; for _ in 1...times { echo "\(word) \(name)" } };"#

@Test func commandModeBinding() throws {
    let f = #"func f(_ a: String, count: Int = 0, dryRun: Bool = false, color: Bool = true, include: [String]) -> String { "\(a) \(count) \(dryRun) \(color) \(include)" };"#
    #expect(try output(f + "f x --count 3 --dry-run --no-color --include a --include=b") == "x 3 true false [a, b]\n")
    #expect(try output(f + "f --count=2 -- --x") == "--x 2 false true []\n")
}

@Test func commandModeNumbersAndVariadics() throws {
    #expect(try output("func add(_ a: Int, _ b: Int) -> Int { a + b }; add 2 -5") == "-3\n")
    #expect(try output("func sum(_ xs: Double...) -> Double { var t = 0.0; for x in xs { t = t + x }; return t }; sum 1 2.5") == "3.5\n")
}

@Test func commandModeErrors() {
    let f = "func f(_ n: Int, name: String) {};"
    #expect(status(f + "f 1") == 1)                  // missing --name
    #expect(status(f + "f abc --name x") == 1)       // not an Int
    #expect(status(f + "f 1 --name x --bogus") == 1) // unknown option
    #expect(status(f + "f 1 2 --name x") == 1)       // extra positional
    #expect(status(f + "f 1 --name") == 1)           // flag without a value
    #expect(status(f + "f 1 --name x -v") == 1)      // no short flags
}

@Test func functionsInPipelinesAndSubstitutions() throws {
    #expect(try output(greet + "greet Rak --times 2 | tr a-z A-Z") == "HI RAK\nHI RAK\n")
    #expect(try output(greet + #"let s = $(greet Rak --loud); echo "[\(s)]""#) == "[HI Rak]\n")
    #expect(try output(greet + "^greet Rak; foreign greet Rak") == "") // no external named greet
}

@Test func boolResultsAreStatuses() throws {
    let isBig = "func isBig(_ n: Int) -> Bool { n > 10 };"
    #expect(try output(isBig + "isBig 50 && echo big; isBig 5 || echo small") == "big\nsmall\n")
}

// MARK: Pipeline input

private let streaming = """
func double(@input _ n: Int) -> Int { n * 2 }
func total(@input _ xs: [Int]) -> Int { var t = 0; for x in xs { t = t + x }; return t }
func evens(@input _ n: Int) -> Int? { if n % 2 == 0 { return n }; return nil }
var calls = 0
func counted(@input _ n: Int) -> Int { calls = calls + 1; return n }

"""

@Test func perItemInput() throws {
    #expect(try output(streaming + "seq 4 | double") == "2\n4\n6\n8\n")
    #expect(try output(streaming + "seq 6 | evens | double") == "4\n8\n12\n")
    #expect(try output(streaming + "[1, 2, 3] | double") == "2\n4\n6\n")
}

@Test func wholeStreamInput() throws {
    #expect(try output(streaming + "seq 4 | double | total") == "20\n")
    #expect(try output(streaming + "[] | total") == "0\n")
}

@Test func inputFromTheCommandLineWhenFirst() throws {
    #expect(try output(streaming + "double 21; total 1 2 3") == "42\n6\n")
}

@Test func streamsFeedExternalCommands() throws {
    #expect(try output(streaming + "seq 3 | double | tr 0-9 a-j") == "c\ne\ng\n")
    #expect(try output(#""a b" | tr a-z A-Z"#) == "A B\n")
    #expect(try output("func gen() -> [Int] { [1, 2, 3] }; gen | tail -1") == "3\n")
}

@Test func streamsAreLazy() throws {
    // `head` exits after one line; the shell sees EPIPE and stops pulling
    // instead of dying of SIGPIPE or looping forever.
    #expect(try output(streaming + "yes 7 | double | head -2") == "14\n14\n")
    #expect(try output(streaming + "for _ in 1...1 { seq 100000 | counted | head -1 }; calls < 100000") == "1\ntrue\n")
}

@Test func streamErrors() {
    #expect(status(streaming + "printf 'x\\n' | double") == 1) // not an Int
    #expect(status(streaming + "double | cat | double") == 1)  // two in-process runs
}

// MARK: Flags, overloads, help

@Test func shortFlags() throws {
    let f = #"func f(@flag("n") times: Int = 1, @flag("v") verbose: Bool = false, @flag("q") quiet: Bool = false) -> String { "\(times) \(verbose) \(quiet)" };"#
    #expect(try output(f + "f -n 3; f -n3 -vq; f -qv --times=2") == "3 false false\n3 true true\n2 true true\n")
    #expect(status(f + "f -x") == 1)
    #expect(status(f + "f -vx") == 1)
}

@Test func negativeNumbersVersusShortFlags() throws {
    #expect(try output(#"func f(_ x: Int, @flag("5") five: Bool = false) -> String { "\(x) \(five)" }; f -5 -3"#) == "-3 true\n")
}

@Test func overloads() throws {
    let byType = #"func f(_ x: Int) -> String { "int" }; func f(_ x: String) -> String { "string" };"#
    #expect(try output(byType + "f 5; f abc; f(5); f(\"a\")") == "int\nstring\n\"int\"\n\"string\"\n")
    let byLabel = #"func f(a: Int) -> String { "a" }; func f(b: Int) -> String { "b" };"#
    #expect(try output(byLabel + "f --b 1; f(a: 2)") == "b\n\"a\"\n")
    #expect(try output(#"func f(_ x: Double) -> String { "double" }; func f(_ x: Int) -> String { "int" }; f(5); f(5.5)"#) == "\"int\"\n\"double\"\n")
}

@Test func redeclaringReplaces() throws {
    #expect(try output("func f() -> Int { 1 }; func f() -> Int { 2 }; f()") == "2\n")
}

@Test func overloadErrors() {
    #expect(status("func g(_ x: Int, _ y: Int) {}; func g(_ s: String) {}; g 1 2 3") == 1)
    #expect(status("func g(a: Int) {}; func g(b: Int) {}; g(c: 1)") == 2)
    #expect(status(#"func g(_ x: Int, y: Int = 0) -> Int { 1 }; func g(_ x: Int, z: Int = 0) -> Int { 2 }; g(1)"#) == 2) // ambiguous
}

@Test func generatedHelp() throws {
    let source = """
    /// Greets someone.
    /// - Parameter name: who to greet
    func greet(_ name: String, @flag("n") times: Int = 1, color: Bool = true, tags: [String]) {}
    greet --help
    """
    #expect(try output(source) == """
    Greets someone.

    Usage:
      greet [--times <Int>] [--no-color] [--tags <String>] <name>

    Arguments:
      <name>               who to greet (String)

    Options:
      -n, --times <Int>    (default: 1)
          --[no-]color     (default: true)
          --tags <String>  (repeatable)
      -h, --help           Show this help

    """)
}

@Test func helpCanBeClaimed() throws {
    #expect(try output(#"func f(help: Bool = false) -> Bool { help }; f --help"#) == "true\n")
    #expect(try output(#"func f() {}; f -- --help"#) == "")
}

@Test func which() throws {
    let text = try output("func greet(_ name: String) {}; which greet cd prefix cat")
    #expect(text.hasPrefix("greet: function greet(_ name: String)\ncd: shell builtin\nprefix: sequence method prefix(@input _ items: [Any], _ maxLength: Int)\n/"))
    #expect(text.hasSuffix("/cat\n"))
    #expect(status("which surely-not-a-command") == 1)
}

// MARK: Structured data

@Test func recordsAndMembers() throws {
    let r = #"let r = (name: "x", size: 2.mb);"#
    #expect(try output(r + "r.name; r.size * 2; r.1") == "\"x\"\n4.0 MB\n2.0 MB\n")
    #expect(try output(r + "r") == #"(name: "x", size: 2.0 MB)"# + "\n")
    #expect(status(r + "r.nope") == 2)
    #expect(try output(#""a\nb".lines.count; [1, 2].last; "abc".count"#) == "2\n2\n3\n")
}

@Test func fileSizes() throws {
    #expect(try output("1.5.gb + 500.mb; 1.kib.bytes; 10.mb / 4; 1.mb > 999.kb; 4.mb / 2.mb; -1.kb") == "2.0 GB\n1024\n2.5 MB\ntrue\n2.0\n-1.0 KB\n")
    #expect(try output(#"func f(_ s: FileSize) -> FileSize { s }; f 1.5mb; f 2048"#) == "1.5 MB\n2.0 KB\n")
}

@Test func listsOfRecordsDisplayAsTables() throws {
    #expect(try output(#"let rows: [Any] = [(n: 5, s: "a"), (n: 100, t: "b")]; rows"#) == "  n  s  t\n  5  a\n100     b\n")
    #expect(try output(#"[(n: 5), (n: 100)] | filter { $0.n > 10 }"#) == "  n\n100\n")
}

/// A directory with known files, for `ls`. (Built with commands, since
/// Foundation can't be imported next to Testing with the Command Line Tools.)
private func fixture() throws -> String {
    let shell = Shell()
    let directory = try output("mktemp -d", in: shell).trimmingCharacters(in: .newlines)
    shell.execute("""
    mkdir \(directory)/sub
    head -c 1500 /dev/zero | dd of=\(directory)/big.bin status=none
    printf hi | dd of=\(directory)/small.txt status=none
    touch \(directory)/.hidden
    """)
    return directory
}

@Test func lsGivesTypedRecords() throws {
    let dir = try fixture()
    #expect(try output("ls \(dir) | get type") == "file\nfile\ndirectory\n")
    #expect(try output("ls \(dir) | filter { $0.type == .file } | select name size") == "name         size\nbig.bin    1.5 KB\nsmall.txt     2 B\n")
    #expect(try output("ls \(dir) | filter { $0.type != FileType.file } | get name") == "sub\n")
    #expect(try output("ls -a \(dir) | count; ls \(dir) | count") == "4\n3\n")
    #expect(try output("ls \(dir) | prefix 1 | members | filter { $0.name == \"size\" } | get kind") == "FileSize\n")
    #expect(try output("ls \(dir)/small.txt | get path") == "\(dir)/small.txt\n")
}

@Test func lsReportsBadPathsAndCarriesOn() throws {
    let dir = try fixture()
    let shell = Shell()
    #expect(try output("ls \(dir)/nope \(dir)/small.txt | get name", in: shell) == "\(dir)/small.txt\n")
    #expect(shell.lastStatus == 1)
}

@Test func psListsProcesses() throws {
    #expect(try output("ps | filter { $0.pid == 1 } | get name") == "launchd\n")
}

@Test func sortingAndSlicing() throws {
    let data = #"let xs = [(n: 3, s: "c"), (n: 1, s: "a"), (n: 2, s: "b")];"#
    #expect(try output(data + "xs | sorted --by n | get s") == "a\nb\nc\n")
    #expect(try output(data + "xs | sorted -rb s | prefix 2 | get n") == "3\n2\n")
    #expect(try output(data + "xs | reversed | get n; xs | count") == "2\n1\n3\n3\n")
    #expect(status(data + "xs | sorted") == 1) // records need --by
    #expect(try output("printf 'b\\n10\\n9\\na\\n' | sorted; printf '10\\n9\\n9\\n' | sorted -nu") == "10\n9\na\nb\n9\n10\n")
    #expect(try output("[3, 1.5, 2] | sorted") == "1.5\n2\n3\n")
    #expect(try output("seq 1000000 | prefix 2; yes | prefix 1") == "1\n2\ny\n")
}

@Test func json() throws {
    #expect(try output(#"echo '{"z": 1, "a": {"b": [1, 2.5, null, true]}, "u": "é\n"}' | from json | to json"#) == """
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

    """)
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
    #expect(try output(#"[(a: 1, b: "x y"), (a: 22, b: "\#(long)")] | cat"#) == " 1  x y\n22  \(long)\n")
    #expect(try output(#"[["a": 1]] | to json | tr -d ' \n'"#) == #"{"a":1}"#)
    #expect(status("func f() {}; [f] | cat") == 1) // functions have no text form
}

@Test func formatterFitsTheWidth() {
    var lines: [String] = []
    let formatter = Formatter(maxWidth: 20) { lines.append($0); return true }
    formatter.add(.record(Record(["name": .string("a-rather-long-file-name"), "size": .filesize(1)])))
    formatter.finish()
    // The name column shrinks from 23 to 14 so the table fits in 20.
    #expect(lines == ["name            size\n", "a-rather-long…   1 B\n"])
}

@Test func formatterDropsColumnsThatCantFit() {
    var lines: [String] = []
    let formatter = Formatter(maxWidth: 20) { lines.append($0); return true }
    formatter.add(.record(Record(["alpha": .string("aaaaaaaa"), "bravo": .string("bbbbbbbb"), "charlie": .string("cccccccc")])))
    formatter.finish()
    // Even at 6 wide, three columns need 22; the last is left off.
    #expect(lines == ["alpha   bravo  …\n", "aaaaa…  bbbbb…\n"])
}

// MARK: Failing substitutions

@Test func failingSubstitutionsGiveTheirStatus() throws {
    // Without `try`, a failure is just what `.status` says.
    #expect(try output("let x = $(sh -c 'echo partial; exit 3'); x.status.code; x.text; echo after") == "3\n\"partial\"\nafter\n")
    #expect(try output("echo $(false) x") == " x\n")
    #expect(try output("let x = $(echo fine); x") == "Output(text: \"fine\", status: Status(code: 0, signal: nil, succeeded: true))\n")
}

@Test func tryMakesASubstitutionThrow() throws {
    #expect(status("let x = try $(false)") == 1)
    #expect(try output("let x = try $(false); echo unreachable") == "")
    #expect(status("let x = try $(sh -c 'exit 3')") == 3) // the command's own status
    // `try` covers what's to its right, including a command's arguments…
    #expect(try output("try echo $(false) x; echo unreachable") == "")
    // …but not a function's body, which decides for itself.
    #expect(try output("func f() -> Output { $(false) }; let o = try f(); o.status.code") == "1\n")
}

@Test func tryQuestionMark() throws {
    #expect(try output("let x = try? $(false); x == nil") == "true\n")
    #expect(try output(#"(try? $(false)) ?? "fallback""#) == "\"fallback\"\n")
    #expect(try output("try? $(grep -q nope /dev/null) != nil || echo missing") == "missing\n")
    #expect(try output(#"if let h = try? $(echo hi) { echo "got \(h)" } else { echo none }"#) == "got hi\n")
    #expect(try output(#"if let h = try? $(false) { h } else if let g = try? $(echo second) { g }"#) == "Output(text: \"second\", status: Status(code: 0, signal: nil, succeeded: true))\n")
    #expect(status("if let h = try? $(false) { }; h") == 127) // h is only bound inside: here it's a command
    // Any runtime error, not just a failed command.
    #expect(try output("try? [1][5] == nil; try? 1 / 0 == nil") == "")
    #expect(try output("(try? [1][5]) == nil; (try? 1 / 0) == nil") == "true\ntrue\n")
    #expect(try output("func f() -> Int { [1][9] }; (try? f()) ?? 0") == "0\n")
}

@Test func tryCoversEverythingToItsRight() throws {
    // As in Swift: the `??` is inside the `try?`, so a failure makes it all nil.
    let shell = Shell()
    #expect(try output(#"try? $(false) ?? "fallback""#, in: shell) == "")
    #expect(shell.lastStatus == 1) // nil is a failure
    #expect(try output("let y = try $(echo plain); y") == "Output(text: \"plain\", status: Status(code: 0, signal: nil, succeeded: true))\n")
}

@Test func tryBangStopsAScript() throws {
    let shell = Shell()
    let path = try output("mktemp", in: shell).trimmingCharacters(in: .newlines)
    shell.execute(#"printf '%s\n' 'echo one' 'let a = $(false)' 'echo two' 'let b = try! $(sh -c "exit 4")' 'echo three' > \#(path)"#)
    let script = Shell()
    var status: Int32 = 0
    let printed = try script.capturing { status = script.runScript(at: path) }
    // A plain error abandons its statement; `try!` stops the script.
    #expect(printed == "one\ntwo\n")
    #expect(status == 4)
    #expect(Shell().runScript(at: path + ".missing") == 127)
}

@Test func nilCoalescing() throws {
    #expect(try output("nil ?? 1 + 2; 1 ?? 2 == 1; nil ?? nil ?? 3") == "3\ntrue\n3\n")
    #expect(try output("func f(name: String? = nil) -> String { name ?? \"anon\" }; f; f --name x") == "anon\nx\n")
}

@Test func questionMarksAreLiteral() throws {
    #expect(try output("echo https://example.com/?q=1 a?b") == "https://example.com/?q=1 a?b\n")
}

// MARK: Environment, status, scripts

@Test func environmentValue() throws {
    let name = "SWISH_TEST_\(Int.random(in: 0..<1_000_000))"
    #expect(try output("env.\(name) == nil; env.\(name) = \"one two\"; echo $\(name); env[\"\(name)\"]; env.\(name) = nil; env.\(name) == nil") == "true\none two\n\"one two\"\ntrue\n")
    #expect(try output("env.HOME == \"\(env("HOME")!)\"") == "true\n")
    // `env.NAME` is always the variable NAME, even one called `count`.
    #expect(try output("env.count == nil") == "true\n")
}

@Test func environmentForOneCommand() throws {
    let name = "SWISH_TEST_\(Int.random(in: 0..<1_000_000))"
    #expect(try output(#"\#(name)="a b" sh -c 'echo "$\#(name)"'; env.\#(name) == nil"#) == "a b\ntrue\n")
    #expect(try output(#"func show() { sh -c 'echo "$\#(name)"' }; \#(name)=fn show"#) == "fn\n")
    #expect(try output(#"with(env: ["\#(name)": "block"]) { sh -c 'echo "$\#(name)"' }; env.\#(name) == nil"#) == "block\ntrue\n")
}

@Test func noGlobalStatus() {
    #expect(status("false; status") == 127) // just a command name now
}

// MARK: Command output

@Test func outputIsLinesWithText() throws {
    let r = #"let r = $(printf 'a b\nc\n');"#
    #expect(try output(r + "r.count; r[0]; r.last; r.text; r.text.count") == "2\n\"a b\"\n\"c\"\n\"a b\\nc\"\n5\n")
    #expect(try output(r + #"for line in r { echo "<\(line)>" }"#) == "<a b>\n<c>\n")
    #expect(try output(r + "r.status.code; r.status.succeeded; r.status.signal == nil") == "0\ntrue\ntrue\n")
    #expect(try output("$(true).isEmpty; $(true).count") == "true\n0\n")
}

@Test func outputIsItsTextWhereAStringIsWanted() throws {
    #expect(try output(#"let b = $(echo main); b == "main"; "on \(b)"; echo $(echo hi) there"#) == "true\n\"on main\"\nhi there\n")
    #expect(try output(#"func up(_ s: String) -> String { s }; up($(echo hi))"#) == "\"hi\"\n")
    #expect(try output("$(echo x).text + \"y\"") == "\"xy\"\n")
    // `description` is every value's textual form, as in Swift; `.text` is
    // the Output's data.
    #expect(try output(#"$(echo x).description == $(echo x).text; 1.5.kb.description; ["a": 1].description"#) == "true\n\"1.5 KB\"\n\"[\\\"a\\\": 1]\"\n")
    #expect(try output(#"(description: "mine", n: 1).description"#) == "\"mine\"\n")
    #expect(status("$(echo x) + \"y\"") == 2) // other String operations go through .text
    #expect(try output("$(printf '3\\n1\\n2') | sorted") == "1\n2\n3\n")
}

// MARK: do/catch

@Test func catchingAFailedCapture() throws {
    #expect(try output(#"do { let r = try $(sh -c 'echo partial; exit 3') } catch { error.status.code; error.text }"#) == "3\n\"partial\"\n")
    #expect(try output(#"do { let r = try $(sh -c 'kill -TERM $$') } catch { error.status.signal; error.status.code == nil }"#) == "15\ntrue\n")
    // Without `try`, nothing throws, so the catch doesn't run.
    #expect(try output(#"do { let r = $(false) } catch { echo never }; echo done"#) == "done\n")
}

@Test func catchingAnyRuntimeError() throws {
    #expect(try output("do { 1 / 0 } catch let e { e.message; e.status.code }") == "\"division by zero\"\n1\n")
    #expect(try output("do { echo fine } catch { echo never }") == "fine\n")
    #expect(try output("do { let x = 1; x }") == "1\n") // do alone is a scope
    #expect(status("do { 1 / 0 }") == 1) // no catch: still an error
}

@Test func tryMakesACommandThrow() throws {
    #expect(try output("do { try sh -c 'exit 4' } catch { echo \"failed with \\(error.status.code)\" }") == "failed with 4\n")
    #expect(try output("try false; echo unreachable") == "")
    #expect(try output("try true && echo ok") == "ok\n")
    #expect(status("try? make") == 2) // try? needs a value: a syntax error
}

@Test func tryBangCommandStopsAScript() throws {
    let shell = Shell()
    let path = try output("mktemp", in: shell).trimmingCharacters(in: .newlines)
    shell.execute(#"printf '%s\n' 'echo one' 'false' 'echo two' 'try! sh -c "exit 5"' 'echo three' > \#(path)"#)
    let script = Shell()
    var code: Int32 = 0
    #expect(try script.capturing { code = script.runScript(at: path) } == "one\ntwo\n")
    #expect(code == 5)
}

@Test func stringsInExpressionsArePureSwift() throws {
    #expect(try output(#""costs $5 and $HOME""#) == #""costs $5 and $HOME""# + "\n")
    #expect(try output(#"echo "home: $HOME" | cut -c1-6"#) == "home: \n")
}

@Test func scriptsGetArgsAndMain() throws {
    let shell = Shell()
    let path = try output("mktemp", in: shell).trimmingCharacters(in: .newlines)
    shell.execute(#"printf '%s\n' '/// Greets someone.' 'func main(_ name: String, loud: Bool = false) { if loud { echo "HI \(name)" } else { echo "hi \(name)" } }' 'echo "args \(args.count)"' > \#(path)"#)
    let script = Shell()
    var status: Int32 = 0
    #expect(try script.capturing { status = script.runScript(at: path, arguments: ["Rak", "--loud"]) } == "args 2\nHI Rak\n")
    #expect(status == 0)
    let helper = Shell()
    let help = try helper.capturing { _ = helper.runScript(at: path, arguments: ["--help"]) }
    #expect(help.contains("Greets someone.") && help.contains("[--loud] <name>"))
    let missing = Shell()
    #expect(missing.runScript(at: path) == 1) // main needs a name
}

@Test func bareValuesShowTheirDebugDescription() throws {
    #expect(try output(#"let r = $(echo Hello); r"#) == #"Output(text: "Hello", status: Status(code: 0, signal: nil, succeeded: true))"# + "\n")
    #expect(try output(#""tab\there"; let xs: [Any] = [1, "x", nil]; xs; ["k": "v"].debugDescription"#) == #""tab\there""# + "\n" + #"[1, "x", nil]"# + "\n" + #""[\"k\": \"v\"]""# + "\n")
    #expect(try output(#"enum E { case a, b(code: Int, String) }; E.b(code: 2, "no"); "\(E.b(code: 2, "no"))""#)
        == #"E.b(code: 2, "no")"# + "\n" + #""b(code: 2, no)""# + "\n")
    // Interpolation, commands and pipelines use the plain text.
    #expect(try output(#"let r = $(echo Hello); echo $r "\(r)"; ["a", "b"] | prefix 2"#) == "Hello Hello\na\nb\n")
    // Awaiting a job that wrote to the terminal shows nothing more.
    #expect(try output("let j = async true; await j").isEmpty)
}

@Test func aCommandsListReadsLikePipelineOutput() throws {
    // In command form, an item per line, as `names | cat` would give; called
    // as Swift, the list as a value.
    #expect(try output(#"func names() -> [String] { ["a", "b"] }; names; names(); names | cat"#)
        == "a\nb\n" + #"["a", "b"]"# + "\na\nb\n")
    #expect(try output("func none() -> [Int] { [] }; none").isEmpty)
}
