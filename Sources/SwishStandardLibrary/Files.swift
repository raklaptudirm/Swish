#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Foundation
import SwishKit
import SystemPackage

/// What kind of entry `ls` found: `ls | filter { $0.type == .directory }`.
/// In this order, so `ls | sorted --by type` puts files first.
public enum FileType: String, CaseIterable, Comparable, Codable {
    case file, directory, symlink, other

    public static func < (lhs: FileType, rhs: FileType) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

extension FileType: DisplayStyled {
    public var displayStyle: DisplayStyle? {
        switch self {
        case .directory: .boldBlue
        case .symlink: .cyan
        default: nil
        }
    }
}

/// An entry `ls` lists.
public struct FileEntry: Encodable, Equatable, Hashable {
    public let name: String
    public let type: FileType
    public let size: FileSize
    public let modified: Date
    public let permissions: String
    public let owner: String
    public let created: Date
    public let accessed: Date
    public let path: FilePath
    public let target: FilePath?
}

extension FileEntry: Tabular {
    public static let columns: [DisplayColumn] = [DisplayColumn("name", styledBy: "type"), "type", "size", "modified"]
}

/// Lists directory contents.
/// - Parameter paths: files or directories to list (default: the current directory)
/// - Parameter all: include hidden files
public func ls(@Rest _ paths: [FilePath] = [], @Flag all: Bool = false) -> Partial<[FileEntry]> {
    var entries: [FileEntry] = []
    var errors: [any Error] = []
    for path in (paths.isEmpty ? [FilePath(".")] : paths).map(\.string) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            errors.append(PathError(path: path, reason: "no such file or directory"))
            continue
        }
        guard isDirectory.boolValue else {
            entry(named: path, at: path, into: &entries, errors: &errors)
            continue
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: path)
        } catch {
            errors.append(PathError(path: path, reason: "permission denied"))
            continue
        }
        for name in names.sorted() where all || !name.hasPrefix(".") {
            let fullPath = path == "." ? name : (path as NSString).appendingPathComponent(name)
            entry(named: name, at: fullPath, into: &entries, errors: &errors)
        }
    }
    return Partial(entries, errors: errors)
}

/// What went wrong with a path: `ls: /nope: no such file or directory`.
struct PathError: Error, CustomStringConvertible {
    let path: String
    let reason: String
    var description: String { "\(path): \(reason)" }
}

private func entry(named name: String, at path: String, into entries: inout [FileEntry], errors: inout [any Error]) {
    let status: FileStatus
    do {
        status = try FileStatus(path)
    } catch {
        errors.append(PathError(path: path, reason: String(cString: strerror(error.rawValue)).lowercased()))
        return
    }
    let (type, letter): (FileType, String) = status.isDirectory ? (.directory, "d") : status.isSymlink ? (.symlink, "l")
        : status.isFile ? (.file, "-") : (.other, "?")
    let target = status.isSymlink ? try? FileManager.default.destinationOfSymbolicLink(atPath: path) : nil
    entries.append(FileEntry(
        name: name, type: type, size: FileSize(bytes: Int(status.size)), modified: status.modified,
        permissions: letter + status.permissions, owner: userName(status.owner),
        created: status.created ?? status.modified, accessed: status.accessed,
        path: FilePath(path), target: target.map { FilePath($0) }
    ))
}

/// What `lstat` says about a path, named the same on every platform.
struct FileStatus {
    let mode: mode_t
    let size: Int64
    let owner: uid_t
    let modified: Date
    let accessed: Date
    /// When it was made, if the system keeps that.
    let created: Date?

    /// The path's status, not following a symlink; the error number if
    /// there's none.
    init(_ path: String) throws(Errno) {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw Errno(rawValue: errno) }
        mode = info.st_mode
        size = Int64(info.st_size)
        owner = info.st_uid
        #if canImport(Darwin)
        modified = Self.date(info.st_mtimespec)
        accessed = Self.date(info.st_atimespec)
        created = Self.date(info.st_birthtimespec)
        #else
        modified = Self.date(info.st_mtim)
        accessed = Self.date(info.st_atim)
        // stat has no birth time here; Foundation asks statx for it.
        created = (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
        #endif
    }

    var isDirectory: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFDIR) }
    var isSymlink: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFLNK) }
    var isFile: Bool { mode & mode_t(S_IFMT) == mode_t(S_IFREG) }

    /// `rwxr-xr-x`.
    var permissions: String {
        let bits = [S_IRUSR, S_IWUSR, S_IXUSR, S_IRGRP, S_IWGRP, S_IXGRP, S_IROTH, S_IWOTH, S_IXOTH]
        return bits.enumerated().map { index, bit in mode & mode_t(bit) != 0 ? ["r", "w", "x"][index % 3] : "-" }.joined()
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }
}
