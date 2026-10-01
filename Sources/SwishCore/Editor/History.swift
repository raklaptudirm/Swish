import Foundation

/// Accepted input lines, newest last, kept in a file across sessions. Each
/// entry is one line of the file, with newlines in multi-line entries
/// escaped as `\n` (and backslashes as `\\`).
final class History {
    private(set) var entries: [String] = []
    private let path: String?
    private let limit: Int

    /// `path` nil keeps history in memory only.
    init(path: String?, limit: Int = 10_000) {
        self.path = path
        self.limit = limit
        guard let path, let data = FileManager.default.contents(atPath: path) else { return }
        entries = History.lines(of: [UInt8](data))
        // Trimmed back to the limit only once it's well past it: at the
        // limit, every session adds a little, and rewriting the whole file
        // each start would make a full history slow to start with.
        if entries.count > limit + limit / 10 {
            entries.removeFirst(entries.count - limit)
            rewrite()
        }
    }

    /// Adds an entry, unless it's blank or repeats the last one.
    func add(_ entry: String) {
        guard !entry.allSatisfy(\.isWhitespace), entry != entries.last else { return }
        entries.append(entry)
        guard let path else { return }
        // Appending rather than rewriting lets several shells share a file.
        var fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        if fd < 0 && errno == ENOENT {
            History.makeDirectory(for: path)
            fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        }
        guard fd >= 0 else { return }
        writeAll(fd, History.encode(entry) + "\n")
        close(fd)
    }

    private func rewrite() {
        guard let path else { return }
        History.makeDirectory(for: path)
        let text = entries.map { History.encode($0) + "\n" }.joined()
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }

    static func encode(_ entry: String) -> String {
        guard entry.utf8.contains(where: { $0 == UInt8(ascii: "\\") || $0 == UInt8(ascii: "\n") }) else { return entry }
        return entry.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
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
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }
}
