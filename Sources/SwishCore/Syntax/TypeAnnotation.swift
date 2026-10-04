import Foundation
import SwishKit

/// A type, as written in a declaration and as the checker works it out.
indirect enum TypeAnnotation: Hashable, Sendable, CustomStringConvertible {
    case any, bool, int, double, string
    /// A record whose fields aren't known: a builtin's row, until the
    /// builtins declare their types.
    case record
    case output
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

extension TypeAnnotation {
    /// Swift's types that Swish writes with an annotation of its own, by
    /// name: one table for the parser (`Int` is `.int`) and for finding the
    /// Swift type an annotation is (`.int` is `Int`). The generic ones are
    /// sugar: `[T]`, `T?`, `[K: V]`.
    private static let spelled: [(name: String, make: @Sendable ([TypeAnnotation]) -> TypeAnnotation?)] = [
        ("Int", { $0.isEmpty ? .int : nil }), ("Double", { $0.isEmpty ? .double : nil }),
        ("String", { $0.isEmpty ? .string : nil }), ("Bool", { $0.isEmpty ? .bool : nil }),
        ("Record", { $0.isEmpty ? .record : nil }),
        ("Output", { $0.isEmpty ? .output : nil }),
        ("Any", { $0.isEmpty ? .any : nil }), ("Value", { $0.isEmpty ? .any : nil }), ("Void", { $0.isEmpty ? .void : nil }),
        ("Array", { $0.count == 1 ? .list($0[0]) : nil }),
        ("Optional", { $0.count == 1 ? .optional($0[0]) : nil }),
        ("Dictionary", { $0.count == 2 ? .dictionary($0[0], $0[1]) : nil }),
    ]

    /// The annotation Swish writes `name<arguments>` with, if it has one of
    /// its own: `Int`, `Array<Int>` as `[Int]`.
    static func spelled(_ name: String, _ arguments: [TypeAnnotation] = []) -> TypeAnnotation? {
        spelled.lazy.compactMap { $0.name == name ? $0.make(arguments) : nil }.first
    }

    /// The Swift type this annotation stands for, by name, with its generic
    /// arguments: `.int` is `Int`, `[String]` is `Array<String>`. The
    /// inverse of `spelled`; nil for one that doesn't name a type.
    var swiftType: (name: String, arguments: [TypeAnnotation])? {
        switch self {
        case .named(let name): return (name, [])
        case .generic(let name, let arguments): return (name, arguments)
        case .list(let element): return ("Array", [element])
        case .optional(let wrapped): return ("Optional", [wrapped])
        case .dictionary(let key, let value): return ("Dictionary", [key, value])
        default:
            return TypeAnnotation.spelled.first { $0.make([]) == self }.map { ($0.name, []) }
        }
    }
}

