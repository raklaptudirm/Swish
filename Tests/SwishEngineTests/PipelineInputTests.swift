import Swiit
import Testing

@testable import SwishEngine

// What a function takes from a pipeline: per item, the whole stream, or the command line.

/// Runs `source` in `shell`, returning what it wrote to standard output.
private func output(_ source: String, in shell: Shell = Shell()) throws -> String {
    try onLargeStack { try shell.runner.capturing { shell.enter(source) } }
}

private func status(_ source: String) -> Int32 {
    let shell = Shell()
    _ = try? onLargeStack { try shell.runner.capturing { shell.execute(source) } }
    return shell.lastStatus.number
}

private let streaming = """
    func double(@input _ n: Int) -> Int { n * 2 }
    func total(@input _ xs: [Int]) -> Int { var t = 0; for x in xs { t = t + x }; return t }
    func evens(@input _ n: Int) -> Int? { if n % 2 == 0 { return n }; return nil }
    var calls = 0
    func counted(@input _ n: Int) -> Int { calls = calls + 1; return n }

    """

@Test func perItemInput() throws {
    #expect(try output(streaming + "seq 4 | double") == "2\n4\n6\n8\n")
    #expect(try output(streaming + "seq 6 | evens | double") == "4\n8\n12\n")
    #expect(try output(streaming + "[1, 2, 3] | double") == "2\n4\n6\n")
}

@Test func wholeStreamInput() throws {
    #expect(try output(streaming + "seq 4 | double | total") == "20\n")
    #expect(try output(streaming + "[] | total") == "0\n")
}

@Test func inputFromTheCommandLineWhenFirst() throws {
    #expect(try output(streaming + "double 21; total 1 2 3") == "42\n6\n")
}

@Test func streamsFeedExternalCommands() throws {
    #expect(try output(streaming + "seq 3 | double | tr 0-9 a-j") == "c\ne\ng\n")
    #expect(try output(#""a b" | tr a-z A-Z"#) == "A B\n")
    #expect(try output("func gen() -> [Int] { [1, 2, 3] }; gen | tail -1") == "3\n")
}

@Test func streamsAreLazy() throws {
    // `head` exits after one line; the shell sees EPIPE and stops pulling
    // instead of dying of SIGPIPE or looping forever.
    #expect(try output(streaming + "yes 7 | double | head -2") == "14\n14\n")
    #expect(
        try output(streaming + "for _ in 1...1 { seq 100000 | counted | head -1 }; calls < 100000")
            == "1\ntrue\n"
    )
}

@Test func streamErrors() {
    #expect(status(streaming + "printf 'x\\n' | double") == 1)  // not an Int
    #expect(status(streaming + "double | cat | double") == 2)  // two in-process runs
}
