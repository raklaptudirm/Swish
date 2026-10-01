import Foundation
import SwishKit

extension Shell {
    // MARK: Sequence methods

    // Methods of every sequence (a list, a stream, or an Output's lines),
    // named as Swift's are: `xs.sorted(by: \.size)`, and as a pipeline
    // stage with the input as the sequence, `ls | sorted --by size`. Their
    // signatures are in the prelude.

    func filter() -> Function {
        .builtin(
            "filter", "The items for which the predicate returns true.",
            [.input("item", .any), .positional("isIncluded", .function)],
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

    func map() -> Function {
        .builtin(
            "map", "Each item transformed by the closure, nil results included.",
            [.input("items", .list(.any)), .positional("transform", .function)],
            docs: ["transform": "a closure like { $0.name }"],
            // A stream, so a nil result is an item too; lazily, so
            // `yes | map { … } | prefix 3` ends.
            .stream { shell, upstream, args in
                ValueStream {
                    guard let item = try upstream.next() else { return nil }
                    return try shell.call(args["transform"]!, with: [item])
                }
            }
        )
    }

    func compactMap() -> Function {
        .builtin(
            "compactMap", "Each item transformed by the closure, nil results dropped.",
            [.input("item", .any), .positional("transform", .function)],
            docs: ["transform": "a closure like { $0.name }"],
            .native { shell, args in
                try shell.call(args["transform"]!, with: [args["item"]!])
            }
        )
    }

    func select() -> Function {
        .builtin(
            "select", "Keeps only the named fields of each record or object.",
            [.input("item", .any), .positional("fields", .string, variadic: true)],
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

    func get() -> Function {
        .builtin(
            "get", "The value of one field of each item.",
            [.input("item", .any), .positional("key", .any)],
            .native { shell, args in
                if case .function(let keyPath as KeyPathValue)? = args["key"] {
                    return try keyPath.read(from: args["item"]!, in: shell)
                }
                return try shell.member(args.strings("key")[0], of: args["item"]!)
            }
        )
    }

    func sorted() -> Function {
        .builtin(
            "sorted", "The items in order.",
            [.input("items", .list(.any)), .option("by", .any)],
            .native { shell, args in
                guard case .list(let items) = args["items"],
                      case .function(let keyPath as KeyPathValue)? = args["key"] ?? args["by"] else { return .list([]) }
                // By a field: ties keep their input order.
                let keyed = try items.enumerated().map { (key: try keyPath.read(from: $1, in: shell), index: $0, item: $1) }
                return .list(keyed.sorted { a, b in
                    let order = a.key.order(comparedTo: b.key)
                    return order != .orderedSame ? order == .orderedAscending : a.index < b.index
                }.map(\.item))
            }
        )
    }

    func uniqued() -> Function {
        .builtin(
            "uniqued", "The items without repeats, first ones kept.", [.input("items", .list(.any))],
            .native { _, args in
                guard case .list(let items) = args["items"] else { return .list([]) }
                var seen: Set<Value> = []
                return .list(items.filter { seen.insert($0).inserted })
            }
        )
    }

    func prefix() -> Function {
        .builtin(
            "prefix", "The first items; stops reading after them.",
            [.input("items", .list(.any)), .positional("maxLength", .int, default: .int(1))],
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

    func count() -> Function {
        .builtin(
            "count", "How many items there are, or how many the predicate is true for.",
            [.input("items", .list(.any)), .option("where", .optional(.function), default: .nothing)],
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

    func reversed() -> Function {
        .builtin(
            "reversed", "The items in reverse order.", [.input("items", .list(.any))],
            .native { _, args in
                guard case .list(let items) = args["items"] else { return .list([]) }
                return .list(items.reversed())
            }
        )
    }
}
