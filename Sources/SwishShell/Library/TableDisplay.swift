import Foundation
@_spi(Layer) import Swiit

// How the shell shows values in a table: the vocabulary a type uses to say which of its fields a table starts with
// and what stands out in them. The core knows none of it (the styles themselves, `DisplayStyle`, are its).

/// A column a table shows, and what styles it: the value of another field
/// (or of itself), if that is a `DisplayStyled` enum, as a file's name is
/// styled by its type: `DisplayColumn("name", styledBy: "type")`; or one
/// style for all of it: `DisplayColumn("name", style: .green)`.
@_spi(Layer) public struct DisplayColumn: Sendable, ExpressibleByStringLiteral {
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

/// How the shell's types show in a table, by the name of the type: the
/// columns of the structs that say so (`Tabular`), and how an enum's cases
/// are styled (`DisplayStyled`). A function that lays values out is lent it
/// in the `HostContext`.
@_spi(Layer) public struct DisplayRegistry: Sendable {
    public var columns: [String: [DisplayColumn]]
    public var enumStyles: [String: @Sendable (String) -> DisplayStyle?]

    public init(columns: [String: [DisplayColumn]] = [:], enumStyles: [String: @Sendable (String) -> DisplayStyle?] = [:]) {
        self.columns = columns
        self.enumStyles = enumStyles
    }
}

/// A struct that says which of its fields a table shows by default, in
/// order. The rest are still there for `filter`, `select` and `get`, and
/// `table` shows every one.
@_spi(Layer) public protocol Tabular {
    static var columns: [DisplayColumn] { get }
}

/// An enum whose cases stand out, by being shown in a style.
@_spi(Layer) public protocol DisplayStyled {
    var displayStyle: DisplayStyle? { get }
}


extension HostContext {
    /// How types show in a table, which the shell lends the functions that lay values out (`table`, `list`, `to`).
    @_spi(Layer) public var display: DisplayRegistry {
        get { extras["display"] as? DisplayRegistry ?? DisplayRegistry() }
        set { extras["display"] = newValue }
    }
}
