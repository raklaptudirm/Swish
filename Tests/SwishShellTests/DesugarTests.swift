@_spi(Shell) import Swiit
@_spi(Shell) @testable import SwishShell
import SwishKit
import Testing

// What each shell construct means, as Swift (Docs/Design/desugaring.md): the
// checked program, rewritten, and printed.

private func desugared(_ source: String, in shell: Shell = Shell()) throws -> String {
    guard case .success(let program) = shell.interpreter.parse(source) else {
        Issue.record("doesn't parse: \(source)")
        return ""
    }
    guard let checked = shell.typeCheck(program) else {
        Issue.record("doesn't check: \(source)")
        return ""
    }
    return SwiftPrinter().source(checked)
}

@Test func aDollarNameIsTheVariableOrTheEnvironments() throws {
    // A variable in scope is that variable; otherwise the environment's, which stops if it isn't set.
    #expect(try desugared("let n = 3; let m = $n") == "let n = 3\nlet m = n")
    #expect(try desugared("let h = $HOME") == #"let h = env["HOME"]!"#)
}

@Test func anUnsetDollarNameSaysWhatIsNil() throws {
    let shell = Shell()
    let text = try onLargeStack { try shell.capturing { shell.execute("let v = $SURELY_NOT_SET_ANYWHERE") } }
    #expect(text == "")
    #expect(shell.lastStatus != 0)
}

@Test func theRewriteGoesThroughWhatIsInsideACommand() throws {
    // `$name` in a command's words, a redirect and an environment assignment is rewritten too.
    #expect(try desugared(#"let d = "/tmp"; X=$d echo $d > $d/x"#)
        == #"let d = "/tmp"\#nCommand("echo", Spread(d)).environment(["X": "\(d)"]).writing(1, to: "\(d)/x").run()"#)
}

@Test func aPlainCommandStatementIsACommandRun() throws {
    #expect(try desugared("git status -s") == #"Command("git", "status", "-s").run()"#)
    #expect(try desugared("echo 'a b'; ls") == "Command(\"echo\", \"a b\").run()\nCommand(\"ls\").run()")
    // Inside a block it is a statement too.
    #expect(try desugared("if true { echo hi }") == "if true {\n    Command(\"echo\", \"hi\").run()\n}")
}

@Test func environmentTryChainsAndConditionsOverPlainCommands() throws {
    #expect(try desugared("X=1 env") == #"Command("env").environment(["X": "1"]).run()"#)
    #expect(try desugared("try sh -c 'exit 1'") == #"try Command("sh", "-c", "exit 1").check()"#)
    #expect(try desugared("try! sh -c 'exit 1'") == #"try! Command("sh", "-c", "exit 1").check()"#)
    let chained = try desugared("make && echo ok || echo no")
    #expect(chained == #"Command("make").runQuietly().and { Command("echo", "ok").runQuietly() }.or { Command("echo", "no").runQuietly() }"#)
    #expect(try desugared("if grep -q x f { echo hi }")
        == "if Command(\"grep\", \"-q\", \"x\", \"f\").runQuietly().succeeded {\n    Command(\"echo\", \"hi\").run()\n}")
    #expect(try desugared("while sh -c 'exit 1' { echo no }").hasPrefix(#"while Command("sh", "-c", "exit 1").runQuietly().succeeded"#))
}

@Test func wordsRedirectsAndProgramsAreCommandsMethods() throws {
    #expect(try desugared("ls *.swift") == #"Command("ls", Glob("*.swift")).run()"#)
    // A value in a pattern stands for itself, whatever wildcards it has.
    #expect(try desugared(#"let d = "/tmp"; ls "$d"/*.txt"#)
        == #"let d = "/tmp"\#nCommand("ls", Glob("\(escapingWildcards("\(d)"))/*.txt")).run()"#)
    #expect(try desugared(#"let xs = ["a"]; rm $xs"#) == #"let xs = ["a"]\#nCommand("rm", Spread(xs)).run()"#)
    #expect(try desugared("echo ~") == #"Command("echo", "\(env["HOME"]!)").run()"#)
    #expect(try desugared("^echo hi") == #"Command("echo", "hi").external().run()"#)
    #expect(try desugared("sh -c 'echo out; echo err >&2' e>o > /dev/null")
        == #"Command("sh", "-c", "echo out; echo err >&2").sending(2, to: 1).writing(1, to: "/dev/null").run()"#)
    #expect(try desugared("cat < /etc/hosts >> /dev/null")
        == #"Command("cat").reading(0, from: "/etc/hosts").appending(1, to: "/dev/null").run()"#)
}

@Test func pipelinesCarryWhatTheCheckerDecided() throws {
    #expect(try desugared("echo a | cat") == #"Pipeline(Command("echo", "a"), Command("cat").checked(StageHint(.other))).run()"#)
    // With a program after it, a Swift member is a stage too.
    #expect(try desugared("[3, 1] | sorted | cat")
        == #"Pipeline(from: [3, 1], Command("sorted").checked(StageHint(.member(of: "Array", on: .collected))), Command("cat").checked(StageHint(.other))).run()"#)
    #expect(try desugared(#"ls | sorted(by: \.size)"#).contains(#"Command("sorted").calling((by: \.size))"#))
}

@Test func substitutionAndJobsAreCaptureAndStart() throws {
    #expect(try desugared("let x = $(echo hi)") == #"let x = capture { Command("echo", "hi").run() }"#)
    #expect(try desugared("let y = try? $(false)") == "let y = try? capture(throwing: true) { false }")
    #expect(try desugared("let j = async sleep 1") == #"let j = Command("sleep", "1").start()"#)
    #expect(try desugared("let k = async $(echo hi)") == #"let k = Command("echo", "hi").startCapturing()"#)
    // A Swift expression among commands is its exit status.
    #expect(try desugared("true && echo yes") == #"exitStatus(of: true).and { Command("echo", "yes").runQuietly() }"#)
}

@Test func nothingOfTheShellsIsLeftAfterTheRewrite() throws {
    let sources = [
        "echo ~", "echo $HOME", "ls *.swift", "echo hi > /dev/null", "echo a | cat", "^echo hi", "exit", "make && exit",
        "X=1 env | cat", "let x = $(ls | count)", "let j = async sleep 1", "[1, 2] | map { $0 * 2 } | sum",
        "if grep -q x /dev/null { echo hi } else { echo no }", "for f in $(ls).lines { echo $f }",
    ]
    for source in sources {
        #expect(!(try desugared(source).contains("/* a construct from a layer over the core */")), "\(source)")
    }
}

@Test func commandsAndPipelinesRunWrittenByHand() throws {
    let shell = Shell()
    let run = { (source: String) in try onLargeStack { try shell.capturing { shell.execute(source) } } }
    #expect(try run(#"Command("echo", "a b", Spread(["x", "y"])).run()"#) == "a b x y\n")
    #expect(try run(#"print(Pipeline(from: [3, 1, 2], Command("sorted")).output().text)"#) == "1\n2\n3\n")
    #expect(try run(#"print(capture { echo hi }.text)"#) == "hi\n")
    #expect(try run(#"print(Command("env").environment(["XYZ": "1"]).output().lines.filter { $0 == "XYZ=1" })"#) == "[XYZ=1]\n")
    // `e>o > /dev/null`: errors go where the output went before it was sent away.
    #expect(try run(#"Command("sh", "-c", "echo err >&2").sending(2, to: 1).writing(1, to: "/dev/null").run()"#) == "err\n")
    #expect(try run(#"do { try Command("false").check() } catch { print(error.localizedDescription) }"#) == "false failed with status 1\n")
}

@Test func aPipelineOfSwiftsOwnCallsIsThoseCalls() throws {
    #expect(try desugared("[3, 1, 2] | sorted") == "displayItems([3, 1, 2].sorted())")
    #expect(try desugared(#""a b" | split(separator: " ")"#) == #"displayItems("a b".split(separator: " "))"#)
    #expect(try desugared(#"["b", "a"] | sorted | joined(separator: ",")"#) == #"displayItems(["b", "a"].sorted().joined(separator: ","))"#)
    // Items as they come are a Flow's, read an item through every stage before the next.
    #expect(try desugared("[3, 1, 2] | filter { $0 > 1 } | prefix(1)") == "displayItems(Flow([3, 1, 2]).filter { $0 > 1 }.prefix(1))")
    #expect(try desugared(#"["a", "b"] | uppercased"#) == #"displayItems(Flow(["a", "b"]).compactMap { $0.uppercased() })"#)
    // A collected stage after items flow, words to convert, or a program: still a pipeline.
    #expect(try desugared("[1, 2] | map { $0 } | sorted").hasPrefix("Pipeline("))
    #expect(try desugared("[1, 2] | prefix 1").hasPrefix("Pipeline("))
    #expect(try desugared("[3, 1] | sorted | cat").hasPrefix("Pipeline("))
}

@Test func swiftsOwnCallsShowWhatThePipelineShows() throws {
    let sources = [
        "[3, 1, 2] | sorted", "[3, 1, 2] | max", "[Int]() | max", "[1, 2] | count", #""a b" | split(separator: " ")"#,
        #"["b", "a"] | sorted | joined(separator: ",")"#, "[3, 1, 2] | sorted | reversed", #"[["a": 1], ["a": 2]] | reversed"#,
        "[1, 2, 2] | contains(2)", #""hello" | uppercased"#, "[3, 1] | sorted | first",
        "[3, 1, 2] | filter { $0 > 1 } | prefix(1)", "[1, 2] | map { $0 * 2 }", #"["a", "b"] | uppercased"#,
        "[3, 1, 2] | sorted | map { $0 + 1 } | compactMap { $0 > 2 ? $0 : nil }",
        // When each stage runs, item by item: a stage's prints show it.
        #"[1, 2, 3] | map { print("m\($0)"); return $0 } | filter { print("f\($0)"); return $0 > 1 } | prefix(1)"#,
        #"struct P { var x: Int; func d() -> String? { print("d\(x)"); return x > 1 ? "p" : nil } }; [P(x: 1), P(x: 2)] | d"#,
    ]
    for source in sources {
        func run(direct: Bool) throws -> (String, Int32) {
            let shell = Shell()
            shell.directCalls = direct
            let output = try onLargeStack { try shell.capturing { shell.enter(source) } }
            return (output, shell.lastStatus)
        }
        let direct = try run(direct: true), pipeline = try run(direct: false)
        #expect(direct.0 == pipeline.0 && direct.1 == pipeline.1, "\(source): \(direct) and \(pipeline)")
    }
}

@Test func aClosureGivingAnOptionalRunsOncePerItem() throws {
    // The bridge made a closure's optional result once to test it and again to convert it.
    let shell = Shell()
    let output = try onLargeStack { try shell.capturing { shell.execute(#"print([1, 2].compactMap { print("c\($0)"); return $0 > 1 ? $0 : nil })"#) } }
    #expect(output == "c1\nc2\n[2]\n")
}
