import Foundation

// The forms the reader reads: the pieces of a command line, before they are written out as Swift.

extension Reader {
    struct Failure: Error, CustomStringConvertible {
        var message: String
        var incomplete: Bool
        init(_ message: String, incomplete: Bool = false) {
            self.message = message
            self.incomplete = incomplete
        }
        static func incomplete(_ message: String) -> Failure { Failure(message, incomplete: true) }
        var description: String { message }
    }

    enum Attempt: Equatable {
        case plain, optional, forced

        var keyword: String {
            switch self {
            case .plain: "try"
            case .optional: "try?"
            case .forced: "try!"
            }
        }
    }

    /// A piece of a command's word.
    enum Piece: Equatable {
        case literal(String)
        /// Unquoted text with a wildcard in it.
        case glob(String)
        /// Swift, an expression's value in the text.
        case expression(String)
        /// An unquoted `$xs` or `\(xs)`: a list in a word of its own is a word per item.
        case spread(String)
    }

    enum Word: Equatable {
        case text([Piece])
        /// A closure passed as an argument: Swift.
        case closure(String)
    }

    struct Redirect: Equatable {
        enum Target: Equatable {
            case file([Piece], Mode)
            case descriptor(Int)
        }
        enum Mode: Equatable { case read, write, append }
        var fd: Int
        var target: Target
    }

    struct Command {
        var words: [Word]
        var external = false
        var redirects: [Redirect] = []
        var environment: [(name: String, value: [Piece])] = []
        var call: String?
    }

    struct Pipeline {
        var commands: [Command]
        var source: String
        var input: String?
        var throwing: Attempt?
    }

    enum Operand {
        case command(Pipeline)
        case expression(String)

        var isOptionalAttempt: Bool {
            if case .expression(let text) = self { text.hasPrefix("try?") } else { false }
        }
    }

    struct Chain {
        var first: Operand
        var links: [(isAnd: Bool, operand: Operand)] = []
        var isCondition = false
        var operands: [Operand] { [first] + links.map(\.operand) }
    }

    enum UnitStart {
        case expression
        case command(notAnExpression: String?)
        var isCommand: Bool { if case .command = self { true } else { false } }
    }
}
