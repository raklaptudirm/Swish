import SwishCore
import Testing

private func words(_ line: String) throws -> [String] {
    try tokenize(line, home: "/home/me").compactMap {
        if case .word(let word) = $0 { word } else { nil }
    }
}

@Test func splitsOnWhitespace() throws {
    #expect(try words("  ls   -la\t/tmp ") == ["ls", "-la", "/tmp"])
}

@Test func handlesQuotes() throws {
    #expect(try words(#"echo 'a  b' "c \"d\" $e" x'y'z"#) == ["echo", "a  b", #"c "d" $e"#, "xyz"])
}

@Test func emptyQuotesMakeAnEmptyWord() throws {
    #expect(try words(#"printf '' """#) == ["printf", "", ""])
}

@Test func backslashEscapesOutsideQuotes() throws {
    #expect(try words(#"echo a\ b \|"#) == ["echo", "a b", "|"])
}

@Test func expandsLeadingTilde() throws {
    #expect(try words("cd ~ ~/src a~ '~' ~user") == ["cd", "/home/me", "/home/me/src", "a~", "~", "~user"])
}

@Test func stripsComments() throws {
    #expect(try words("echo hi # a comment") == ["echo", "hi"])
    #expect(try words("echo a#b") == ["echo", "a#b"])
}

@Test func pipesNeedNoSpaces() throws {
    #expect(try tokenize("ls|wc -l", home: "") == [.word("ls"), .pipe, .word("wc"), .word("-l")])
}

@Test func rejectsUnterminatedQuotes() {
    #expect(throws: SyntaxError.self) { try tokenize("echo 'oops", home: "") }
    #expect(throws: SyntaxError.self) { try tokenize(#"echo "oops"#, home: "") }
    #expect(throws: SyntaxError.self) { try tokenize(#"echo \"#, home: "") }
}

@Test func parsesPipelines() throws {
    let pipeline = try parse(tokenize("cat f | grep x | wc -l", home: ""))
    #expect(pipeline?.commands.map(\.argv) == [["cat", "f"], ["grep", "x"], ["wc", "-l"]])
}

@Test func blankLinesParseToNothing() throws {
    #expect(try parse(tokenize("   # just a comment", home: "")) == nil)
}

@Test func rejectsDanglingPipes() {
    #expect(throws: SyntaxError.self) { try parse(tokenize("| ls", home: "")) }
    #expect(throws: SyntaxError.self) { try parse(tokenize("ls |", home: "")) }
    #expect(throws: SyntaxError.self) { try parse(tokenize("ls || wc", home: "")) }
}
