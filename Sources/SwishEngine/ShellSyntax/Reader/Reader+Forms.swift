import Foundation

// The forms the reader reads: the pieces of a command line, before they are written out as Swift.

extension Reader {
    /// A form that could not be read, and whether more input could finish it.
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

    /// How a command line is tried: plain, `try?` or `try!`.
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

    /// One word of a command: text made of pieces, or a closure.
    enum Word: Equatable {
        case text([Piece])
        /// A closure passed as an argument: Swift.
        case closure(String)
    }

    /// A redirect of one descriptor, to a file or to another descriptor.
    struct Redirect: Equatable {
        enum Target: Equatable {
            case file([Piece], Mode)
            case descriptor(Int)
        }
        enum Mode: Equatable { case read, write, append }
        var fd: Int
        var target: Target
    }

    /// One command of a pipeline: its words, redirects and environment.
    struct Command {
        var words: [Word]
        var external = false
        var redirects: [Redirect] = []
        var environment: [(name: String, value: [Piece])] = []
        var call: String?
    }

    /// Commands joined by `|`, with the source they were read from.
    struct Pipeline {
        var commands: [Command]
        var source: String
        var input: String?
        var throwing: Attempt?
    }

    /// One side of `&&` or `||`: a pipeline, or a Swift expression.
    enum Operand {
        case command(Pipeline)
        case expression(String)

        var isOptionalAttempt: Bool {
            if case .expression(let text) = self { text.hasPrefix("try?") } else { false }
        }
    }

    /// Operands joined by `&&` and `||`.
    struct Chain {
        var first: Operand
        var links: [(isAnd: Bool, operand: Operand)] = []
        var isCondition = false
        var operands: [Operand] { [first] + links.map(\.operand) }
    }

    /// What a statement starts as: an expression, or a command (and why it is not an expression).
    enum UnitStart {
        case expression
        case command(notAnExpression: String?)
        var isCommand: Bool { if case .command = self { true } else { false } }
    }
}
