import Foundation
import Swiit
import SystemPackage

/// What a table and a terminal need to know of a Swift type's values beyond their text: a type says
/// only what is true of it.
protocol Presentable {
    /// One cell of a table.
    var cell: String { get }
    /// What else the printers need to know of how it looks.
    var shape: DisplayShape { get }
    /// It in pieces to color, if it has colors to show: what is written to a terminal, where the
    /// text is for a pipe or file. Also how it prints in the debug form, if it has a form of its own
    /// (a job reads `[1] running make`); nil to print as its fields.
    var styledSegments: [Segment]? { get }
}

extension Sequence where Element == Segment {
    /// The text, with the terminal's escapes for each style if `styled`.
    func text(styled: Bool) -> String {
        map { $0.text.styled($0.style, styled) }.joined()
    }
}

/// A piece of text and the style it is shown in.
struct Segment: Sendable, Hashable {
    public let text: String
    public let style: DisplayStyle?

    public init(_ text: String, _ style: DisplayStyle? = nil) {
        self.text = text
        self.style = style
    }
}

extension Presentable {
    var cell: String { "\(self)" }
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
    var styledSegments: [Segment]? {
        runs.map { Segment(String(self[$0.range].characters), $0.swiit.displayStyle) }
    }
}
