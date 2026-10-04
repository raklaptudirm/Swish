import Foundation

/// How a type says it's shown, so the shell has no table of its types' names:
/// which columns a table starts with, and what stands out in them.

/// A style for text: bold, dim, or a color, and the roles the shell gives
/// them, so a string or a type looks the same typed, shown and in help. Its
/// raw value is the terminal's code for it.
public enum DisplayStyle: String, Sendable {
    case bold = "1"
    case dim = "90"
    case red = "31"
    case green = "32"
    case yellow = "33"
    case blue = "34"
    case magenta = "35"
    case cyan = "36"
    case boldRed = "1;31"
    case boldBlue = "1;34"
    case brightMagenta = "95"
    case brightYellow = "93"

    // What each kind of thing is shown in.
    public static let keyword = DisplayStyle.magenta
    public static let string = DisplayStyle.yellow
    public static let constant = DisplayStyle.brightMagenta // numbers, true, nil
    public static let type = DisplayStyle.brightYellow
    public static let variable = DisplayStyle.cyan // a variable, a parameter's name
    public static let path = DisplayStyle.green // a FilePath, unquoted, unlike a String
    public static let command = DisplayStyle.green // a name that runs
    public static let flag = DisplayStyle.blue
    public static let comment = DisplayStyle.dim // secondary text: job numbers, `nil`s, cut-off markers
    public static let label = DisplayStyle.bold // table headers, record keys, help sections
    public static let error = DisplayStyle.boldRed

    /// The terminal's escape for it, and what ends it.
    public var escape: String { "\u{1B}[\(rawValue)m" }
    public static let reset = "\u{1B}[0m"
}

/// A column a table shows, and what styles it: the value of another field
/// (or of itself), if that is a `DisplayStyled` enum, as a file's name is
/// styled by its type: `DisplayColumn("name", styledBy: "type")`; or one
/// style for all of it: `DisplayColumn("name", style: .green)`.
public struct DisplayColumn: Sendable, ExpressibleByStringLiteral {
    public let name: String
    public let styledBy: String?
    public let style: DisplayStyle?

    public init(_ name: String, styledBy: String? = nil, style: DisplayStyle? = nil) {
        self.name = name
        self.styledBy = styledBy
        self.style = style
    }

    public init(stringLiteral name: String) {
        self.init(name)
    }
}

/// A struct that says which of its fields a table shows by default, in
/// order. The rest are still there for `filter`, `select` and `get`, and
/// `table` shows every one.
public protocol Tabular {
    static var columns: [DisplayColumn] { get }
}

/// An enum whose cases stand out, by being shown in a style.
public protocol DisplayStyled {
    var displayStyle: DisplayStyle? { get }
}

/// A Swift type that shows in Swish other than as its `description`: a date
/// in local time, to the second, and to the minute in a table.
public protocol SwishDisplayed {
    var swishDescription: String { get }
    var swishCell: String { get }
    var swishDebugDescription: String { get }
    /// It with terminal color escapes, if it has colors to show: what's
    /// written to a terminal, where `swishDescription` is for a pipe or file.
    var swishColored: String? { get }
}

extension SwishDisplayed {
    public var swishCell: String { swishDescription }
    public var swishDebugDescription: String { swishDescription }
    public var swishColored: String? { nil }
}

extension Date: SwishDisplayed {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public var swishDescription: String { Date.formatter.string(from: self) }
    /// `2026-09-27 14:03`.
    public var swishCell: String { String(swishDescription.prefix(16)) }
}
