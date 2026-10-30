import Swiit
import Testing

@testable import SwishShell

@Test func aWordIsAValueOfTheTypeAParameterNames() throws {
    let shell = Shell()
    _ = try shell.interpreter.evaluate(
        #"enum Kind { case file, directory }; enum Letter: String { case a = "x", b = "y" }"#
    )
    let kind = ScriptType.named(shell.interpreter.typeID(named: "Kind")!)
    let letter = ScriptType.named(shell.interpreter.typeID(named: "Letter")!)

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

    #expect(shell.word("owner.name", as: .named(.keyPath))?.description == "\\.owner.name")
}

@Test func aWordCanBeSomeTypesAndNotOthers() throws {
    let shell = Shell()
    _ = try shell.interpreter.evaluate("enum Kind { case file }")
    let kind = ScriptType.named(shell.interpreter.typeID(named: "Kind")!)

    #expect(shell.acceptsWords(as: .int))
    #expect(shell.acceptsWords(as: .string))
    #expect(shell.acceptsWords(as: .optional(.int)))
    #expect(shell.acceptsWords(as: kind))
    #expect(shell.acceptsWords(as: .named(.keyPath)))
    #expect(!shell.acceptsWords(as: .list(.int)))
    #expect(!shell.acceptsWords(as: .callable))
}
