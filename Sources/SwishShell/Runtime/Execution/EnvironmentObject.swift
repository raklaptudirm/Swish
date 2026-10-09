import Foundation
@_spi(Shell) import Swiit
import SwishKit

/// The process's variables, for `env`.
struct EnvironmentAccess {
    var get: (String) -> String?
    /// Every variable, by name.
    var all: () -> [(name: String, value: String)]
    /// Sets a variable, or removes it when the value is nil.
    var set: (String, String?) -> Void

    init(get: @escaping (String) -> String?, all: @escaping () -> [(name: String, value: String)], set: @escaping (String, String?) -> Void) {
        self.get = get
        self.all = all
        self.set = set
    }
}

extension EnvironmentAccess {
    /// The process's own variables.
    nonisolated(unsafe) static let process = EnvironmentAccess(
        get: { env($0) },
        all: { ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key }).map { (name: $0.key, value: $0.value) } },
        set: { name, value in
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        })
}

/// `env`: the variables of the programs the shell runs. `env.HOME` is a
/// `String?`, nil when unset; `env.PAGER = "less"` sets one and `= nil` removes
/// it. It is a dynamic object, so the core knows nothing of it.
final class EnvironmentObject: DynamicObject, @unchecked Sendable {
    let access: EnvironmentAccess

    init(access: EnvironmentAccess) {
        self.access = access
    }

    var typeName: String { "Environment" }
    var readType: TypeAnnotation { .optional(.string) }
    // Anything with a text form is a value: `env.PORT = 8080`.
    var writeType: TypeAnnotation { .optional(.any) }
    var memberNames: [String] { access.all().map(\.name) }
    var description: String { "Environment" }

    func member(_ name: String) -> Value? { access.get(name).map(Value.string) }

    var fields: Record? {
        var record = Record(typeName: "Environment")
        for (name, value) in access.all() { record[name] = .string(value) }
        return record
    }

    func read(_ name: String) throws -> Value {
        access.get(name).map(Value.string) ?? .nothing
    }

    func write(_ name: String, _ value: Value) throws {
        guard !name.isEmpty, !name.contains("=") else {
            throw RuntimeError("an environment variable's name must be a String without '=', not \(name)")
        }
        access.set(name, value == .nothing ? nil : value.description)
    }
}
