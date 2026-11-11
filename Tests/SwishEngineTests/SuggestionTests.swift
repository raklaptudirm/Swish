import Swiit
import Testing

@testable import SwishEngine

// What a mistyped command was likely meant to be.

@Test func editsAreCountedAsATypistMakesThem() {
    #expect(Shell.editDistance("gti", "git") == 1)  // two letters swapped
    #expect(Shell.editDistance("gt", "git") == 1)  // one left out
    #expect(Shell.editDistance("gitt", "git") == 1)  // one added
    #expect(Shell.editDistance("gat", "git") == 1)  // one changed
    #expect(Shell.editDistance("pyhton3", "python") == 2)
    #expect(Shell.editDistance("", "ls") == 2)
}

@Test func aCommandThatIsNotFoundSaysWhatIsNear() throws {
    let shell = Shell()
    _ = try onLargeStack { try shell.capturing { shell.execute("func deployment() {}") } }
    #expect(shell.commands(near: "deploymnet") == ["deployment"])
    #expect(shell.commands(near: "zzqqxxyy").isEmpty)
    // A short name is allowed one edit only: `ab` is not a mistyped `cd`, nor `env.X` `env`.
    #expect(!shell.commands(near: "ab").contains("cd"))
    #expect(!shell.commands(near: "env.X").contains("env"))
    #expect(
        errorText("deploymnet", in: shell)
            == "swish: deploymnet: command not found; did you mean `deployment`?"
    )
}
