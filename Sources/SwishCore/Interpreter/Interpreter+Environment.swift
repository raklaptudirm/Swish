import Foundation
import SwishKit
import SwishStandardLibrary

extension Interpreter {
    func isEnvironment(_ expr: Expr) -> Bool {
        guard case .variable(let name) = expr else { return false }
        return lookup(name)?.special == .environment
    }

    func environmentRecord() -> Value {
        var record = Record(typeName: "Environment")
        for (name, value) in shellLayer?.environment.all() ?? [] {
            record[name] = .string(value)
        }
        return .record(record)
    }

    /// Joins a string's parts into one string. Interpolation never splits.
    func expand(_ parts: [StringPart]) throws -> String {
        try parts.map { part in
            switch part {
            case .literal(let text): text
            case .expression(let expr): try evaluate(expr).description
            }
        }.joined()
    }
}
