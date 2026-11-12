import Foundation
import SystemPackage

/// The working directory.
public func pwd() -> FilePath {
    FilePath(FileManager.default.currentDirectoryPath)
}

/// Runs a closure with environment variables set, then puts them back.
/// - Parameter variables: the variables to set, as in with(env: ["EDITOR": "vim"]) { git commit }
/// - Parameter body: what to run with them set
public func with<T>(env variables: [String: String], _ body: () throws -> T) rethrows -> T {
    let saved = variables.keys.map { ($0, getenv($0).map { String(cString: $0) }) }
    for (name, value) in variables { setenv(name, value, 1) }
    defer {
        for (name, value) in saved {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
    }
    return try body()
}
