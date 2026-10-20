import SystemPackage
import Swiit

// How a path shows: its text, unquoted, unlike a String.

extension FilePath: SwiitDisplayed {
    public var swiitDescription: String { string }
    /// As Swift writes it, quoted: the text is for showing, this is for code.
    public var swiitDebugDescription: String { String(reflecting: self) }
}

extension FilePath.Component: SwiitDisplayed {
    public var swiitDescription: String { string }
    public var swiitDebugDescription: String { String(reflecting: self) }
}
