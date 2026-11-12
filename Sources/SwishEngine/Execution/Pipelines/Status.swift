import Foundation
import Swiit

/// How a command ended: it exited with a code, or a signal ended it. It is what `$?` reads, what a
/// command statement gives (the prelude's `Status`), and an `Output`'s.
public enum Status: Hashable, Sendable {
    case exited(Int32)
    case signaled(Int32)

    public static let success = Status.exited(0)

    /// How a child ended, from `waitpid`'s status; one that neither exited nor was signaled (which
    /// `waitpid` without `WUNTRACED` doesn't give) failed.
    init(_ wait: WaitStatus) {
        if wait.exited {
            self = .exited(wait.exitCode)
        } else if wait.signaled {
            self = .signaled(wait.signal)
        } else {
            self = .exited(1)
        }
    }

    public var succeeded: Bool { self == .success }

    /// The status as a process gives it, and as the shell exits with: the code, or 128 and the
    /// signal.
    public var number: Int32 {
        switch self {
        case .exited(let code): code
        case .signaled(let signal): 128 + signal
        }
    }

    /// The exit code, or nil when a signal ended the command.
    public var code: Int? {
        if case .exited(let code) = self { Int(code) } else { nil }
    }

    /// The signal that ended the command, if one did.
    public var signal: Int? {
        if case .signaled(let signal) = self { Int(signal) } else { nil }
    }
}

/// Encoded as the fields of the prelude's `Status`, by its name: a member of `Output` makes one
/// this way, as host types are process-wide and can't make a type an interpreter declares. Every
/// field is there, and `nil` is a field.
extension Status: Encodable {
    public func encode(to encoder: any Encoder) throws {
        try StatusFields(self).encode(to: encoder)
    }
}

/// A status crosses as the fields of the prelude's `Status`, by its name.
extension Status: ScriptConvertible {
    static let id = Symbol.ID(hostType: "Status")
    public static var scriptType: ScriptType { .named(id) }

    /// A script's status is read as its fields; nothing takes one as a parameter.
    public init(_ value: Value) throws {
        throw LibraryError("expected a Status, not \(value)")
    }

    public var value: Value { (try? Value(encoding: StatusFields(self), as: Status.id)) ?? .nothing }
}

/// A status as its fields, which encode as the struct they are. (A status that encodes itself
/// would be converted by `value`, which encodes it.)
private struct StatusFields: Encodable {
    let code: Int?
    let signal: Int?
    let succeeded: Bool

    init(_ status: Status) {
        (code, signal, succeeded) = (status.code, status.signal, status.succeeded)
    }

    private enum CodingKeys: String, CodingKey { case code, signal, succeeded }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(code, forKey: .code)
        try container.encode(signal, forKey: .signal)
        try container.encode(succeeded, forKey: .succeeded)
    }
}
