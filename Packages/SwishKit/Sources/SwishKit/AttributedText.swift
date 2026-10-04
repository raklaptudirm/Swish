import Foundation

// Text with styles is Foundation's `AttributedString`: what Swift uses for
// it, so `help`, and anything else that shows text with emphasis, hands
// Swish a standard type. Foundation alone has no colors (they're in AppKit,
// UIKit and SwiftUI), so the shell's own are one attribute: a style by what
// the text is, which the terminal turns into a color when it's shown.

/// The style a run of text is in: `DisplayStyle`'s roles (a keyword, a type,
/// a flag…), not a color, so what a color is, or whether there is one, is
/// decided when it's shown.
public enum DisplayStyleAttribute: AttributedStringKey {
    public typealias Value = DisplayStyle
    public static let name = "swish.displayStyle"
}

extension AttributeScopes {
    public struct SwishAttributes: AttributeScope {
        public let displayStyle: DisplayStyleAttribute
        /// What Foundation has (emphasis, code, links, structure), so text
        /// parsed from Markdown keeps it.
        public let foundation: FoundationAttributes
    }

    public var swish: SwishAttributes.Type { SwishAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(dynamicMember keyPath: KeyPath<AttributeScopes.SwishAttributes, T>) -> T {
        self[T.self]
    }
}

extension AttributedString {
    /// Text in a style, or plain if there's none.
    public init(_ text: String, _ style: DisplayStyle?) {
        self.init(text)
        if let style { self.swish.displayStyle = style }
    }

    /// Pieces one after the other.
    public init(joining pieces: [AttributedString]) {
        self.init()
        for piece in pieces { append(piece) }
    }

    /// Without the styles.
    public var plain: String {
        String(characters)
    }

    /// Text written in Markdown, as documentation is: its emphasis, code and
    /// links kept as the attributes Foundation gives them, which show as styles
    /// where there are colors. Text that isn't valid Markdown is just text.
    public init(documentation text: String) {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        self = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// The style of a run: the one it's given, or what its Markdown says
    /// (code, strong, emphasis, a link).
    private static func style(of run: AttributedString.Runs.Run) -> DisplayStyle? {
        if let style = run.swish.displayStyle { return style }
        if let intent = run.inlinePresentationIntent {
            if intent.contains(.code) { return .variable }
            if intent.contains(.stronglyEmphasized) { return .bold }
            if intent.contains(.emphasized) { return .italic }
        }
        return run.link == nil ? nil : .underline
    }

    /// With the terminal's escapes for each style.
    public var colored: String {
        var result = ""
        for run in runs {
            let text = String(self[run.range].characters)
            if let style = AttributedString.style(of: run), !text.isEmpty {
                result += style.escape + text + DisplayStyle.reset
            } else {
                result += text
            }
        }
        return result
    }

    /// As a String: with the terminal's escapes if `styled`.
    public func rendered(_ styled: Bool) -> String {
        styled ? colored : plain
    }
}

extension AttributedString: StandsForText, SwishDisplayed {
    public var text: String { plain }
    public var swishDescription: String { plain }
    public var swishColored: String? { colored }
}

extension Value {
    /// Text with styles, held as the Swift value it is.
    public static func attributed(_ text: AttributedString) -> Value {
        SwiftValue.make(text, as: "AttributedString")
    }
}
