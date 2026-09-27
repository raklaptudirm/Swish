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
        entries = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { History.decode(String($0)) }
        if entries.count > limit {
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
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        writeAll(fd, History.encode(entry) + "\n")
        close(fd)
    }

    private func rewrite() {
        guard let path else { return }
        let text = entries.map { History.encode($0) + "\n" }.joined()
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }

    static func encode(_ entry: String) -> String {
        entry.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func decode(_ line: String) -> String {
        var result = ""
        var escaped = false
        for c in line {
            if escaped {
                result.append(c == "n" ? "\n" : c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                result.append(c)
            }
        }
        return result
    }

    /// The default file: `$SWISH_HISTORY`, or `~/.swish_history`.
    static var defaultPath: String? {
        if let path = env("SWISH_HISTORY") { return path.isEmpty ? nil : path }
        return env("HOME").map { $0 + "/.swish_history" }
    }
}
