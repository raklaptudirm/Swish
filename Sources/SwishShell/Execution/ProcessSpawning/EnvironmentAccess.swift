import Foundation
import Swiit

/// The process's variables, for `env`.
struct EnvironmentAccess {
    var get: (String) -> String?
    /// Every variable, by name.
    var all: () -> [(name: String, value: String)]
    /// Sets a variable, or removes it when the value is nil.
    var set: (String, String?) -> Void

    init(
        get: @escaping (String) -> String?,
        all: @escaping () -> [(name: String, value: String)],
        set: @escaping (String, String?) -> Void
    ) {
        self.get = get
        self.all = all
        self.set = set
    }
}

extension EnvironmentAccess {
    /// The process's own variables.
    nonisolated(unsafe) static let process = EnvironmentAccess(
        get: { env($0) },
        all: {
            ProcessInfo.processInfo.environment.sorted(by: { $0.key < $1.key })
                .map { (name: $0.key, value: $0.value) }
        },
        set: { name, value in
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    )
}

/// A variable of this process's environment, or nil.
func env(_ name: String) -> String? {
    getenv(name).map { String(cString: $0) }
}
