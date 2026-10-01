import Foundation
import SwishKit
import SystemPackage

extension Shell {
    // MARK: Sources

    func ls() -> Function {
        .builtin(
            "ls", "Lists directory contents as records.",
            [
                .positional("paths", .named("FilePath"), variadic: true),
                .option("all", .bool, default: .bool(false), short: "a"),
            ],
            .native { shell, args in
                let paths = args.strings("paths")
                let all = args["all"] == .bool(true)
                var entries: [Value] = []
                for path in paths.isEmpty ? ["."] : paths {
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                        shell.reportItemError("ls: \(path): no such file or directory")
                        continue
                    }
                    guard isDirectory.boolValue else {
                        if let entry = shell.fileEntry(named: path, at: path) { entries.append(entry) }
                        continue
                    }
                    let names: [String]
                    do {
                        names = try FileManager.default.contentsOfDirectory(atPath: path)
                    } catch {
                        shell.reportItemError("ls: \(path): permission denied")
                        continue
                    }
                    for name in names.sorted() where all || !name.hasPrefix(".") {
                        let fullPath = path == "." ? name : (path as NSString).appendingPathComponent(name)
                        if let entry = shell.fileEntry(named: name, at: fullPath) { entries.append(entry) }
                    }
                }
                return .list(entries)
            }
        )
    }

    private struct FileEntry: Encodable {
        var name: String
        var type: String
        var size: FileSize
        var modified: Date
        var permissions: String
        var owner: String
        var created: Date
        var accessed: Date
    }

    private func fileEntry(named name: String, at path: String) -> Value? {
        let status: FileStatus
        do {
            status = try FileStatus(path)
        } catch {
            reportItemError("ls: \(path): \(errorMessage(error.code).lowercased())")
            return nil
        }
        let (type, letter) = status.isDirectory ? ("directory", "d") : status.isSymlink ? ("symlink", "l")
            : status.isFile ? ("file", "-") : ("other", "?")
        let entry = FileEntry(
            name: name, type: type, size: FileSize(bytes: status.size),
            modified: status.modified, permissions: letter + status.permissions, owner: userName(status.owner),
            created: status.created ?? status.modified, accessed: status.accessed
        )
        guard case .record(var record) = try? ValueEncoder().encode(entry) else { return nil }
        record["type"] = preludeCase("FileType", type)
        record["path"] = pathValue(path)
        // A nil target is still a field, as the struct declares it.
        let target = status.isSymlink ? try? FileManager.default.destinationOfSymbolicLink(atPath: path) : nil
        record["target"] = target.map(pathValue) ?? .nothing
        return .record(record)
    }

    func pwd() -> Function {
        .builtin("pwd", "The working directory.", [], .native { _, _ in
            pathValue(FileManager.default.currentDirectoryPath)
        })
    }

    func history() -> Function {
        .builtin("history", "What you've entered at the prompt, oldest first.", [], .native { shell, _ in
            .list(shell.historyEntries.map(Value.string))
        })
    }

    func readLine() -> Function {
        .builtin(
            "readLine", "A line of standard input, or nil at its end.",
            [.option("strippingNewline", .bool, default: .bool(true))],
            .native { _, args in
                // A byte at a time, so nothing past the line is taken from
                // programs that read the rest.
                var bytes: [UInt8] = []
                while let byte = readByte(STDIN_FILENO) {
                    bytes.append(byte)
                    if byte == UInt8(ascii: "\n") { break }
                }
                guard !bytes.isEmpty else { return .nothing }
                if args["strippingNewline"] != .bool(false), bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
                return .string(String(decoding: bytes, as: UTF8.self))
            }
        )
    }

    func ps() -> Function {
        .builtin(
            "ps", "Lists running processes as records. Memory and CPU time are only known for your own processes.", [],
            .native { _, _ in
                do {
                    return .list(try runningProcesses().map { try ValueEncoder().encode($0) })
                } catch let error as Errno {
                    throw RuntimeError("ps: \(errorMessage(error.code))")
                }
            }
        )
    }
}

/// A path as Swish holds it: a FilePath.
func pathValue(_ path: String) -> Value {
    SwiftValue.make(FilePath(path), as: "FilePath")
}
