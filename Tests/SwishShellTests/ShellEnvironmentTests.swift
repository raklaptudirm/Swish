import Foundation
import Swiit
import Testing

@testable import SwishShell

// The environment other shells set up (`Shell.loadEnvironment(fromShell:login:)`). These change
// the process's own variables, which the tests share, so each uses names no other test does.

private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.capturing { shell.execute(source) } }
}

@Test func aShellScriptsEnvironmentIsTaken() throws {
    setenv("SWISH_TEST_LOAD_GONE", "here", 1)
    setenv("SWISH_TEST_LOAD_KEPT", "same", 1)
    let shell = Shell()
    let printed = try output(
        """
        try env.load(fromShell: "export SWISH_TEST_LOAD_NEW='a b'; unset SWISH_TEST_LOAD_GONE; echo said")
        print(env.SWISH_TEST_LOAD_NEW ?? "nil", env.SWISH_TEST_LOAD_GONE ?? "nil")
        print(env.SWISH_TEST_LOAD_KEPT ?? "nil")
        """,
        in: shell
    )
    // What the script printed is shown; its environment is not mistaken for it.
    #expect(printed == "said\na b nil\nsame\n")
}

@Test func aValueWithANewlineIsOneVariable() throws {
    let printed = try output(
        #"""
        try env.load(fromShell: "export SWISH_TEST_LOAD_LINES='one\ntwo=2'")
        print(env.SWISH_TEST_LOAD_LINES!.split(separator: "\n"))
        """#
    )
    #expect(printed == #"["one", "two=2"]"# + "\n")
}

@Test func aScriptThatExitsEarlyChangesNothing() throws {
    let shell = Shell()
    let status = try onLargeStack {
        shell.execute(#"try env.load(fromShell: "export SWISH_TEST_LOAD_EXIT=1; exit 3")"#)
    }
    #expect(status != 0)
    #expect(getenv("SWISH_TEST_LOAD_EXIT") == nil)
}

@Test func whatShItselfSetsIsNotTaken() throws {
    let shell = Shell()
    func variable(_ name: String) -> String? { getenv(name).map { String(cString: $0) } }
    let level = variable("SHLVL"), directory = variable("PWD")
    try onLargeStack { try shell.loadEnvironment(fromShell: "cd /") }
    #expect(variable("SHLVL") == level)
    #expect(variable("PWD") == directory)
}

@Test func anotherShellsScriptIsToldApart() throws {
    let directory = FileManager.default.temporaryDirectory.path + "/swish-other-shell-\(getpid())"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    func file(_ name: String, _ text: String) -> String {
        let path = directory + "/" + name
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        return path
    }
    #expect(Shell.otherShell(of: file("a.sh", "export A=1\n")) == "sh")
    #expect(Shell.otherShell(of: file("b", "#!/usr/bin/env bash\n")) == "bash")
    #expect(Shell.otherShell(of: file("c", "#!/bin/zsh -f\n")) == "zsh")
    #expect(Shell.otherShell(of: file("d.swish", "print(1)\n")) == nil)
    #expect(Shell.otherShell(of: file("e.sh", "#!/usr/bin/env swish\n")) == nil)
}
