import SwishCore
import Foundation
import SwishKit

struct PipelineNode: Equatable, Sendable {
    var commands: [CommandNode]
    /// The pipeline as typed, for job messages like "Stopped".
    var source: String
    /// A value feeding the pipeline, as in `[3, 1, 2] | sort`.
    var input: Expr?
    /// `try make` (`.some(nil)`) or `try! make`: failing throws, rather than
    /// only setting the status.
    var throwing: TryKind?? = nil
}

struct CommandNode: Equatable, Sendable {
    var words: [Word]
    /// `^name`: skip functions and builtins, and run the external program.
    var external = false
    /// In the order written, which matters: `> out e>o` sends both to
    /// `out`, `e>o > out` only standard output.
    var redirects: [Redirect] = []
    /// `EDITOR=vim git commit`: environment variables for this command only.
    var environment: [EnvironmentAssignment] = []
    /// `sorted(by: "size")` after a `|`: arguments written as a call.
    var call: [Argument]? = nil
    /// What the checker found the name to be, from the type of what's piped
    /// in; nil when it couldn't tell, and the interpreter looks.
    var resolution: StageResolution? = nil
    /// For a stage written as a call, the overload the checker chose.
    var overload: Int? = nil
    /// Why it isn't an expression, when that's what made it a command
    /// (`7zip`, but also a mistyped `1...2...3`): shown instead of "command
    /// not found" if no program has the name.
    var notAnExpression: String? = nil
}

/// What a pipeline stage's name is, given what flows into it.
enum StageResolution: Equatable, Sendable {
    /// A method of the sequence: `ls | sorted`.
    case sequenceMethod
    /// A method of each item: `points | describe`.
    case itemMethod
    /// A Swift member of a bridged type, called on `receiver`. `bindings`:
    /// what its generic parameters are here, so a word on the command line
    /// converts to them (`xs | contains 2`, 2 an Int).
    case bridged(type: String, receiver: StageReceiver, bindings: [String: TypeAnnotation])
    /// Neither: a function or a program, looked up as for the first command.
    case other
}

/// What a Swift member as a stage is called on.
enum StageReceiver: Equatable, Sendable {
    /// The items collected, as an Array: `xs | max`.
    case collected
    /// Each item, its results flowing on: `names | uppercased`.
    case each
    /// The items as they come, a `Flow`, for what can work on them one at a
    /// time: `yes | map { … } | prefix 3` ends.
    case flow
    /// The one value a pipeline starts from, when it isn't a sequence:
    /// `"a b" | split(separator: " ")`. A list it gives flows as its items.
    case value
}

struct EnvironmentAssignment: Equatable, Sendable {
    var name: String
    var value: [WordPart]
}

/// `> file`, `e>> file`, `< file`, `e>o` and the like.
struct Redirect: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case file([WordPart], Mode)
        /// Another of the command's descriptors, as in `e>o`.
        case descriptor(Int32)
    }

    enum Mode: Equatable, Sendable {
        case read, write, append
    }

    var fd: Int32
    var target: Target
}

enum Word: Equatable, Sendable {
    case text([WordPart])
    /// `where { $0.size > 1.mb }`: a closure passed as an argument.
    case closure(ClosureLiteral)
}

/// A piece of a command word: a string's parts, and the two a word has that a
/// string doesn't.
enum WordPart: Equatable, Sendable {
    case literal(String)
    case expression(Expr)
    /// An unquoted `$xs` or `\(xs)` in a command word. A list there, alone
    /// in its word, is one argument per item; quoted, it's one argument.
    case spread(Expr)
    /// Unquoted text with a wildcard, like `*.swift`; only unquoted
    /// wildcards expand to file names.
    case glob(String)

    init(_ part: StringPart) {
        switch part {
        case .literal(let text): self = .literal(text)
        case .expression(let expr): self = .expression(expr)
        }
    }
}
