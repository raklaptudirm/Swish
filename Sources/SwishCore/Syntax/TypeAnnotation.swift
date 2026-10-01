import Foundation
import SwishKit

/// A type, as written in a declaration and as the checker works it out.
indirect enum TypeAnnotation: Hashable, Sendable, CustomStringConvertible {
    case any, bool, int, double, string
    /// A record whose fields aren't known: a builtin's row, until the
    /// builtins declare their types.
    case record
    case filesize, date, output
    /// `()`: what a function without `->` returns.
    case void
    /// A struct or enum, declared in Swish or by the shell, like `FileType`.
    case named(String)
    case list(TypeAnnotation)
    /// `[K: V]`.
    case dictionary(TypeAnnotation, TypeAnnotation)
    /// `(name: String, Int)`.
    case tuple([TupleElement])
    /// A generic parameter, like `Element` or `T` in a builtin's signature.
    case parameter(String)
    /// `KeyPath<Root, Value>`, what `\.size` is.
    case keyPath(TypeAnnotation, TypeAnnotation)
    /// Any function: a closure whose signature isn't known yet.
    case function
    /// `(Int, String) -> Bool`, or `(Int) throws -> Bool`.
    case functionType([TypeAnnotation], TypeAnnotation, throws: Bool = false)
    /// `T?`: a T, or nil.
    case optional(TypeAnnotation)
    /// A generic Swift type Swish holds as it is: `Set<Int>`, `ClosedRange<Int>`.
    case generic(String, [TypeAnnotation])
    /// What a Swift parameter `S: Sequence` with `S.Element == E` takes:
    /// any sequence of E, as `some Sequence<E>` says.
    case someSequence(TypeAnnotation)
    /// Not known yet: what a program prints, or a builtin that hasn't
    /// declared its type. It fits anywhere, and anything fits it.
    case unknown

    struct TupleElement: Hashable, Sendable {
        var label: String?
        var type: TypeAnnotation
    }

    var description: String {
        switch self {
        case .any: "Any"
        case .bool: "Bool"
        case .int: "Int"
        case .double: "Double"
        case .string: "String"
        case .record: "Record"
        case .filesize: "FileSize"
        case .date: "Date"
        case .output: "Output"
        case .void: "Void"
        case .list(let element): "[\(element)]"
        case .dictionary(let key, let value): "[\(key): \(value)]"
        case .tuple(let elements):
            "(" + elements.map { ($0.label.map { "\($0): " } ?? "") + $0.type.description }.joined(separator: ", ") + ")"
        case .function: "function"
        case .functionType(let parameters, let result, let throwing):
            "(" + parameters.map(\.description).joined(separator: ", ") + ")" + (throwing ? " throws" : "") + " -> \(result)"
        case .named(let name), .parameter(let name): name
        case .generic(let name, let arguments): "\(name)<\(arguments.map(\.description).joined(separator: ", "))>"
        case .someSequence(let element): "some Sequence<\(element)>"
        case .keyPath(let root, let value): "KeyPath<\(root), \(value)>"
        case .optional(let wrapped):
            if case .functionType = wrapped { "(\(wrapped))?" } else { "\(wrapped)?" }
        case .unknown: "_"
        }
    }
}
