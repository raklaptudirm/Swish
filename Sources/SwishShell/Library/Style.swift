@_spi(Layer) import Swiit

/// What `String.styled` can make text (the shell's: the core knows only `DisplayStyle`), each with its terminal code as its raw value.
@_spi(Layer) public enum TextStyle: String, CaseIterable {
    case bold = "1", dim = "2", italic = "3", underline = "4"
    case red = "31", green = "32", yellow = "33", blue = "34", magenta = "35", cyan = "36", white = "37", gray = "90"
}

extension String {
    /// The text in colors or emphasis, plain where color is off.
    /// - Parameter styles: how to style it, as in `.bold, .red`
    @_spi(Layer) public func styled(@Rest _ styles: [TextStyle], in shell: HostContext) -> String {
        guard !styles.isEmpty, !isEmpty, shell.colorOutput else { return self }
        return "\u{1B}[\(styles.map(\.rawValue).joined(separator: ";"))m" + self + "\u{1B}[0m"
    }
}
