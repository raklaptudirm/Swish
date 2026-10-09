@_spi(Shell) import Swiit
import SwishKit

extension Library {
    /// The shell's own: `ls`, `ps`, `pwd`, `with(env:)`, `readLine`, `history`,
    /// `from`, `to`, `table`, `list` and the types they use (SwishShellLibrary),
    /// with the prelude declarations that are the shell's: `Status`,
    /// `CommandFailure`, `help`, `members`, `select` and `JSON`.
    static func shell(for shell: Shell) -> Library {
        Library(
            types: Bridge.shellTypes, columns: Bridge.shellColumns,
            enumStyles: Bridge.shellEnumStyles, functions: Bridge.shellFunctions,
            declarations: shellDeclarations,
            bodies: [
                "help": (shell.help().body, nil),
                "members": (shell.interpreter.members().body, nil),
                "Sequence.select": selectBody,
            ]
        )
    }

    /// Swish source read after the core's prelude. The checker works from the
    /// signatures; the bodies are in Swift, found by name (`bodies`).
    private static let shellDeclarations = #"""
    /// How a command exited: `output.status`.
    struct Status: Equatable, Hashable, Encodable {
        let code: Int?
        let signal: Int?
        let succeeded: Bool
    }

    /// What `try $(…)` throws when the command fails, and `try await job`:
    /// `catch let` it with a cast, `if let failure = error as? CommandFailure`.
    struct CommandFailure {
        let message: String
        let status: Status
        let text: String
        let localizedDescription: String
    }

    /// A member `members` describes.
    struct Member: Equatable, Hashable, Encodable {
        let type: String
        let name: String
        let kind: String
    }

    /// Describes the input: each type's fields and members.
    func members(@input _ items: [Any]) -> [Member]

    /// A function `help` lists.
    struct Help: Equatable, Hashable, Encodable {
        let name: String
        let source: String
        let summary: String
        let usage: String
        let description: String
    }

    /// Parsed JSON: read by field (json.name, json["name"]) or element
    /// (json[0]), each giving JSON?, and as a type with .string, .int,
    /// .double, .bool, .array, .object and .isNull.
    struct JSON {}

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

    /// `xs | select name size`: a sequence method that reads each item.
    private static var selectBody: (body: FunctionBody, input: Parameter?) {
        let method = Function.builtin(
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
        let input = method.parameters.first(where: \.isInput)!
        // Each item is an Element; all of them, a list of Elements.
        let type: TypeAnnotation = input.type.isList ? .list(.parameter("Element")) : .parameter("Element")
        return (method.body, Parameter(label: nil, name: input.name, type: type, isInput: true))
    }
}
