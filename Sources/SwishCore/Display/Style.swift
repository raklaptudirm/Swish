import Foundation
import SwishKit

/// When and how the shell styles what it prints; the styles themselves are
/// SwishKit's `DisplayStyle`, shared by the input highlighter, tables and
/// help, so a string or a type looks the same typed and shown.
extension DisplayStyle {
    /// Whether to style what's written to `fd`: only for a terminal, and
    /// not with `NO_COLOR` set or `TERM=dumb`.
    static func enabled(for fd: Int32) -> Bool {
        isatty(fd) != 0 && env("NO_COLOR").map(\.isEmpty) != false && env("TERM") != "dumb"
    }
}

extension String {
    /// `self` in `style`, if styling is on.
    func styled(_ style: DisplayStyle?, _ enabled: Bool = true) -> String {
        guard enabled, let style, !isEmpty else { return self }
        return style.escape + self + DisplayStyle.reset
    }
}
