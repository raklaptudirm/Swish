import Foundation
import SwishKit

/// The config file: a Swish script the interactive shell runs as it
/// starts, whose functions and variables stay defined at the prompt. A
/// `prompt` function there draws the prompt.
extension Shell {
    /// `$SWISH_CONFIG` (empty for none), or the first `swish/config.swish`
    /// in the XDG config directories: `$XDG_CONFIG_HOME` (or `~/.config`),
    /// then each of `$XDG_CONFIG_DIRS` (or `/etc/xdg`).
    static func configPath(environment: [String: String], exists: (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }) -> String? {
        if let path = environment["SWISH_CONFIG"] { return path.isEmpty ? nil : path }
        let directories = [XDG.configHome(environment)].compactMap { $0 } + XDG.configDirectories(environment)
        return directories.map { $0 + "/swish/config.swish" }.first(where: exists)
    }

    /// Runs the config file, if there is one. Its errors are reported, and
    /// the shell starts anyway.
    func loadConfig() {
        guard let path = Shell.configPath(environment: ProcessInfo.processInfo.environment) else { return }
        _ = sourceFile(path, arguments: [])
        lastStatus = 0
    }

    /// What the `prompt` function gives, or nil if there isn't one. It's
    /// `prompt() -> String`, or `prompt(status: Int) -> String` to be told
    /// how the last command exited.
    func customPrompt() throws -> String? {
        guard let binding = interpreter.scopes[1].bindings["prompt"], binding.isFunction,
              case .function(let set as OverloadSet) = binding.value else { return nil }
        let withStatus = set.candidates.first { $0.parameters.map(\.label) == ["status"] && $0.parameters[0].type == .int }
        guard let function = withStatus ?? set.candidates.first(where: { $0.parameters.isEmpty }),
              function.returnType == .string else {
            throw RuntimeError("declare it as `func prompt() -> String` or `func prompt(status: Int) -> String`")
        }
        let status = lastStatus
        defer { lastStatus = status } // Drawing the prompt isn't a command.
        let value = try interpreter.invoke(function, with: withStatus != nil ? ["status": .int(Int(status))] : [:])
        guard case .string(let text) = value else { throw RuntimeError("it gave \(value.typeName), not a String") }
        return text
    }
}
