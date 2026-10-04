import Foundation

/// A line of text in pieces, each in a style or plain: `help` is written in
/// it. On a terminal it shows in color, and anywhere else (a pipe, a file,
/// `.text`) it's the plain text.
public struct StyledText: Sendable, Hashable, StandsForText {
    public struct Segment: Sendable, Hashable {
        public var text: String
        public var style: DisplayStyle?

        public init(_ text: String, _ style: DisplayStyle? = nil) {
            self.text = text
            self.style = style
        }
    }

    public var segments: [Segment]

    public init(_ segments: [Segment] = []) {
        self.segments = segments
    }

    /// Without styles.
    public init(plain text: String) {
        self.init([Segment(text)])
    }

    public var text: String {
        segments.map(\.text).joined()
    }

    /// With the terminal's escapes for each style.
    public var colored: String {
        segments.map { segment in
            guard let style = segment.style, !segment.text.isEmpty else { return segment.text }
            return style.escape + segment.text + DisplayStyle.reset
        }.joined()
    }
}

extension StyledText: CustomStringConvertible, SwishDisplayed {
    public var description: String { text }
    public var swishDescription: String { text }
    public var swishColored: String? { colored }
}

extension Value {
    /// A line of styled text, held as the Swift value it is.
    public static func styledText(_ line: StyledText) -> Value {
        SwiftValue.make(line, as: "StyledText")
    }
}
