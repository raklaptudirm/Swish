import Foundation
import SwishEngine

/// The config file: a Swish script the interactive shell runs as it starts, whose functions and
/// variables stay defined at the prompt. A `prompt` function there draws the prompt.
enum Configuration {
    /// `$SWISH_CONFIG` (empty for none), or the first `swish/config.swish` in the XDG config
    /// directories: `$XDG_CONFIG_HOME` (or `~/.config`), then each of `$XDG_CONFIG_DIRS` (or
    /// `/etc/xdg`).
    static func path(
        environment: [String: String],
        exists: (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) -> String? {
        if let path = environment["SWISH_CONFIG"] { return path.isEmpty ? nil : path }
        let directories =
            [XDG.configHome(environment)].compactMap { $0 } + XDG.configDirectories(environment)
        return directories.map { $0 + "/swish/config.swish" }.first(where: exists)
    }
}

extension InteractivePrompt {
    /// Runs the config file, if there is one. Its errors are reported, and the shell starts anyway.
    func loadConfiguration() {
        guard let path = Configuration.path(environment: ProcessInfo.processInfo.environment) else {
            return
        }
        // Loading the config isn't a command.
        shell.keepingStatus { _ = shell.source(fileAt: path) }
    }
}
