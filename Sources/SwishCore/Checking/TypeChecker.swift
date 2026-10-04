import Foundation
import SwishKit

/// A mistake in types, found before anything runs: the statement (or, in a
/// script, the whole script) doesn't run. See Docs/Design/types.md.
struct TypeError: Error, CustomStringConvertible {
    let message: String
    /// The line of the statement it's in, when there's more than one.
    var line: Int?
    /// A call's arguments don't line up with a signature's parameters, as
    /// opposed to lining up with a value of the wrong type.
    var isArity = false

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

/// Works out the type of every expression and checks it fits where it's
/// used, as Swift does: local, two-way inference, with every function's
/// signature written. Names already bound in the shell (from earlier
/// entries at the prompt, and the builtins) come from the shell; those the
/// program declares come from the program.
///
/// It also decides what the interpreter would otherwise decide as it runs,
/// and writes that into the program it returns: which overload a call
/// uses (`.chosen`). Commands, pipelines and builtins' results are
/// `unknown` until phase 3, which fits anywhere.
final class TypeChecker {
    struct Signature {
        var name: String
        var parameters: [Parameter]
        var returns: TypeAnnotation
        var isMutating = false
        var isThrowing = false
        /// `rethrows`: a call throws if a closure passed to it does.
        var isRethrowing = false
        /// Its position among the overloads the interpreter will have.
        var index = 0
        /// Its type parameters and the protocols each must conform to:
        /// `sorted<V: Comparable>(by:)`, and a sequence method's `Element`.
        var generics: [String: [String]] = [:]
    }

    struct StructInfo {
        var name: String
        var stored: [PropertyDecl]
        var computed: [String: TypeAnnotation]
        var methods: [String: [Signature]]
        var initializers: [Signature]
        var memberwise: Signature
        var conformances: [String] = []
        /// `static let` and `static var`, stored and computed: read on the type.
        var staticProperties: [PropertyDecl] = []
        var staticMethods: [String: [Signature]] = [:]

        func property(_ name: String) -> PropertyDecl? { stored.first { $0.name == name } }
        func staticProperty(_ name: String) -> PropertyDecl? { staticProperties.first { $0.name == name } }
    }

    struct EnumInfo {
        var name: String
        /// Each case's associated values, in declaration order.
        var cases: [(name: String, payload: [AssociatedValue])]
        var rawType: TypeAnnotation?
        var conformances: [String] = []

        func payload(of name: String) -> [AssociatedValue]? { cases.first { $0.name == name }?.payload }
    }

    enum Symbol {
        case variable(TypeAnnotation, mutable: Bool)
        case functions([Signature])
        case structType(StructInfo)
        case enumType(EnumInfo)
        /// An imported module, `Tools`; its members aren't known until it loads.
        case module
        /// `env`: the environment.
        case environment
        /// A Swift type by name, bridged: `String`, `Int`.
        case swiftType(String)
    }

    /// Where `return` goes: the declared result, or, for a closure that
    /// didn't say, the types its `return`s give.
    final class ReturnContext {
        let declared: TypeAnnotation?
        var seen: [TypeAnnotation] = []

        init(declared: TypeAnnotation?) {
            self.declared = declared
        }
    }

    /// Whether an error thrown here is handled: in a `throws` function, a
    /// closure, a `do` with a `catch`, or at the top level.
    struct ErrorContext {
        var handled: Bool
        /// What an error would have to leave, for messages.
        var boundary: Boundary = .topLevel

        enum Boundary {
            case topLevel, function(String), deferBlock

            /// Why an error can't get out, and what would let it.
            var unhandled: String {
                switch self {
                case .topLevel: "nothing catches it: use do/catch, try? or try!"
                case .function(let name): "\(name) isn't 'throws': mark it 'throws', or use do/catch, try? or try!"
                case .deferBlock: "nothing thrown can leave a defer: use do/catch, try? or try!"
                }
            }
        }
    }

    unowned let shell: Shell
    /// The type whose member was last looked up, so a JSON field can be
    /// written into a lookup that runs.
    var lastMemberBase: TypeAnnotation?

    /// Parsed JSON: any of its values, read by field (`json.name`,
    /// `json["name"]`) or position (`json[0]`), each giving `JSON?`.
    static let json = TypeAnnotation.named("JSON")

    /// What a JSON value is, when it's that: `json.port?.int`.
    static let jsonAccessors: [String: TypeAnnotation] = [
        "string": .optional(.string), "int": .optional(.int), "double": .optional(.double), "bool": .optional(.bool),
        "array": .optional(.list(json)), "object": .optional(.dictionary(.string, json)), "isNull": .bool,
    ]

    /// `json.name` as it runs: a lookup that gives nil for a missing field,
    /// or the value as one of the accessors' types.
    static func jsonAccess(_ base: Expr, _ name: String) -> Expr {
        let function = jsonAccessors[name] != nil ? "$jsonAs" : "$json"
        return .call(.variable(function), [Argument(label: nil, value: base), Argument(label: nil, value: .literal(.string(name)))])
    }
    /// What the program declares, innermost last, on top of the shell's names.
    var scopes: [[String: Symbol]] = [[:]]
    var returns: [ReturnContext] = []
    var errorContexts = [ErrorContext(handled: true)]
    /// Above zero while checking what a `try` covers.
    var tryDepth = 0
    /// Places that can throw, so far: how a `try` or a closure knows it
    /// covers one.
    var throwingSites = 0
    /// After an `import`, names it may bring can't be checked.
    var afterImport = false
    var line: Int?

    init(shell: Shell) {
        self.shell = shell
    }

    /// Checks a program, returning it with what was decided written in.
    func check(_ program: Program) throws(TypeError) -> Program {
        var checked = program
        do {
            try checkBlock(&checked)
        } catch var error as TypeError {
            error.line = error.line ?? line
            throw error
        } catch {
            preconditionFailure("the checker only throws TypeError")
        }
        return checked
    }

    /// The types of the globals a checked program declared, for the next
    /// entry at the prompt.
    var declaredGlobals: [String: TypeAnnotation] {
        scopes[0].compactMapValues { if case .variable(let type, _) = $0 { type } else { nil } }
    }

}
