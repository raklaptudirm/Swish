import Foundation
import SwishKit

/// Every function declared under one name. A name declared with `func` is
/// always bound to one of these, even with a single candidate.
package final class OverloadSet: Callable, @unchecked Sendable {
    package let name: String
    package let candidates: [Function]

    package init(name: String, candidates: [Function]) {
        self.name = name
        self.candidates = candidates
    }

    package var description: String {
        candidates.count == 1 ? candidates[0].description : "<func \(name) (\(candidates.count) overloads)>"
    }
}

extension Parameter {
    /// As a declaration writes it: `_ name: String`, `by key: Int`,
    /// `@input items: [Int]`, `paths: FilePath...`.
    package var declaration: [AttributedString] {
        var pieces: [AttributedString] = []
        if isInput { pieces += [.init("@input", .keyword), .init(" ")] }
        if label == name {
            pieces.append(.init(name, .variable))
        } else {
            pieces += [.init(label ?? "_", label == nil ? nil : .variable), .init(" "), .init(name, .variable)]
        }
        return pieces + [.init(": ")] + type.styled + (variadic ? [.init("...")] : [])
    }
}

extension Function {
    /// Like a Swift declaration: `greet(_ name: String, times: Int) -> String`,
    /// without the parameters `hiding` says, in pieces by what each is.
    package func declaration(
        as name: String? = nil, nameStyle: DisplayStyle = .command, hiding hidden: (Parameter) -> Bool
    ) -> [AttributedString] {
        var pieces: [AttributedString] = [.init(name ?? self.name ?? "closure", nameStyle), .init("(")]
        for (index, parameter) in parameters.filter({ !hidden($0) }).enumerated() {
            pieces += (index > 0 ? [.init(", ")] : []) + parameter.declaration
        }
        pieces.append(.init(")"))
        if let returnType, returnType != .void { pieces += [.init(" -> ")] + returnType.styled }
        return pieces
    }

    /// Like a Swift declaration: `greet(_ name: String, times: Int) -> String`.
    /// A Swift member's receiver, as a stage's input, isn't written.
    package var signature: String {
        AttributedString(joining: declaration { $0.isInput && $0.name == "self" }).text
    }

    package func declaration(hiding hidden: (Parameter) -> Bool) -> [AttributedString] {
        declaration(as: nil, nameStyle: .command, hiding: hidden)
    }
}

/// `\.size` or `\.status.code`: reads the path of members from a value.
/// Where a function is wanted it's one, as in Swift: `xs.map(\.name)`.
package final class KeyPathValue: Callable, @unchecked Sendable {
    package let path: [String]

    package init(path: [String]) {
        self.path = path
    }

    package var description: String { "\\." + path.joined(separator: ".") }

    package func read(from value: Value, in shell: Interpreter) throws -> Value {
        try path.reduce(value) { try shell.member($1, of: $0) }
    }
}

/// One argument to a command: text, or a value like the closure in
/// `where { $0.size > 1.mb }`.
package enum CommandArgument: CustomStringConvertible {
    case text(String)
    case value(Value)
    /// From a stage written as a call, `ls | sorted(by: "size")`: bound by
    /// Swift's rules instead of as a command line.
    case call(Argument)

    package var description: String {
        switch self {
        case .text(let text): text
        case .value(let value): value.description
        case .call(let argument): (argument.label.map { "\($0): " } ?? "") + "…"
        }
    }
}

extension TypeAnnotation {
    package var isList: Bool {
        if case .list = self { true } else { false }
    }

    /// Whether a closure can be passed for it.
    package var acceptsFunction: Bool {
        switch self {
        case .function, .functionType, .any: true
        case .optional(let wrapped): wrapped.acceptsFunction
        default: false
        }
    }
}

// MARK: Declaring builtins

extension Function {
    /// A builtin written in Swift, with its documentation.
    package static func builtin(
        _ name: String, _ summary: String, _ parameters: [Parameter],
        docs: [String: String] = [:], _ body: FunctionBody
    ) -> Function {
        Function(
            name: name, parameters: parameters, returnType: nil, body: body,
            documentation: Documentation(summary: summary, parameters: docs)
        )
    }
}

extension Parameter {
    /// An argument by position.
    package static func positional(_ name: String, _ type: TypeAnnotation, default value: Value? = nil, variadic: Bool = false) -> Parameter {
        Parameter(label: nil, name: name, type: type, variadic: variadic, defaultValue: value.map(Expr.literal))
    }

    /// A labeled argument: a flag on the command line.
    package static func option(_ label: String, _ type: TypeAnnotation, default value: Value? = nil, short: Character? = nil) -> Parameter {
        Parameter(label: label, name: label, type: type, defaultValue: value.map(Expr.literal), shortFlag: short)
    }

    /// What's piped in.
    package static func input(_ name: String, _ type: TypeAnnotation) -> Parameter {
        Parameter(label: nil, name: name, type: type, isInput: true)
    }
}
