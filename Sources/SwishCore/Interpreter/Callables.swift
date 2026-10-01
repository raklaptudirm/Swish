import Foundation
import SwishKit

/// Every function declared under one name. A name declared with `func` is
/// always bound to one of these, even with a single candidate.
final class OverloadSet: Callable, @unchecked Sendable {
    let name: String
    let candidates: [Function]

    init(name: String, candidates: [Function]) {
        self.name = name
        self.candidates = candidates
    }

    var description: String {
        candidates.count == 1 ? candidates[0].description : "<func \(name) (\(candidates.count) overloads)>"
    }
}

extension Function {
    /// Like a Swift declaration: `greet(_ name: String, times: Int) -> String`.
    var signature: String {
        // A Swift member's receiver, as a stage's input, isn't written.
        let parameters = parameters.filter { !($0.isInput && $0.name == "self") }.map { p in
            let names = p.label == p.name ? p.name : "\(p.label ?? "_") \(p.name)"
            return "\(p.isInput ? "@input " : "")\(names): \(p.type)\(p.variadic ? "..." : "")"
        }
        return "\(name ?? "closure")(\(parameters.joined(separator: ", ")))" + (returnType.map { " -> \($0)" } ?? "")
    }
}

/// `\.size` or `\.status.code`: reads the path of members from a value.
/// Where a function is wanted it's one, as in Swift: `xs.map(\.name)`.
final class KeyPathValue: Callable, @unchecked Sendable {
    let path: [String]

    init(path: [String]) {
        self.path = path
    }

    var description: String { "\\." + path.joined(separator: ".") }

    func read(from value: Value, in shell: Shell) throws -> Value {
        try path.reduce(value) { try shell.member($1, of: $0) }
    }
}

/// One argument to a command: text, or a value like the closure in
/// `where { $0.size > 1.mb }`.
enum CommandArgument: CustomStringConvertible {
    case text(String)
    case value(Value)
    /// From a stage written as a call, `ls | sorted(by: "size")`: bound by
    /// Swift's rules instead of as a command line.
    case call(Argument)

    var description: String {
        switch self {
        case .text(let text): text
        case .value(let value): value.description
        case .call(let argument): (argument.label.map { "\($0): " } ?? "") + "…"
        }
    }
}

extension TypeAnnotation {
    var isList: Bool {
        if case .list = self { true } else { false }
    }

    /// Whether a closure can be passed for it.
    var acceptsFunction: Bool {
        switch self {
        case .function, .functionType, .any: true
        case .optional(let wrapped): wrapped.acceptsFunction
        default: false
        }
    }
}
