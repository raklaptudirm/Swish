import Foundation
import Swiit
import SwishLibrary

// How the shell shows values in a table: the vocabulary a type uses to say which of its fields a
// table starts with and what stands out in them. The core knows none of it (the styles themselves,
// `DisplayStyle`, are its).

/// How the shell's types show in a table, by the name of the type: the
/// columns of the structs that say so (`Tabular`), and how an enum's cases
/// are styled (`DisplayStyled`).
struct DisplayRegistry: Sendable {
    public var columns: [String: [DisplayColumn]]
    public var enumStyles: [String: @Sendable (String) -> DisplayStyle?]
    /// The columns of a type the registry does not know yet: one a program declared.
    public var declared: (@Sendable (String) -> [DisplayColumn]?)?

    public init(
        columns: [String: [DisplayColumn]] = [:],
        enumStyles: [String: @Sendable (String) -> DisplayStyle?] = [:]
    ) {
        self.columns = columns
        self.enumStyles = enumStyles
    }

    /// Adds a Swift type that says its columns, under the name its values show as.
    mutating func add<Type: Tabular>(_ type: Type.Type) {
        columns[String(describing: type)] = type.columns
    }

    /// Adds a Swift enum that says how its cases are styled, under the name its values show as.
    mutating func add<Type: DisplayStyled & CaseIterable>(_ type: Type.Type) {
        let styles = Dictionary(
            type.allCases.map { ("\($0)", $0.displayStyle) },
            uniquingKeysWith: { first, _ in first }
        )
        enumStyles[String(describing: type)] = { name in styles[name] ?? nil }
    }

    /// The columns a table of `typeName` starts with, if the type says.
    func columns(for typeName: String) -> [DisplayColumn]? {
        columns[typeName] ?? declared?(typeName)
    }
}
