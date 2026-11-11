import Foundation
import Swiit

/// Accepted input lines, newest last, kept in a file across sessions. Each
/// entry is one line of the file, with newlines in multi-line entries
/// escaped as `\n` (and backslashes as `\\`).
final class History {
    private(set) var entries: [String] = []
    private let path: String?
    private let limit: Int
    /// How far into the file has been read: what other shells add after it is theirs.
    private var readOffset = 0
    /// What this shell has written since it last read the file, in order, to tell from the others'.
    private var written: [String] = []

    /// `path` nil keeps history in memory only.
    init(path: String?, limit: Int = 10_000) {
        self.path = path
        self.limit = limit
        guard let path, let data = FileManager.default.contents(atPath: path) else { return }
        entries = History.lines(of: [UInt8](data))
        readOffset = data.count
        // Trimmed back to the limit only once it's well past it: at the
        // limit, every session adds a little, and rewriting the whole file
        // each start would make a full history slow to start with.
        if entries.count > limit + limit / 10 {
            entries.removeFirst(entries.count - limit)
            rewrite()
        }
    }

    /// Adds an entry, unless it's blank, repeats the last one, or begins with a space, which is
    /// how a line is kept out of history, as other shells keep it.
    func add(_ entry: String) {
        guard !entry.allSatisfy(\.isWhitespace), entry != entries.last, !entry.hasPrefix(" ")
        else { return }
        entries.append(entry)
        guard let path else { return }
        written.append(entry)
        // Appending rather than rewriting lets several shells share a file.
        var fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        if fd < 0 && errno == ENOENT {
            History.makeDirectory(for: path)
            fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        }
        guard fd >= 0 else { return }
        let line = Array((History.encode(entry) + "\n").utf8)
        _ = write(fd, line, line.count)
        close(fd)
    }

    /// Takes what other shells sharing the file have added since it was last read, so their lines
    /// are found here too. A file rewritten since, which is shorter, is read again from its start.
    func takeOthersEntries() {
        guard let path, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        guard size != readOffset else { return }
        if size < readOffset {
            readOffset = 0
            written = []
        }
        try? handle.seek(toOffset: UInt64(readOffset))
        let added = handle.readData(ofLength: size - readOffset)
        // A line another shell is still writing is left for the next time.
        guard let end = added.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = added[added.startIndex...end]
        readOffset += complete.count
        for entry in History.lines(of: [UInt8](complete)) {
            if written.first == entry {
                written.removeFirst()
            } else if entry != entries.last {
                entries.append(entry)
            }
        }
    }

    private func rewrite() {
        guard let path else { return }
        History.makeDirectory(for: path)
        let text = entries.map { History.encode($0) + "\n" }.joined()
        FileManager.default.createFile(
            atPath: path,
            contents: Data(text.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        readOffset = text.utf8.count
        written = []
    }

    static func encode(_ entry: String) -> String {
        guard entry.utf8.contains(where: { $0 == UInt8(ascii: "\\") || $0 == UInt8(ascii: "\n") })
        else { return entry }
        return entry.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// The file's entries. It's read as bytes on every start, since that's
    /// many times faster than as Characters; most lines have no escapes,
    /// so they're taken as they are.
    static func lines(of bytes: [UInt8]) -> [String] {
        var entries: [String] = []
        var start = 0
        var escaped = false
        for index in bytes.indices {
            switch bytes[index] {
            case UInt8(ascii: "\\"):
                escaped = true
            case UInt8(ascii: "\n"):
                if index > start {
                    let line = bytes[start..<index]
                    entries.append(escaped ? decode(line) : String(decoding: line, as: UTF8.self))
                }
                start = index + 1
                escaped = false
            default:
                break
            }
        }
        if start < bytes.count { entries.append(decode(bytes[start...])) }
        return entries
    }

    static func decode(_ line: String) -> String {
        decode([UInt8](line.utf8)[...])
    }

    static func decode(_ line: ArraySlice<UInt8>) -> String {
        var result: [UInt8] = []
        result.reserveCapacity(line.count)
        var escaped = false
        for byte in line {
            if escaped {
                result.append(byte == UInt8(ascii: "n") ? UInt8(ascii: "\n") : byte)
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else {
                result.append(byte)
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// The default file: `$SWISH_HISTORY` (empty for none), or `swish/history`
    /// in the XDG state directory, `$XDG_STATE_HOME` or `~/.local/state`.
    static var defaultPath: String? {
        defaultPath(environment: ProcessInfo.processInfo.environment)
    }

    static func defaultPath(environment: [String: String]) -> String? {
        if let path = environment["SWISH_HISTORY"] { return path.isEmpty ? nil : path }
        return XDG.stateHome(environment).map { $0 + "/swish/history" }
    }

    /// Creates the file's directory, private to the user, as the spec asks.
    static func makeDirectory(for path: String) {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}
