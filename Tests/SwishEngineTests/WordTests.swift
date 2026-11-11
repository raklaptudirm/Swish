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

    #expect(shell.word("5", as: .int) == 5)
    #expect(shell.word("x", as: .int) == nil)
    #expect(shell.word("x", as: .string) == "x")
    #expect(shell.word("x", as: .any) == "x")
    #expect(shell.word("x", as: .optional(.string)) == "x")
    #expect(shell.word("x", as: Symbol.GenericParameter(name: "Element").type) == "x")

    #expect(shell.word(".directory", as: kind)?.description == "directory")
    #expect(shell.word("file", as: kind)?.description == "file")
    #expect(shell.word("nope", as: kind) == nil)
    #expect(shell.word("y", as: letter)?.description == "b")

    // A word is a literal first: one letter for a Character, which a longer word is not, and
    // never a trap.
    let character = ScriptType.named(Symbol.ID(named: "Character", in: shell.interpreter)!)
    #expect(shell.word("a", as: character) == "a")
    #expect(shell.word("ab", as: character) == nil)
    #expect(
        shell.word("/a/b", as: .named(Symbol.ID(named: "FilePath", in: shell.interpreter)!)) != nil
    )
    #expect(shell.word("2.5", as: .double) == 2.5)

    #expect(shell.word("owner.name", as: .named(.keyPath))?.description == "\\.owner.name")
}

@Test func aWordCanBeSomeTypesAndNotOthers() throws {
    let shell = Shell()
    _ = try shell.interpreter.evaluate("enum Kind { case file }")
    let kind = ScriptType.named(Symbol.ID(named: "Kind", in: shell.interpreter)!)

    #expect(shell.acceptsWords(as: .int))
    #expect(shell.acceptsWords(as: .string))
    #expect(shell.acceptsWords(as: .optional(.int)))
    #expect(shell.acceptsWords(as: kind))
    #expect(shell.acceptsWords(as: .named(Symbol.ID(named: "Character", in: shell.interpreter)!)))
    #expect(shell.acceptsWords(as: .named(.keyPath)))
    #expect(!shell.acceptsWords(as: .list(.int)))
    #expect(!shell.acceptsWords(as: .callable))
}
