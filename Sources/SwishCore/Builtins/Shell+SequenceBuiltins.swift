import Foundation
import SwishKit

extension Shell {
    // MARK: Sequence methods

    // What the prelude adds to every sequence that Swift can't say (see
    // `Flow` for `filter`, `map`, `compactMap` and `prefix`, which it can).
    // Its signature is in the prelude.

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
}
