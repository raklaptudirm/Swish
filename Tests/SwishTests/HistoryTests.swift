import Foundation
import Testing

@testable import Swish

private func temporaryFile() -> String {
    NSTemporaryDirectory() + "swish-history-" + UUID().uuidString
}

private func temporaryDirectory() throws -> String {
    let path = temporaryFile()
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

// The prompt's history: the file it is kept in, how lines are stored, and shells sharing one.

@Test func historyEscapesMultiLineEntries() {
    let entry = "if true {\n  echo \\n\n}"
    #expect(History.encode(entry) == #"if true {\n  echo \\n\n}"#)
    #expect(History.decode(History.encode(entry)) == entry)
}

@Test func historyPersistsAndSkipsRepeats() throws {
    let path = temporaryFile()
    let history = History(path: path)
    history.add("echo one")
    history.add("echo one")
    history.add("   ")
    history.add("if x {\n}")
    #expect(History(path: path).entries == ["echo one", "if x {\n}"])
    #expect(History(path: path, limit: 1).entries == ["if x {\n}"])
    #expect(History(path: path).entries == ["if x {\n}"])  // trimmed on disk too
}

@Test func aLineThatBeginsWithASpaceIsKeptOutOfHistory() throws {
    let path = temporaryFile()
    let history = History(path: path)
    history.add(" export TOKEN=secret")
    history.add("echo kept")
    #expect(history.entries == ["echo kept"])
    #expect(History(path: path).entries == ["echo kept"])
}

@Test func shellsSharingAHistoryFileSeeEachOthersLines() throws {
    let path = temporaryFile()
    let first = History(path: path), second = History(path: path)
    first.add("echo from first")
    second.add("echo from second")
    first.add("echo first again")
    first.takeOthersEntries()
    second.takeOthersEntries()
    // Each has its own lines in the order it ran them, and the other's as it finds them.
    #expect(first.entries == ["echo from first", "echo first again", "echo from second"])
    #expect(second.entries == ["echo from second", "echo from first", "echo first again"])
    // Nothing new: nothing is taken twice.
    first.takeOthersEntries()
    #expect(first.entries.count == 3)
}

@Test func historyReadsItsFileAsBytes() {
    // Escaped lines decode; others, and a last line without a newline, are
    // taken as they are, multi-byte characters included.
    let file = "echo héllo\nif x {\\n}\n\nlast \\\\ one"
    #expect(History.lines(of: Array(file.utf8)) == ["echo héllo", "if x {\n}", "last \\ one"])
}

@Test func historyIsTrimmedOnlyWellPastItsLimit() throws {
    let path = temporaryFile()
    let history = History(path: path)
    for n in 1...11 { history.add("echo \(n)") }
    // At 11 of 10 it's left as it is, so a full history isn't rewritten
    // every time a shell starts; at 12, it's trimmed back to 10.
    #expect(History(path: path, limit: 10).entries.count == 11)
    history.add("echo 12")
    #expect(History(path: path, limit: 10).entries == (3...12).map { "echo \($0)" })
    #expect(History(path: path).entries.count == 10)
}

@Test func historyLivesInTheXDGStateDirectory() {
    let path = { (environment: [String: String]) in History.defaultPath(environment: environment) }
    #expect(path(["HOME": "/h"]) == "/h/.local/state/swish/history")
    #expect(path(["HOME": "/h", "XDG_STATE_HOME": "/state"]) == "/state/swish/history")
    #expect(path(["HOME": "/h", "XDG_STATE_HOME": "relative"]) == "/h/.local/state/swish/history")
    #expect(path(["HOME": "/h", "XDG_STATE_HOME": "/state", "SWISH_HISTORY": "/mine"]) == "/mine")
    #expect(path(["HOME": "/h", "SWISH_HISTORY": ""]) == nil)
}

@Test func historyCreatesItsDirectory() throws {
    let directory = try temporaryDirectory()
    let path = directory + "/state/swish/history"
    History(path: path).add("echo one")
    #expect(History(path: path).entries == ["echo one"])
    // Private to you: the directory is readable by no one else.
    let attributes = try FileManager.default.attributesOfItem(atPath: directory + "/state/swish")
    #expect(attributes[.posixPermissions] as? Int == 0o700)
}
