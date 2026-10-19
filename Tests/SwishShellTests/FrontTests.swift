@testable @_spi(Layer) import Swiit
@_spi(Shell) @_spi(Layer) @testable import SwishShell
import Foundation
import Testing

// The shell's own front end (Front/): text that is Swift's with the shell's in it goes in, Swift comes out. What a unit is
// (a command or an expression), and what each form of the shell's means, is read from the Swift that comes out.

private func front(variables: Set<String> = [], functions: Set<String> = [], tests: ((String) -> Bool)? = nil) -> Front {
    var roles: [String: NameRole] = [:]
    for name in variables { roles[name] = .variable }
    for name in functions { roles[name] = .function }
    return Front(bound: Names(roles: roles))
}

private func cure(_ source: String, variables: Set<String> = [], functions: Set<String> = []) throws -> String {
    try front(variables: variables, functions: functions).cure(source)
}

/// What each top-level line comes to: "command" where the shell's reading made one, "expression" where it is Swift's as typed.
private func modes(_ source: String, variables: Set<String> = [], functions: Set<String> = []) throws -> [String] {
    try source.split(separator: ";").map { unit in
        let cured = try cure(String(unit), variables: variables, functions: functions)
        return cured.contains("Command(") || cured.contains("Pipeline(") ? "command" : "expression"
    }
}

private func failure(_ source: String, variables: Set<String> = []) -> Failure? {
    do {
        _ = try cure(source, variables: variables)
        return nil
    } catch {
        return error as? Failure
    }
}

// MARK: Command or expression

@Test func bareWordsAreCommands() throws {
    #expect(try modes("ls -la; git status; ./run.sh; ~/bin/x; $EDITOR notes") == Array(repeating: "command", count: 5))
}

@Test func literalsAndBracketsAreExpressions() throws {
    #expect(try modes(#"1 + 2; "hi"; 'raw'; (1); [1]; !true; -1; true; nil"#) == Array(repeating: "expression", count: 9))
}

@Test func unknownNamesAreCommandsNotErrors() throws {
    #expect(try modes("undefined + 1; Int.max") == ["command", "command"])
}

@Test func boundVariablesAreExpressions() throws {
    #expect(try modes("n > 2", variables: ["n"]) == ["expression"])
    #expect(try modes("n > 2") == ["command"])
}

@Test func declarationsBindForLaterStatements() throws {
    #expect(try cure("let n = 1\nn > 0") == "let n = 1\nn > 0")
    #expect(try cure("if true { let y = 1 }\ny") == "if true { let y = 1 }\nCommand(\"y\").run()")
}

@Test func caretForcesCommandMode() throws {
    #expect(try cure("^n -la", variables: ["n"]) == #"Command("n", "-la").external().run()"#)
}

@Test func assignmentNeedsABoundName() throws {
    #expect(try cure("i = 2", variables: ["i"]) == "i = 2")
    #expect(try modes("i = 2") == ["command"]) // runs a command named `i`
}

@Test func functionNamesStartCommandsUnlessCalled() throws {
    #expect(try modes("greet Rak --loud; greet(\"Rak\")", functions: ["greet"]) == ["command", "expression"])
    #expect(try cure("func greet() {}\ngreet Rak") == "func greet() {}\nCommand(\"greet\", \"Rak\").run()")
}

@Test func controlFlowStatementsAreSwifts() throws {
    #expect(try cure("for x in [1] { echo hi }") == #"for x in [1] { Command("echo", "hi").run() }"#)
    #expect(try cure("if true { echo a } else { echo b }") == #"if true { Command("echo", "a").run() } else { Command("echo", "b").run() }"#)
}

// MARK: Words

@Test func quotingAndEscapes() throws {
    #expect(try cure(#"echo 'a $b' "c d" e\ f"#) == #"Command("echo", "a $b", "c d", "e f").run()"#)
    #expect(try cure(#"echo "tab\there""#) == #"Command("echo", "tab\there").run()"#)
    #expect(try cure("echo ''") == #"Command("echo", "").run()"#)
}

@Test func interpolationInWords() throws {
    #expect(try cure(#"echo "hi \(name)!""#, variables: ["name"]) == #"Command("echo", "hi \(shellText(name))!").run()"#)
    #expect(try cure(#"echo \(xs)"#, variables: ["xs"]) == #"Command("echo", Spread(xs)).run()"#)
}

@Test func dollarNamesAreVariablesOrTheEnvironments() throws {
    #expect(try cure("let m = $n", variables: ["n"]) == "let m = n")
    #expect(try cure("let h = $HOME") == #"let h = env["HOME"]!"#)
    #expect(try cure("echo $HOME") == #"Command("echo", Spread(env["HOME"]!)).run()"#)
}

@Test func dollarDigitsOutsideClosuresAreText() throws {
    #expect(try cure("echo costs $5") == #"Command("echo", "costs", "$5").run()"#)
}

@Test func tildeOnlyAtWordStart() throws {
    #expect(try cure("echo ~/x a~b") == "Command(\"echo\", \"\\(shellText(env[\"HOME\"]!))/x\", \"a~b\").run()")
}

@Test func onlyUnquotedWildcardsGlob() throws {
    #expect(try cure("ls *.swift") == #"Command("ls", Glob("*.swift")).run()"#)
    #expect(try cure(#"ls "*.swift" '*'"#) == #"Command("ls", "*.swift", "*").run()"#)
}

@Test func emptyBracesAreAWord() throws {
    #expect(try cure("find . -exec rm {} ;") == #"Command("find", ".", "-exec", "rm", "{}").run() ;"#)
}

// MARK: Redirects, environment, chains

@Test func redirectsInOrder() throws {
    #expect(try cure("sort < in e>o > out") == #"Command("sort").reading(0, from: "in").sending(2, to: 1).writing(1, to: "out").run()"#)
    #expect(try cure("make o+e>> log") == #"Command("make").appending(1, to: "log").sending(2, to: 1).run()"#)
}

@Test func posixRedirectsNameTheSwishSpelling() {
    #expect(failure("ls 2>&1")?.message == "that's a POSIX redirect; in Swish it's e>o")
    #expect(failure("ls &> out")?.message == "that's a POSIX redirect; in Swish it's o+e>")
    #expect(failure("ls 3> out")?.message.contains("numbered descriptors") == true)
}

@Test func environmentPrefixesAndAssignments() throws {
    #expect(try cure("X=1 env") == #"Command("env").environment(["X": "1"]).run()"#)
    #expect(failure("X=1")?.message.contains("sets a variable for one command") == true)
}

@Test func logicalOperatorsJoinCommandsAndExpressions() throws {
    #expect(try cure("make && echo ok || echo no")
        == #"Command("make").runQuietly().and { Command("echo", "ok").runQuietly() }.or { Command("echo", "no").runQuietly() }"#)
    #expect(try cure("x > 1 && echo big", variables: ["x"]) == #"exitStatus(of: x > 1).and { Command("echo", "big").runQuietly() }"#)
    // Swift's `||` between expressions stays Swift's.
    #expect(try cure("a < 1 || a > 2", variables: ["a"]) == "a < 1 || a > 2")
}

@Test func conditionsCanBeCommands() throws {
    #expect(try cure("if grep -q x f { echo hi }") == #"if (Command("grep", "-q", "x", "f").runQuietly()).succeeded { Command("echo", "hi").run() }"#)
    #expect(try cure("guard test -d / else { exit 1 }")
        == #"guard (Command("test", "-d", "/").runQuietly()).succeeded else { exitShell(Command("exit", "1")) }"#)
}

@Test func tryBeforeACommand() throws {
    #expect(try cure("try make") == #"try Command("make").check()"#)
    #expect(try cure("try! make") == #"try! Command("make").check()"#)
    #expect(failure("try? make")?.message.contains("try? needs a value") == true)
}

// MARK: Pipelines

@Test func valuesCanFeedPipelines() throws {
    #expect(try cure("xs | sorted | prefix 2", variables: ["xs"]) == #"Pipeline(from: xs, Command("sorted"), Command("prefix", "2")).run()"#)
    #expect(try cure("ls | grep x") == #"Pipeline(Command("ls"), Command("grep", "x")).run()"#)
}

@Test func closuresAsCommandArguments() throws {
    #expect(try cure("ls | where { $0.size > 1 }") == #"Pipeline(Command("ls"), Command("where", { $0.size > 1 })).run()"#)
    // A closure naming no parameter takes what the stage gives it.
    #expect(try cure("xs | filter { true }", variables: ["xs"]) == #"Pipeline(from: xs, Command("filter", { _ in true })).run()"#)
}

@Test func aBraceEndsACommandInAConditionOnly() throws {
    #expect(try cure("if make { echo a }") == #"if (Command("make").runQuietly()).succeeded { Command("echo", "a").run() }"#)
    #expect(try cure("echo {a}") == #"Command("echo", { _ in Command("a").run() }).run()"#)
}

@Test func aCallWrittenAfterAStage() throws {
    #expect(try cure(#"xs | sorted(by: "size")"#, variables: ["xs"]) == #"Pipeline(from: xs, Command("sorted").calling((by: "size"))).run()"#)
}

// MARK: $(…) and async

@Test func substitutionStartsAnExpression() throws {
    #expect(try cure("let a = $(echo hi)") == #"let a = capture({ Command("echo", "hi").run() })"#)
    #expect(try cure("$(echo x).text") == #"capture({ Command("echo", "x").run() }).text"#)
    #expect(try cure("let a = try $(echo hi)") == #"let a = try captureThrowing({ Command("echo", "hi").run() })"#)
}

@Test func tryDoesNotReachIntoClosures() throws {
    #expect(try cure("try xs.map { $(echo \\($0)) }", variables: ["xs"]).contains("capture(") == true)
}

@Test func asyncStartsCommandsAndTasks() throws {
    #expect(try cure("let j = async sleep 1") == #"let j = Command("sleep", "1").start()"#)
    #expect(try cure("let j = async $(echo hi)") == #"let j = Command("echo", "hi").startCapturing()"#)
    #expect(try cure("let t = async { work() }", functions: ["work"]) == #"let t = startTask("{ work() }") { work() }"#)
}

// MARK: Errors and unfinished input

@Test func realErrorsAreNotIncomplete() {
    #expect(failure("echo \"a")?.incomplete == true)
    #expect(failure("echo \"a \\q\"")?.incomplete == false)
    #expect(failure("ls &")?.message.contains("background jobs") == true)
    #expect(failure("ls (a)")?.message.contains("unexpected '('") == true)
    #expect(failure("echo $?")?.message.contains("$? isn't Swish") == true)
}

@Test func commentsAreSlashes() throws {
    #expect(try cure("echo hi // note") == #"Command("echo", "hi").run()"#) // the comment is dropped with the command it follows
    #expect(try cure("echo a#b") == #"Command("echo", "a#b").run()"#)
}

@Test func foreignMarksExternal() throws {
    #expect(try cure("foreign greet Rak") == #"Command("greet", "Rak").external().run()"#)
}

@Test func swiftStaysSwift() throws {
    let program = "let x = [3, 1, 2].map { $0 * 2 }.sorted { $0 > $1 }\nfunc f(_ n: Int) -> Int { n + 1 }\nstruct P { var a: Int }\nfor i in 0..<3 { print(i) }"
    #expect(try cure(program) == program)
}
