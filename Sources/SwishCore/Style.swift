import Foundation

/// The shell's colors, shared by the input highlighter and everything it
/// prints, so a string or a type looks the same typed as shown. Color is
/// for what matters (errors, states, directories) and for telling parts
/// apart (headers, labels); the rest stays plain.
enum Style: String {
    case bold = "1"
    /// Secondary text: job numbers, `nil`s, cut-off markers.
    case dim = "90"
    case red = "31"
    case green = "32"
    case yellow = "33"
    case blue = "34"
    case magenta = "35"
    case cyan = "36"
    case brightMagenta = "95"
    case brightYellow = "93"
    case boldRed = "1;31"
    case boldBlue = "1;34"

    // What each kind of thing is shown in.
    static let keyword = Style.magenta
    static let string = Style.yellow
    static let constant = Style.brightMagenta // numbers, true, nil
    static let type = Style.brightYellow
    static let variable = Style.cyan
    static let flag = Style.blue
    static let comment = Style.dim
    static let label = Style.bold // table headers, record keys, help sections
    static let error = Style.boldRed

    var escape: String { "\u{1B}[\(rawValue)m" }
    static let reset = "\u{1B}[0m"

    /// Whether to style what's written to `fd`: only for a terminal, and
    /// not with `NO_COLOR` set or `TERM=dumb`.
    static func enabled(for fd: Int32) -> Bool {
        isatty(fd) != 0 && env("NO_COLOR").map(\.isEmpty) != false && env("TERM") != "dumb"
    }
}

extension String {
    /// `self` in `style`, if styling is on.
    func styled(_ style: Style?, _ enabled: Bool = true) -> String {
        guard enabled, let style, !isEmpty else { return self }
        return style.escape + self + Style.reset
    }
}
