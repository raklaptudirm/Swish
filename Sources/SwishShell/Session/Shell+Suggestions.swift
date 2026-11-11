import Swiit

// What a mistyped name was likely meant to be.

extension Shell {
    /// The commands nearest `name` in spelling, nearest first and at most three: programs on
    /// `PATH`, functions and shell builtins whose name is one or two edits away (a letter added,
    /// left out, changed, or two swapped): one for a name of five characters or fewer.
    func commands(near name: String) -> [String] {
        var names = executableNames()
        for symbol in interpreter.globals() where symbol.function != nil {
            names.insert(symbol.name)
        }
        for builtin in builtins.values where builtin.works { names.insert(builtin.name) }
        let allowed = name.count <= 5 ? 1 : 2
        return
            names
            .compactMap { candidate -> (String, Int)? in
                guard candidate != name, abs(candidate.count - name.count) <= allowed else {
                    return nil
                }
                let distance = Shell.editDistance(name, candidate)
                return distance <= allowed ? (candidate, distance) : nil
            }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
            .prefix(3)
            .map(\.0)
    }

    /// What is said after "command not found": the names it was likely meant to be.
    func commandNotFoundHint(_ name: String) -> String {
        let near = commands(near: name)
        guard !near.isEmpty else { return "" }
        return "; did you mean " + near.map { "`\($0)`" }.joined(separator: ", or ") + "?"
    }

    /// Edits from one to the other: a character added, removed or replaced, or two side by side
    /// swapped (`gti` is one edit from `git`).
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], previous2[j - 2] + 1)
                }
            }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }
}
