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
}
