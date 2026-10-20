import Swiit

/// What `String.styled` can make text (the shell's: the core knows only `DisplayStyle`), each with its terminal code as its raw value.
enum TextStyle: String, CaseIterable {
    case bold = "1", dim = "2", italic = "3", underline = "4"
    case red = "31", green = "32", yellow = "33", blue = "34", magenta = "35", cyan = "36", white = "37", gray = "90"
}
