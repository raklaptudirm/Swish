import Swiit
import Testing

@testable import SwishLibrary

// A command's output and how it ended: values a script holds, with no shell to make them.

@Test func anOutputIsTheLinesOfItsText() {
    let output = Output(text: "b\na", status: .success)
    #expect(output.text == "b\na")
    #expect(output.lines == ["b", "a"])
    #expect(output.count == 2)
    #expect(output.first == "b")
    #expect(output.last == "a")
    #expect(output[1] == "a")
    #expect(!output.isEmpty)
    #expect(Output(text: "", status: .success).isEmpty)
    #expect(Output(text: "", status: .success).lines == [])
    // Where a String is wanted it is all of it.
    #expect(output.description == "b\na")
}

@Test func anOutputComparesWithTextAsItsTextDoesOnEitherSide() {
    let output = Output(text: "b", status: .success)
    #expect(output == "b")
    #expect("b" == output)
    #expect(output != "c")
    #expect("c" != output)
    #expect(output < "c")
    #expect("a" < output)
    #expect(output <= "b")
    #expect("b" >= output)
    #expect(output > "a")
    #expect("c" > output)
}

@Test func anOutputKnowsHowItsCommandEnded() {
    #expect(Output(text: "x", code: 3, signal: nil).status == .exited(3))
    #expect(Output(text: "x", code: nil, signal: 15).status == .signaled(15))
    #expect(Output(text: "x", code: nil, signal: nil).status == .success)
    // The signal wins, as in a status that has both.
    #expect(Output(text: "x", code: 1, signal: 9).status == .signaled(9))
}

@Test func aStatusIsACodeOrASignal() {
    #expect(Status.success.succeeded)
    #expect(Status.exited(3).code == 3)
    #expect(Status.exited(3).signal == nil)
    #expect(Status.exited(3).number == 3)
    #expect(!Status.exited(3).succeeded)
    #expect(Status.signaled(15).signal == 15)
    #expect(Status.signaled(15).code == nil)
    // As a process gives it and the shell exits with: 128 and the signal.
    #expect(Status.signaled(15).number == 143)
}

@Test func aStatusIsHeldWithEveryFieldNilIncluded() {
    #expect(
        Status.exited(0).value.debugDescription == "Status(code: 0, signal: nil, succeeded: true)"
    )
    #expect(
        Status.signaled(9).value.debugDescription
            == "Status(code: nil, signal: 9, succeeded: false)"
    )
}
