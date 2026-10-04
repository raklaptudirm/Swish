import Foundation

/// How a type says it's shown, so the shell has no table of its types' names:
/// which columns a table starts with, and what stands out in them.

/// A style for text in a table: bold, dim, or a color. Its raw value is the
/// terminal's code for it.
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
}

/// A column a table shows, and what styles it: the value of another field
/// (or of itself), if that is a `DisplayStyled` enum. A file's name is
/// styled by its type: `DisplayColumn("name", styledBy: "type")`.
public struct DisplayColumn: Sendable, ExpressibleByStringLiteral {
    public let name: String
    public let styledBy: String?

    public init(_ name: String, styledBy: String? = nil) {
        self.name = name
        self.styledBy = styledBy
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
}

extension SwishDisplayed {
    public var swishCell: String { swishDescription }
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
