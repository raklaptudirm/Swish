import Foundation
import SystemPackage
import Testing

@testable import SwishLibrary

// Listing files and processes: records a script holds.

/// A directory with a file, a hidden file and a subdirectory, removed afterwards.
private func inDirectory(_ body: (String) throws -> Void) throws {
    let directory = NSTemporaryDirectory() + "swish-library-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    FileManager.default.createFile(atPath: directory + "/a", contents: Data("hello".utf8))
    FileManager.default.createFile(atPath: directory + "/.hidden", contents: Data())
    try FileManager.default.createDirectory(
        atPath: directory + "/d",
        withIntermediateDirectories: false
    )
    try body(directory)
}

@Test func lsListsADirectoryWithoutItsHiddenFiles() throws {
    try inDirectory { directory in
        let entries = ls(FilePath(directory))
        #expect(entries.map(\.name) == ["a", "d"])
        #expect(entries[0].type == .file)
        #expect(entries[1].type == .directory)
        #expect(entries[0].size == FileSize(bytes: 5))
        #expect(entries[0].permissions.hasPrefix("-"))
        #expect(entries[1].permissions.hasPrefix("d"))
        #expect(entries[0].path == FilePath(directory + "/a"))
        #expect(entries[0].target == nil)
    }
}

@Test func lsListsHiddenFilesWhenAskedAndAFileByItself() throws {
    try inDirectory { directory in
        #expect(ls(FilePath(directory), all: true).map(\.name) == [".hidden", "a", "d"])
        #expect(ls(FilePath(directory + "/a")).map(\.name) == [directory + "/a"])
        #expect(ls([FilePath(directory)], all: false).count == 2)
    }
}

@Test func lsLeavesOutAPathItCannotReadAndGoesOn() throws {
    try inDirectory { directory in
        let entries = ls(FilePath("/nonexistent-swish-path"), FilePath(directory))
        #expect(entries.map(\.name) == ["a", "d"])
    }
    #expect(ls(FilePath("/nonexistent-swish-path")).isEmpty)
}

@Test func anEntryKnowsItsCreationTimeOnlyIfTheSystemKeepsIt() throws {
    try inDirectory { directory in
        let entry = try #require(ls(FilePath(directory + "/a")).first)
        // Whether it is there depends on the system; if it is, it is not after the change.
        if let created = entry.created { #expect(created <= entry.modified.addingTimeInterval(5)) }
    }
}

@Test func fileTypesAreOrderedFilesFirst() {
    #expect(FileType.file < .directory)
    #expect(FileType.directory < .symlink)
    #expect(FileType.symlink < .other)
    #expect(FileType.allCases.sorted() == [.file, .directory, .symlink, .other])
}

@Test func aRecordIsItsStoredPropertiesInTheOrderTheyAreDeclared() throws {
    try inDirectory { directory in
        let entry = try #require(ls(FilePath(directory + "/a")).first)
        #expect(
            entry.memberNames == [
                "name", "type", "size", "modified", "permissions", "owner", "created", "accessed",
                "path", "target",
            ]
        )
        #expect(entry.member("name")?.description == directory + "/a")
        #expect(entry.member("nope") == nil)
    }
    let process = ProcessEntry(pid: 1, ppid: 0, name: "init", user: "root")
    #expect(
        process.memberNames == ["pid", "ppid", "name", "user", "memory", "cpuTime", "threads"]
    )
}

@Test func psListsTheRunningProcessesIncludingThisOne() {
    let processes = ps()
    #expect(!processes.isEmpty)
    #expect(processes.contains { $0.pid == Int(getpid()) })
    #expect(processes == processes.sorted { $0.pid < $1.pid })
}

@Test func pwdIsAnAbsolutePath() {
    #expect(pwd().isAbsolute)
}
