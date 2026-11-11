import Swiit
import Testing

@testable import SwishEngine

@Test func aWordIsAValueOfTheTypeAParameterNames() throws {
    let shell = Shell()
    _ = try shell.interpreter.evaluate(
        #"enum Kind { case file, directory }; enum Letter: String { case a = "x", b = "y" }"#
    )
    let kind = ScriptType.named(Symbol.ID(named: "Kind", in: shell.interpreter)!)
    let letter = ScriptType.named(Symbol.ID(named: "Letter", in: shell.interpreter)!)

    #expect(shell.runner.value(forWord: "5", as: .int) == 5)
    #expect(shell.runner.value(forWord: "x", as: .int) == nil)
    #expect(shell.runner.value(forWord: "x", as: .string) == "x")
    #expect(shell.runner.value(forWord: "x", as: .any) == "x")
    #expect(shell.runner.value(forWord: "x", as: .optional(.string)) == "x")
    #expect(
        shell.runner.value(forWord: "x", as: Symbol.GenericParameter(name: "Element").type) == "x"
    )

    #expect(shell.runner.value(forWord: ".directory", as: kind)?.description == "directory")
    #expect(shell.runner.value(forWord: "file", as: kind)?.description == "file")
    #expect(shell.runner.value(forWord: "nope", as: kind) == nil)
    #expect(shell.runner.value(forWord: "y", as: letter)?.description == "b")

    // A word is a literal first: one letter for a Character, which a longer word is not, and
    // never a trap.
    let character = ScriptType.named(Symbol.ID(named: "Character", in: shell.interpreter)!)
    #expect(shell.runner.value(forWord: "a", as: character) == "a")
    #expect(shell.runner.value(forWord: "ab", as: character) == nil)
    #expect(
        shell.runner.value(
            forWord: "/a/b",
            as: .named(Symbol.ID(named: "FilePath", in: shell.interpreter)!)
        )
            != nil
    )
    #expect(shell.runner.value(forWord: "2.5", as: .double) == 2.5)

    #expect(
        shell.runner.value(forWord: "owner.name", as: .named(.keyPath))?.description
            == "\\.owner.name"
    )
}

@Test func aWordCanBeSomeTypesAndNotOthers() throws {
    let shell = Shell()
    _ = try shell.interpreter.evaluate("enum Kind { case file }")
    let kind = ScriptType.named(Symbol.ID(named: "Kind", in: shell.interpreter)!)

    #expect(shell.runner.acceptsWords(as: .int))
    #expect(shell.runner.acceptsWords(as: .string))
    #expect(shell.runner.acceptsWords(as: .optional(.int)))
    #expect(shell.runner.acceptsWords(as: kind))
    #expect(
        shell.runner.acceptsWords(as: .named(Symbol.ID(named: "Character", in: shell.interpreter)!))
    )
    #expect(shell.runner.acceptsWords(as: .named(.keyPath)))
    #expect(!shell.runner.acceptsWords(as: .list(.int)))
    #expect(!shell.runner.acceptsWords(as: .callable))
}
