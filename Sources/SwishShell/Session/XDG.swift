@_spi(Shell) import Swiit
import Foundation

/// Where files go, by the XDG Base Directory spec. A relative directory in
/// any of its variables is ignored, as the spec says.
enum XDG {
    /// `$XDG_CONFIG_HOME`, or `~/.config`.
    static func configHome(_ environment: [String: String]) -> String? {
        absolute(environment["XDG_CONFIG_HOME"]) ?? environment["HOME"].map { $0 + "/.config" }
    }

    /// `$XDG_CONFIG_DIRS`, or `/etc/xdg`: where to look after configHome.
    static func configDirectories(_ environment: [String: String]) -> [String] {
        let listed = (environment["XDG_CONFIG_DIRS"] ?? "").split(separator: ":").compactMap { absolute(String($0)) }
        return listed.isEmpty ? ["/etc/xdg"] : listed
    }

    /// `$XDG_STATE_HOME`, or `~/.local/state`.
    static func stateHome(_ environment: [String: String]) -> String? {
        absolute(environment["XDG_STATE_HOME"]) ?? environment["HOME"].map { $0 + "/.local/state" }
    }

    private static func absolute(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return path
    }
}
