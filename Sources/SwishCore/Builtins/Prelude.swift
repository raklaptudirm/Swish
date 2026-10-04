import Foundation
import SwishKit

/// The builtins' types and signatures, written in Swish and read when the
/// shell starts. The checker works from these; the bodies are in Swift
/// (StructuredBuiltins.swift), found by name. Doc comments are what `help`
/// and `--help` show.
extension Shell {
    static let prelude = #"""
    /// How a command exited: `output.status`.
    struct Status: Equatable, Hashable, Encodable {
        let code: Int?
        let signal: Int?
        let succeeded: Bool
    }

    /// What `catch` binds.
    struct Error {
        let message: String
        let status: Status
        let text: String
    }

    /// A function `help` lists.
    struct Help: Equatable, Hashable, Encodable {
        let name: String
        let source: String
        let summary: String
        let usage: String
        let description: String
    }

    /// A member `members` describes.
    struct Member: Equatable, Hashable, Encodable {
        let type: String
        let name: String
        let kind: String
    }

    /// Parsed JSON: read by field (json.name, json["name"]) or element
    /// (json[0]), each giving JSON?, and as a type with .string, .int,
    /// .double, .bool, .array, .object and .isNull.
    struct JSON {}

    /// Describes the input: each type's fields and members.
    func members(@input _ items: [Any]) -> [Member]

    /// Lists every function you can call.
    func help() -> [Help]

    /// Shows a function, shell builtin or program in full, or a type's
    /// members: `help String`, `help FilePath`, or a struct of yours.
    /// - Parameter name: a function, shell builtin, type or program
    func help(_ name: String) -> [AttributedString]

    extension Sequence {
        /// Keeps only the named fields of each record.
        func select(_ fields: String...) -> [Any]
    }
    """#

    /// Reads the prelude, binding its types, functions and sequence
    /// methods in the outermost scope with their Swift bodies.
    func installPrelude() {
        // The Swift types the declarations may name.
        let bridgedTypeNames = Dictionary(uniqueKeysWithValues: Bridge.types.keys.map { ($0, NameKind.type) })
        let program: Program
        do {
            program = try Parser.parsePrelude(Shell.prelude + "\n" + Bridge.standardTypes, bound: bridgedTypeNames)
        } catch {
            preconditionFailure("the prelude doesn't parse: \(error)")
        }
        let natives = builtinBodies()
        for statement in program.statements {
            switch statement {
            case .structDecl(let decl):
                // Declared as any struct is, then moved out to the builtins.
                declare(decl)
                scopes[0].bindings[decl.name] = scopes[scopes.count - 1].bindings.removeValue(forKey: decl.name)
            case .enumDecl(let decl):
                do { try declare(decl) } catch { preconditionFailure("the prelude's \(decl.name): \(error)") }
                scopes[0].bindings[decl.name] = scopes[scopes.count - 1].bindings.removeValue(forKey: decl.name)
            case .function(let decl):
                guard let native = natives[decl.name] else { preconditionFailure("no body for \(decl.name)") }
                let function = builtinFunction(decl, native.body, input: nil)
                scopes[0].declare(function, named: decl.name)
            case .extensionDecl(_, let methods):
                for method in methods {
                    guard let native = natives["Sequence." + method.name] else {
                        preconditionFailure("no body for Sequence.\(method.name)")
                    }
                    let function = builtinFunction(method, native.body, input: native.input)
                    let existing = sequenceMethods[method.name]?.candidates ?? []
                    sequenceMethods[method.name] = OverloadSet(name: method.name, candidates: existing + [function])
                }
            default:
                preconditionFailure("the prelude only declares")
            }
        }
    }

    /// A builtin as the shell's functions are: the prelude's signature, a
    /// Swift body, and for a sequence method, the `@input` it reads the
    /// sequence from (each item, or all of them).
    private func builtinFunction(_ decl: FunctionDecl, _ body: FunctionBody, input: Parameter?) -> Function {
        Function(
            name: decl.name, parameters: (input.map { [$0] } ?? []) + decl.parameters, returnType: decl.returnType,
            body: body, documentation: decl.documentation, isThrowing: decl.isThrowing,
            isRethrowing: decl.isRethrowing, generics: decl.generics
        )
    }
}
