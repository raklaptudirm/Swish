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
    let shell = Shell()
    guard case .success(let program) = shell.interpreter.parse(#"let d = "/tmp"; echo $d > $d/x"#), let checked = shell.typeCheck(program) else {
        Issue.record("doesn't check")
        return
    }
    guard case .chain(let chain) = checked.statements[1], let node = chain.first.pipelineNode else {
        Issue.record("not a command")
        return
    }
    #expect(node.commands[0].words.last == .text([.spread(.variable("d"))]))
    #expect(node.commands[0].redirects.last?.target == .file([.spread(.variable("d")), .literal("/x")], .write))
}

@Test func aPlainCommandStatementIsACommandRun() throws {
    #expect(try desugared("git status -s") == #"Command("git", "status", "-s").run()"#)
    #expect(try desugared("echo 'a b'; ls") == "Command(\"echo\", \"a b\").run()\nCommand(\"ls\").run()")
    // Inside a block it is a statement too.
    #expect(try desugared("if true { echo hi }") == "if true {\n    Command(\"echo\", \"hi\").run()\n}")
}

@Test func whatIsMoreThanWordsIsLeftForLater() throws {
    // Each of these still runs as a node of its own, printed as a comment.
    let node = "/* a construct from a layer over the core */"
    for source in ["echo ~", "echo $HOME", "ls *.swift", "echo hi > /dev/null", "X=1 env", "echo a | cat", "try false", "^echo hi", "exit"] {
        #expect(try desugared(source).contains(node), "\(source)")
    }
}
