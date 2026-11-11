import Swiit
import Testing

@testable import SwishEngine

@Test func styledTextIsPlainOffATerminal() throws {
    let shell = Shell()
    #expect(
        try onLargeStack {
            try shell.capturing {
                shell.enter(
                    #""x".styled(.red, .bold); let c = true ? TextStyle.green : .red; "y".styled(c) + "!""#
                )
            }
        } == "\"x\"\n\"y!\"\n"
    )
}
