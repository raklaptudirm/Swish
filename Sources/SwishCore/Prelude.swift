import Foundation
import SwishKit

/// The builtins' types and signatures, written in Swish and read when the
/// shell starts. The checker works from these; the bodies are in Swift
/// (StructuredBuiltins.swift), found by name. Doc comments are what `help`
/// and `--help` show.
extension Shell {
    static let prelude = #"""
    /// An entry `ls` lists.
    struct FileEntry: Equatable, Hashable, Encodable {
        let name: String
        let type: FileType
        let size: FileSize
        let modified: Date
        let permissions: String
        let owner: String
        let created: Date
        let accessed: Date
        let path: String
        let target: String?
    }

    /// A process `ps` lists.
    struct ProcessEntry: Equatable, Hashable, Encodable {
        let pid: Int
        let ppid: Int
        let name: String
        let user: String
        let memory: FileSize?
        let cpuTime: Double?
        let threads: Int?
    }

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

    /// Lists directory contents.
    /// - Parameter paths: files or directories to list (default: the current directory)
    /// - Parameter all: include hidden files
    func ls(_ paths: String..., @flag("a") all: Bool = false) -> [FileEntry]

    /// Lists running processes. Memory and CPU time are only known for your own processes.
    func ps() -> [ProcessEntry]

    /// Parses text into values.
    /// - Parameter format: json
    func from(_ format: String, @input _ text: [String]) -> JSON

    /// Converts the input to text: json, or text for how it would be displayed.
    /// - Parameter format: json or text
    func to(_ format: String, @input _ items: [Any]) -> String

    /// Lays records out as a table with every field.
    func table(@input _ items: [Any]) -> [String]

    /// Shows each record as a list of fields.
    func list(@input _ items: [Any]) -> [String]

    /// Describes the input: each type's fields and members.
    func members(@input _ items: [Any]) -> [Member]

    /// Lists every function you can call.
    func help() -> [Help]

    /// Shows a function, shell builtin or program in full.
    /// - Parameter name: a function, shell builtin or program
    func help(_ name: String) -> [String]

    /// Runs a closure with environment variables set.
    func with<T>(env: [String: String], _ body: () throws -> T) rethrows -> T

    extension Sequence {
        /// The items for which the predicate returns true.
        /// - Parameter isIncluded: a closure like { $0.size > 1.mb }
        func filter(_ isIncluded: (Element) throws -> Bool) rethrows -> [Element]

        /// Each item transformed; nil results are dropped.
        /// - Parameter transform: a closure like { $0.name }, or a key path like \.name
        func map<T>(_ transform: (Element) throws -> T) rethrows -> [T]

        /// The items in order.
        func sorted(@flag("r") reverse: Bool = false) -> [Element] where Element: Comparable

        /// The items in order of a field.
        /// - Parameter by: the field, as in --by size or by: \.size
        func sorted<V: Comparable>(@flag("b") by key: KeyPath<Element, V>, @flag("r") reverse: Bool = false) -> [Element]

        /// The items in the order a closure says: whether $0 comes before $1.
        func sorted(by areInIncreasingOrder: (Element, Element) throws -> Bool, @flag("r") reverse: Bool = false) rethrows -> [Element]

        /// The first items; stops reading after them.
        func prefix(_ maxLength: Int = 1) -> [Element]

        /// The items in reverse order.
        func reversed() -> [Element]

        /// How many items there are, or how many the predicate is true for.
        /// - Parameter where: a closure like { $0.size > 1.mb }
        func count(where predicate: ((Element) throws -> Bool)? = nil) rethrows -> Int

        /// The items without repeats, first ones kept.
        func uniqued() -> [Element] where Element: Hashable

        /// Keeps only the named fields of each record.
        func select(_ fields: String...) -> [Any]

        /// The value of one field of each item.
        /// - Parameter key: a field, as in get name or get(\.name)
        func get<V>(_ key: KeyPath<Element, V>) -> [V]
    }
    """#

    /// Reads the prelude, binding its types, functions and sequence
    /// methods in the outermost scope with their Swift bodies.
    func installPrelude() {
        let program: Program
        do {
            program = try Parser.parsePrelude(Shell.prelude, bound: ["FileType": .type, "JobState": .type])
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
            case .function(let decl):
                guard let native = natives[decl.name] else { preconditionFailure("no body for \(decl.name)") }
                let function = builtinFunction(decl, native.body, input: nil)
                var candidates: [Function] = []
                if case .function(let set as OverloadSet)? = scopes[0].bindings[decl.name]?.value { candidates = set.candidates }
                // `with` is only called with a closure, so it isn't a command.
                scopes[0].bindings[decl.name] = Binding(
                    value: .function(OverloadSet(name: decl.name, candidates: candidates + [function])),
                    mutable: false, isFunction: decl.name != "with"
                )
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
