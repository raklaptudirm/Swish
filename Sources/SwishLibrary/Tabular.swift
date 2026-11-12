import Foundation
import Swiit

// How a table shows a type's values: the vocabulary a type uses to say which of its fields a table
// starts with and what stands out in them. The core knows none of it (the styles themselves,
// `DisplayStyle`, are its).

/// A column a table shows, and what styles it: the value of another field (or of itself), if that
/// is a `DisplayStyled` enum, as a file's name is styled by its type:
/// `DisplayColumn("name", styledBy: "type")`; or one style for all of it:
/// `DisplayColumn("name", style: .green)`.
public struct DisplayColumn: ScriptConvertible, Sendable, ExpressibleByStringLiteral {
    /// What styles a column's cells.
    public enum Styling: Sendable, Hashable {
        /// They are shown plain.
        case none
        /// By the `DisplayStyled` enum that another field of the same item holds.
        case byField(String)
        /// All in one style.
        case fixed(DisplayStyle)
    }

    public let name: String
    public let styling: Styling

    public init(_ name: String, styling: Styling = .none) {
        self.name = name
        self.styling = styling
    }

    /// A column styled by the value of the field `field`.
    public init(_ name: String, styledBy field: String) {
        self.init(name, styling: .byField(field))
    }

    /// A column all in one style.
    public init(_ name: String, style: DisplayStyle) {
        self.init(name, styling: .fixed(style))
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
