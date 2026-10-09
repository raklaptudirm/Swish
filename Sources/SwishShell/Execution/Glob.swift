import SwishCore
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
                    for name in entries(of: base) where matches(Array(segment), Array(name)) {
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

    /// Whether `name` matches one segment of a pattern: `*` any run of
    /// characters, `[a-z]` or `[!a-z]` one, `\` makes the next literal. A
    /// leading dot has to be matched by a dot.
    static func matches(_ pattern: [Character], _ name: [Character]) -> Bool {
        if name.first == ".", pattern.first != "." && !(pattern.first == "\\" && pattern.dropFirst().first == ".") {
            return false
        }
        // Where to go back to after a mismatch: just after the last `*`,
        // with it taking one more character.
        var p = 0, n = 0
        var star: (pattern: Int, name: Int)?
        while n < name.count {
            if p < pattern.count, pattern[p] == "*" {
                star = (p + 1, n)
                p += 1
                continue
            }
            if p < pattern.count {
                let (matched, next) = matchOne(pattern, at: p, name[n])
                if matched {
                    p = next
                    n += 1
                    continue
                }
            }
            guard let back = star else { return false }
            star = (back.pattern, back.name + 1)
            p = back.pattern
            n = back.name + 1
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }

    /// Whether the pattern element at `index` matches `character`, and the
    /// index after it.
    private static func matchOne(_ pattern: [Character], at index: Int, _ character: Character) -> (Bool, Int) {
        switch pattern[index] {
        case "\\" where index + 1 < pattern.count:
            return (pattern[index + 1] == character, index + 2)
        case "[":
            var i = index + 1
            let negated = i < pattern.count && (pattern[i] == "!" || pattern[i] == "^")
            if negated { i += 1 }
            var matched = false
            var first = true
            while i < pattern.count, pattern[i] != "]" || first {
                first = false
                var low = pattern[i]
                if low == "\\", i + 1 < pattern.count { i += 1; low = pattern[i] }
                if i + 2 < pattern.count, pattern[i + 1] == "-", pattern[i + 2] != "]" {
                    if low <= character && character <= pattern[i + 2] { matched = true }
                    i += 3
                } else {
                    if low == character { matched = true }
                    i += 1
                }
            }
            // An unclosed `[` is just a bracket.
            guard i < pattern.count else { return (character == "[", index + 1) }
            return (matched != negated, i + 1)
        default:
            return (pattern[index] == character, index + 1)
        }
    }

    private static func exists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }
}
