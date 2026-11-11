import Foundation
import Swiit
import SystemPackage

/// What a table and a terminal need to know of a Swift type's values beyond their text: a type says
/// only what is true of it.
protocol Presentable {
    /// One cell of a table.
    var cell: String { get }
    /// It with terminal color escapes, if it has colors to show: what is written to a terminal,
    /// where the text is for a pipe or file.
    var styledText: String? { get }
    /// What else the printers need to know of how it looks.
    var shape: DisplayShape { get }
    /// How it prints in the debug form, in pieces to color, if it has a form of its own (a job reads
    /// `[1] running make`); nil to print as its fields.
    var styledSegments: [Segment]? { get }
}

/// A piece of text and the style it is shown in.
typealias Segment = (text: String, style: DisplayStyle?)

extension Presentable {
    var cell: String { "\(self)" }
    var styledText: String? { nil }
    var shape: DisplayShape { DisplayShape() }
    var styledSegments: [Segment]? { nil }
}

/// The facts about how a value looks that the printers need beyond its text.
struct DisplayShape: Sendable {
    /// The style of its text in a debug form, when it's one thing: a number, a path.
    var role: DisplayStyle?
    /// It's a number, so a column of them lines up on the right.
    var isNumeric = false
    /// It has nothing to show: a command that printed nothing.
    var isEmpty = false
}

extension Date: Presentable {
    /// `2026-09-27 14:03`.
    var cell: String { String(shown.prefix(16)) }
}

extension FilePath: Presentable {
    var cell: String { string }
    var shape: DisplayShape { DisplayShape(role: .path) }
}

extension FilePath.Component: Presentable {
    var cell: String { string }
    var shape: DisplayShape { DisplayShape(role: .path) }
}

extension AttributedString: Presentable {
    var cell: String { plain }
    var styledText: String? { rendered(true) }
}
