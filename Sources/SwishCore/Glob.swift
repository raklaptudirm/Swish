import Darwin
import Foundation

/// Filename patterns: `*`, `[a-z]`, and `**` for any depth of directories.
/// `?` isn't a wildcard, as in fish, so `curl https://x.com/?q=1` needs no
/// quotes; `[…]` matches a single character instead. A backslash makes the next character literal, which is how
/// quoted and interpolated text stays literal inside a pattern.
enum Glob {
    /// Makes every character of `text` literal in a pattern.
    static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            if "*?[\\".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Whether `pattern` has an unescaped wildcard: `*`, or a `[…]` class
    /// with its closing bracket. A lone `[`, as in `[ -f x ]`, isn't one.
    static func hasWildcards(_ pattern: String) -> Bool {
        let characters = Array(pattern)
        var index = 0
        while index < characters.count {
            switch characters[index] {
            case "\\":
                index += 1
            case "*":
                return true
            case "[":
                if let close = characters[(index + 1)...].firstIndex(of: "]"), close > index + 1 { return true }
            default:
                break
            }
            index += 1
        }
        return false
    }

    /// The paths matching `pattern`, sorted. As in most shells, `*` doesn't
    /// match a leading dot, and `**` doesn't enter hidden directories.
    static func expand(_ pattern: String) -> [String] {
        let wantsDirectories = pattern.hasSuffix("/")
        let segments = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var paths = [pattern.hasPrefix("/") ? "/" : ""]
        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            let needsDirectory = !isLast || wantsDirectories
            var next: [String] = []
            for base in paths {
                if segment == "**" {
                    next += isLast ? descendants(of: base, directoriesOnly: wantsDirectories)
                        : [base] + descendants(of: base, directoriesOnly: true)
                } else if !hasWildcards(segment) {
                    let path = join(base, unescape(segment))
                    if needsDirectory ? isDirectory(path) : exists(path) { next.append(path) }
                } else {
                    for name in entries(of: base) where fnmatch(segment, name, FNM_PERIOD) == 0 {
                        let path = join(base, name)
                        if !needsDirectory || isDirectory(path) { next.append(path) }
                    }
                }
            }
            paths = next
        }
        let results = Array(Set(paths)).sorted()
        return wantsDirectories ? results.map { $0 + "/" } : results
    }

    private static func descendants(of base: String, directoriesOnly: Bool) -> [String] {
        var found: [String] = []
        for name in entries(of: base) where !name.hasPrefix(".") {
            let path = join(base, name)
            let directory = isDirectory(path) && !isSymlink(path)
            if directory || !directoriesOnly { found.append(path) }
            if directory { found += descendants(of: path, directoriesOnly: directoriesOnly) }
        }
        return found
    }

    private static func entries(of directory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.isEmpty ? "." : directory)) ?? []
    }

    private static func join(_ base: String, _ name: String) -> String {
        base.isEmpty ? name : base.hasSuffix("/") ? base + name : base + "/" + name
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if character == "\\" && !escaped {
                escaped = true
                continue
            }
            result.append(character)
            escaped = false
        }
        return result
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isSymlink(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK
    }
}
