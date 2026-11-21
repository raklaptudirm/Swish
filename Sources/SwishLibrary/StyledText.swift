import Foundation

// Text with styles is Foundation's `AttributedString`, which is what Swift uses for it. Foundation
// alone has no colors (they are in AppKit, UIKit and SwiftUI), so the shell's own are one
// attribute: a style by what the text is, which the terminal turns into a color when it is shown.

extension DisplayStyle {
    /// The style a run of text is in: one of `DisplayStyle`'s roles (a keyword, a type, a flag), not
    /// a color, so what the color is, or whether there is one, is decided when the text is shown.
    public enum Attribute: AttributedStringKey {
        public typealias Value = DisplayStyle
        public static let name = "swish.displayStyle"
    }
}

extension AttributeScopes {
    public struct SwishAttributes: AttributeScope {
        public let displayStyle: DisplayStyle.Attribute
    }

    public var swish: SwishAttributes.Type { SwishAttributes.self }
}

extension AttributeDynamicLookup {
    public subscript<T: AttributedStringKey>(
        dynamicMember keyPath: KeyPath<AttributeScopes.SwishAttributes, T>
    ) -> T {
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

    /// With the terminal's escapes for each style.
    public var colored: String {
        var result = ""
        for run in runs {
            let text = String(self[run.range].characters)
            if let style = run.swish.displayStyle, !text.isEmpty {
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
