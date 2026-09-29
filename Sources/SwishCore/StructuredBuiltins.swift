import Darwin
import Foundation
import SwishKit

/// Builtins written in Swift. They're ordinary functions to the rest of
/// the shell: the same flags, help, overloads and streaming as Swish ones.
extension Shell {
    func installBuiltinFunctions() {
        scopes[0].bindings["env"] = Binding(value: .nothing, mutable: false, special: .environment)
        scopes[0].bindings["FileType"] = Binding(value: .object(Shell.fileType), mutable: false)
        scopes[0].bindings["JobState"] = Binding(value: .object(Shell.jobState), mutable: false)
        // In declaration order, so `ls | sorted --by type` puts files first.
        for type in [Shell.fileType, Shell.jobState] {
            enumConformances[ObjectIdentifier(type)] = ["Equatable", "Hashable", "Comparable"]
        }
        scopes[0].bindings["jobs"] = Binding(value: .nothing, mutable: false, special: .jobs)
        scopes[0].bindings["args"] = Binding(value: .list([]), mutable: false)
        installPrelude()
        installJSONAccess()
        // Swift's types by name, for their initializers and static members.
        for name in Bridge.types.keys {
            scopes[0].bindings[name] = Binding(value: .object(BridgedTypeName(name)), mutable: false)
        }
    }

    /// What the checker writes JSON access into: `json.name` is
    /// `$json(json, "name")`, `json.port?.int` is `$jsonAs(…, "int")`. Both
    /// give nil for nil, a missing field, or a value of another kind.
    private func installJSONAccess() {
        let field = Function(name: "$json", parameters: [
            Parameter(label: nil, name: "value", type: .any), Parameter(label: nil, name: "key", type: .any),
        ], returnType: nil, body: .native { _, args in
            switch (args["value"]!, args["key"]!) {
            case (.record(let record), .string(let key)): record[key] ?? .nothing
            case (.dictionary(let dictionary), let key): dictionary[key] ?? .nothing
            case (.list(let items), .int(let index)): items.indices.contains(index) ? items[index] : .nothing
            default: .nothing
            }
        })
        let accessor = Function(name: "$jsonAs", parameters: [
            Parameter(label: nil, name: "value", type: .any), Parameter(label: nil, name: "kind", type: .string),
        ], returnType: nil, body: .native { _, args in
            let value = args["value"]!
            guard case .string(let kind) = args["kind"]! else { return .nothing }
            switch (kind, value) {
            case ("string", .string), ("int", .int), ("double", .double), ("bool", .bool), ("array", .list): return value
            case ("double", .int(let n)): return .double(Double(n))
            case ("int", .double(let d)) where d == d.rounded() && abs(d) < 9e15: return .int(Int(d))
            case ("object", .record(let record)):
                return .dictionary(ValueDictionary(record.map { (Value.string($0.key), $0.value) }))
            case ("object", .dictionary): return value
            case ("isNull", _): return .bool(value == .nothing)
            default: return .nothing
            }
        })
        for function in [field, accessor] {
            scopes[0].bindings[function.name!] = Binding(
                value: .function(OverloadSet(name: function.name!, candidates: [function])), mutable: false
            )
        }
    }

    /// Each builtin's body, by name, for the prelude's declarations; a
    /// sequence method's also says how it reads the sequence: each item
    /// (`filter`), or all of them (`sorted`).
    func builtinBodies() -> [String: (body: FunctionBody, input: Parameter?)] {
        var bodies: [String: (body: FunctionBody, input: Parameter?)] = [:]
        for function in [ls(), ps(), from(), to(), table(), list(), members(), help(), with()] {
            bodies[function.name!] = (function.body, nil)
        }
        for method in [sorted(), filter(), map(), prefix(), reversed(), count(), uniqued(), select(), get()] {
            let input = method.parameters.first(where: \.isInput)!
            // Each item is an Element; all of them, a list of Elements.
            let type: TypeAnnotation = input.type.isList ? .list(.parameter("Element")) : .parameter("Element")
            bodies["Sequence." + method.name!] = (method.body, Parameter(label: nil, name: input.name, type: type, isInput: true))
        }
        return bodies
    }

    /// `with(env: ["EDITOR": "vim"]) { git commit }`: runs the closure with
    /// environment variables set, then puts them back.
    private func with() -> Function {
        builtin(
            "with", "Runs a closure with environment variables set.",
            [option("env", .dictionary(.string, .string)), positional("body", .function)],
            .native { shell, args in
                guard case .dictionary(let variables) = args["env"] else { return .nothing }
                let pairs = variables.map { ($0.key.description, $0.value.description) }
                return try shell.withEnvironment(pairs) { try shell.call(args["body"]!, with: []) }
            }
        )
    }

    /// What kind of entry `ls` found: `ls | where { $0.type == .directory }`.
    static let fileType = EnumType(name: "FileType", cases: ["file", "directory", "symlink", "other"].map { .init(name: $0) })

    /// A job's `state`.
    static let jobState = EnumType(name: "JobState", cases: ["running", "stopped", "done", "cancelled"].map { .init(name: $0) })

    // MARK: Sources

    private func ls() -> Function {
        builtin(
            "ls", "Lists directory contents as records.",
            [
                positional("paths", .string, variadic: true),
                option("all", .bool, default: .bool(false), short: "a"),
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
        var path: String
        var target: String?
    }

    private func fileEntry(named name: String, at path: String) -> Value? {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            reportItemError("ls: \(path): \(errorMessage(errno).lowercased())")
            return nil
        }
        let kind = info.st_mode & S_IFMT
        let (type, letter) = switch kind {
        case S_IFDIR: ("directory", "d")
        case S_IFLNK: ("symlink", "l")
        case S_IFREG: ("file", "-")
        default: ("other", "?")
        }
        let permissions = letter
            + [S_IRUSR, S_IWUSR, S_IXUSR, S_IRGRP, S_IWGRP, S_IXGRP, S_IROTH, S_IWOTH, S_IXOTH].enumerated().map { index, bit in
                info.st_mode & bit != 0 ? ["r", "w", "x"][index % 3] : "-"
            }.joined()
        let entry = FileEntry(
            name: name, type: type, size: FileSize(bytes: info.st_size),
            modified: date(info.st_mtimespec), permissions: permissions,
            owner: getpwuid(info.st_uid).map { String(cString: $0.pointee.pw_name) } ?? String(info.st_uid),
            created: date(info.st_birthtimespec), accessed: date(info.st_atimespec),
            path: path,
            target: kind == S_IFLNK ? try? FileManager.default.destinationOfSymbolicLink(atPath: path) : nil
        )
        guard case .record(var record) = try? ValueEncoder().encode(entry) else { return nil }
        record["type"] = .enumValue(EnumValue(type: Shell.fileType, name: type))
        // A nil target is still a field, as the struct declares it.
        if record["target"] == nil { record["target"] = .nothing }
        return .record(record)
    }

    private func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }

    private func ps() -> Function {
        builtin(
            "ps", "Lists running processes as records. Memory and CPU time are only known for your own processes.", [],
            .native { _, _ in
                // sysctl lists every process without privileges; proc_pidinfo
                // adds detail, but only for processes we're allowed to inspect.
                var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
                var size = 0
                guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else {
                    throw RuntimeError("ps: \(errorMessage(errno))")
                }
                let stride = MemoryLayout<kinfo_proc>.stride
                var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
                size = processes.count * stride
                guard sysctl(&mib, 3, &processes, &size, nil, 0) == 0 else {
                    throw RuntimeError("ps: \(errorMessage(errno))")
                }
                var timebase = mach_timebase_info()
                mach_timebase_info(&timebase)
                let secondsPerTick = Double(timebase.numer) / Double(timebase.denom) / 1e9

                var entries: [Value] = []
                for process in processes.prefix(size / stride).sorted(by: { $0.kp_proc.p_pid < $1.kp_proc.p_pid }) {
                    let pid = process.kp_proc.p_pid
                    let uid = process.kp_eproc.e_ucred.cr_uid
                    // p_comm is cut to 16 bytes; pbi_name, when we can read it, isn't.
                    var name = withUnsafeBytes(of: process.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                    var bsd = proc_bsdinfo()
                    if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                        let full = withUnsafeBytes(of: bsd.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                        if !full.isEmpty { name = full }
                    }
                    var task = proc_taskinfo()
                    let hasTask = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0
                    let entry = ProcessEntry(
                        pid: Int(pid), ppid: Int(process.kp_eproc.e_ppid), name: name,
                        user: getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid),
                        memory: hasTask ? FileSize(bytes: Int64(task.pti_resident_size)) : nil,
                        cpuTime: hasTask ? (Double(task.pti_total_user + task.pti_total_system) * secondsPerTick * 100).rounded() / 100 : nil,
                        threads: hasTask ? Int(task.pti_threadnum) : nil
                    )
                    entries.append(try ValueEncoder().encode(entry))
                }
                return .list(entries)
            }
        )
    }

    private struct ProcessEntry: Encodable {
        var pid: Int
        var ppid: Int
        var name: String
        var user: String
        var memory: FileSize?
        /// Seconds.
        var cpuTime: Double?
        var threads: Int?
    }

    // MARK: Sequence methods

    // Methods of every sequence (a list, a stream, or an Output's lines),
    // named as Swift's are: `xs.sorted(by: \.size)`, and as a pipeline
    // stage with the input as the sequence, `ls | sorted --by size`. Their
    // signatures are in the prelude.

    private func filter() -> Function {
        builtin(
            "filter", "The items for which the predicate returns true.",
            [input("item", .any), positional("isIncluded", .function)],
            docs: ["isIncluded": "a closure like { $0.size > 1.mb }"],
            .native { shell, args in
                let item = args["item"]!
                let verdict = try shell.call(args["isIncluded"]!, with: [item])
                guard case .bool(let keep) = verdict else {
                    throw RuntimeError("filter: the predicate must return a Bool, not \(verdict.typeName)")
                }
                return keep ? item : .nothing
            }
        )
    }

    private func map() -> Function {
        builtin(
            "map", "Each item transformed by the closure; nil results are dropped.",
            [input("item", .any), positional("transform", .function)],
            docs: ["transform": "a closure like { $0.name }"],
            .native { shell, args in
                try shell.call(args["transform"]!, with: [args["item"]!])
            }
        )
    }

    private func select() -> Function {
        builtin(
            "select", "Keeps only the named fields of each record or object.",
            [input("item", .any), positional("fields", .string, variadic: true)],
            .native { _, args in
                guard let record = args["item"]?.asRecord else {
                    throw RuntimeError("select: \(args["item"]!.description) has no fields")
                }
                var selected = Record()
                for field in args.strings("fields") { selected[field] = record[field] ?? .nothing }
                return .record(selected)
            }
        )
    }

    private func get() -> Function {
        builtin(
            "get", "The value of one field of each item.",
            [input("item", .any), positional("key", .any)],
            .native { shell, args in
                if case .function(let keyPath as KeyPathValue)? = args["key"] {
                    return try keyPath.read(from: args["item"]!, in: shell)
                }
                return try shell.member(args.strings("key")[0], of: args["item"]!)
            }
        )
    }

    private func sorted() -> Function {
        builtin(
            "sorted", "The items in order.",
            [input("items", .list(.any)), option("by", .any, default: .nothing), option("reverse", .bool, default: .bool(false))],
            .native { shell, args in
                guard case .list(let items) = args["items"] else { return .list([]) }
                var ordered: [Value]
                // The prelude's overloads name `by` for what it is: a key path
                // (`key`) or a comparison (`areInIncreasingOrder`).
                let by = args["key"] ?? args["areInIncreasingOrder"] ?? args["by"]
                switch by {
                case .function(let keyPath as KeyPathValue)?:
                    // By a field: ties keep their input order.
                    let keyed = try items.enumerated().map { (key: try keyPath.read(from: $1, in: shell), index: $0, item: $1) }
                    ordered = keyed.sorted { a, b in
                        let order = a.key.order(comparedTo: b.key)
                        return order != .orderedSame ? order == .orderedAscending : a.index < b.index
                    }.map(\.item)
                case .function?:
                    ordered = try items.sorted { a, b in
                        let verdict = try shell.call(by!, with: [a, b])
                        guard case .bool(let before) = verdict else {
                            throw RuntimeError("sorted: the closure must return a Bool, not \(verdict.typeName)")
                        }
                        return before
                    }
                default:
                    ordered = items.enumerated().sorted { a, b in
                        let order = a.element.order(comparedTo: b.element)
                        return order != .orderedSame ? order == .orderedAscending : a.offset < b.offset
                    }.map(\.element)
                }
                if args["reverse"] == .bool(true) { ordered.reverse() }
                return .list(ordered)
            }
        )
    }

    private func uniqued() -> Function {
        builtin(
            "uniqued", "The items without repeats, first ones kept.", [input("items", .list(.any))],
            .native { _, args in
                guard case .list(let items) = args["items"] else { return .list([]) }
                var seen: Set<Value> = []
                return .list(items.filter { seen.insert($0).inserted })
            }
        )
    }

    private func prefix() -> Function {
        builtin(
            "prefix", "The first items; stops reading after them.",
            [input("items", .list(.any)), positional("maxLength", .int, default: .int(1))],
            .stream { _, upstream, args in
                guard case .int(let count) = args["maxLength"], count >= 0 else {
                    throw RuntimeError("prefix: the length must be zero or more")
                }
                var taken = 0
                return ValueStream {
                    guard taken < count, let item = try upstream.next() else { return nil }
                    taken += 1
                    return item
                }
            }
        )
    }

    private func count() -> Function {
        builtin(
            "count", "How many items there are, or how many the predicate is true for.",
            [input("items", .list(.any)), option("where", .optional(.function), default: .nothing)],
            docs: ["where": "a closure like { $0.size > 1.mb }"],
            .native { shell, args in
                guard case .list(let items) = args["items"] else { return .int(0) }
                guard let predicate = args["predicate"], case .function = predicate else { return .int(items.count) }
                var count = 0
                for item in items {
                    let verdict = try shell.call(predicate, with: [item])
                    guard case .bool(let matches) = verdict else {
                        throw RuntimeError("count: the predicate must return a Bool, not \(verdict.typeName)")
                    }
                    if matches { count += 1 }
                }
                return .int(count)
            }
        )
    }

    private func reversed() -> Function {
        builtin(
            "reversed", "The items in reverse order.", [input("items", .list(.any))],
            .native { _, args in
                guard case .list(let items) = args["items"] else { return .list([]) }
                return .list(items.reversed())
            }
        )
    }

    // MARK: Conversions

    private func from() -> Function {
        builtin(
            "from", "Parses text into values.",
            [positional("format", .string), input("text", .list(.any))],
            docs: ["format": "json"],
            .native { _, args in
                let format = args.strings("format")[0]
                guard format == "json" else { throw RuntimeError("from: unknown format '\(format)' (supported: json)") }
                return try JSON.parse(args.strings("text").joined(separator: "\n"))
            }
        )
    }

    private func to() -> Function {
        builtin(
            "to", "Converts the input to text.",
            [positional("format", .string), input("items", .list(.any))],
            docs: ["format": "json, or text for how it would be displayed"],
            .native { _, args in
                guard case .list(let items) = args["items"] else { return .nothing }
                switch args.strings("format")[0] {
                case "json":
                    return .string(try JSON.text(items.count == 1 ? items[0] : .list(items)))
                case "text":
                    return .list(Shell.formattedLines(items, useViews: true))
                case let format:
                    throw RuntimeError("to: unknown format '\(format)' (supported: json, text)")
                }
            }
        )
    }

    private func table() -> Function {
        builtin(
            "table", "Lays records out as a table with every field.", [input("items", .list(.any))],
            .native { _, args in
                guard case .list(let items) = args["items"] else { return .list([]) }
                return .list(Shell.formattedLines(items, useViews: false))
            }
        )
    }

    private func list() -> Function {
        builtin(
            "list", "Shows each record as a list of fields.", [input("items", .list(.any))],
            .native { shell, args in
                guard case .list(let items) = args["items"] else { return .list([]) }
                var lines: [String] = []
                for item in items {
                    if !lines.isEmpty { lines.append("") }
                    if let record = item.asRecord {
                        lines += shell.keyValueLines(record)
                    } else {
                        lines.append(item.description)
                    }
                }
                return .list(lines.map(Value.string))
            }
        )
    }

    private func members() -> Function {
        builtin(
            "members", "Describes the input: each type's fields and members.", [input("items", .list(.any))],
            .native { _, args in
                guard case .list(let items) = args["items"] else { return .list([]) }
                var rows: [Value] = []
                var seen: Set<String> = []
                func add(_ type: String, _ name: String, _ kind: String) {
                    guard seen.insert("\(type).\(name)").inserted else { return }
                    rows.append(.record(Record(["type": .string(type), "name": .string(name), "kind": .string(kind)], typeName: "Member")))
                }
                for item in items {
                    switch item {
                    case .record(let record):
                        for (key, value) in record { add(record.typeName ?? "Record", key, value.typeName) }
                        for member in ["count", "isEmpty", "keys", "values"] { add(record.typeName ?? "Record", member, "member") }
                    case .function(let set as OverloadSet):
                        for candidate in set.candidates { add("Function", candidate.signature, "signature") }
                    case .object(let object):
                        for name in object.memberNames {
                            add(object.typeName, name, object.member(name).map { $0.typeName } ?? "")
                        }
                    default:
                        let members = switch item {
                        case .list: ["count", "isEmpty", "first", "last"]
                        case .string: ["count", "isEmpty", "lines"]
                        case .filesize: ["bytes"]
                        default: [String]()
                        }
                        if members.isEmpty { add(item.typeName, "", "") }
                        for member in members { add(item.typeName, member, "member") }
                    }
                }
                return .list(rows)
            }
        )
    }

    /// The lines the display step would show for `items`.
    static func formattedLines(_ items: [Value], useViews: Bool) -> [Value] {
        var lines: [Value] = []
        let formatter = Formatter(useViews: useViews) { text in
            lines.append(.string(String(text.dropLast())))
            return true
        }
        for item in items { formatter.add(item) }
        formatter.finish()
        return lines
    }
}

// MARK: - Declaring builtins

private func builtin(
    _ name: String, _ summary: String, _ parameters: [Parameter],
    docs: [String: String] = [:], _ body: FunctionBody
) -> Function {
    Function(
        name: name, parameters: parameters, returnType: nil, body: body,
        documentation: Documentation(summary: summary, parameters: docs)
    )
}

private func positional(_ name: String, _ type: TypeAnnotation, default value: Value? = nil, variadic: Bool = false) -> Parameter {
    Parameter(label: nil, name: name, type: type, variadic: variadic, defaultValue: value.map(Expr.literal))
}

private func option(_ label: String, _ type: TypeAnnotation, default value: Value? = nil, short: Character? = nil) -> Parameter {
    Parameter(label: label, name: label, type: type, defaultValue: value.map(Expr.literal), shortFlag: short)
}

private func input(_ name: String, _ type: TypeAnnotation) -> Parameter {
    Parameter(label: nil, name: name, type: type, isInput: true)
}

private extension Dictionary where Key == String, Value == SwishKit.Value {
    /// A String or list-of-Strings argument as an array; empty if absent.
    func strings(_ key: String) -> [String] {
        switch self[key] {
        case .string(let text)?: [text]
        case .list(let items)?: items.map(\.description)
        default: []
        }
    }
}

extension SwishKit.Value {
    /// A total order for sorting: numbers numerically (Int and Double
    /// together), then by kind for values of different kinds.
    func order(comparedTo other: SwishKit.Value) -> ComparisonResult {
        func compare<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
            a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
        }
        switch (self, other) {
        case (.bool(let a), .bool(let b)): return compare(a ? 1 : 0, b ? 1 : 0)
        case (.int, .int), (.int, .double), (.double, .int), (.double, .double): return compare(asDouble!, other.asDouble!)
        case (.string(let a), .string(let b)): return a.compare(b)
        case (.enumValue(let a), .enumValue(let b)) where a.type === b.type: return compare(a.index, b.index)
        case (.object(let a as SwiftValue), .object(let b as SwiftValue)):
            if let less = a.isLess(than: b) { return less ? .orderedAscending : b.isLess(than: a) == true ? .orderedDescending : .orderedSame }
            return compare(a.typeName, b.typeName)
        case (.output(let a), _): return Value.string(a.text).order(comparedTo: other)
        case (_, .output(let b)): return order(comparedTo: .string(b.text))
        case (.filesize(let a), .filesize(let b)): return compare(a, b)
        case (.date(let a), .date(let b)): return compare(a, b)
        case (.list(let a), .list(let b)):
            for (x, y) in zip(a, b) {
                let order = x.order(comparedTo: y)
                if order != .orderedSame { return order }
            }
            return compare(a.count, b.count)
        default: return compare(kindRank, other.kindRank)
        }
    }

    private var kindRank: Int {
        switch self {
        case .nothing: 0
        case .bool: 1
        case .int, .double: 2
        case .filesize: 3
        case .date: 4
        case .string, .output: 5
        case .list: 6
        case .enumValue: 6
        case .record, .dictionary: 7
        case .object, .function: 8
        @unknown default: 9
        }
    }
}
