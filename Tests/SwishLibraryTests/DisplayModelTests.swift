import Foundation
import Swiit
import SystemPackage
import Testing

@testable import SwishLibrary

// How a type says what a table does with it: the model the library's types use.

@Test func aColumnSaysHowItIsStyledWithOneThing() {
    #expect(DisplayColumn("name").styling == .none)
    #expect(DisplayColumn("name", styledBy: "type").styling == .byField("type"))
    #expect(DisplayColumn("name", style: .green).styling == .fixed(.green))
    // A name alone is a column, as a string literal.
    let column: DisplayColumn = "size"
    #expect(column.name == "size")
    #expect(column.styling == .none)
}

@Test func segmentsAreTextInStylesAndEscapesAreAddedOnlyWhenAsked() {
    let segments = [Segment("a", .red), Segment(" "), Segment("b")]
    #expect(segments.text(styled: false) == "a b")
    let styled = segments.text(styled: true)
    #expect(styled.contains("\u{1B}["))
    #expect(styled.contains("a"))
}

@Test func aTypeSaysOnlyWhatIsTrueOfIt() {
    // A size is a number: a column of them lines up on the right.
    #expect(FileSize(bytes: 1).shape.isNumeric)
    #expect(FileSize(bytes: 1).shape.role == .constant)
    // A path is shown in its own style.
    #expect(FilePath("/a").shape.role == .path)
    #expect(FilePath("/a").cell == "/a")
    // An output with nothing in it has nothing to show.
    #expect(Output(text: "", status: .success).shape.isEmpty)
    #expect(!Output(text: "x", status: .success).shape.isEmpty)
    // The rest takes the defaults.
    let plain = DisplayShape()
    #expect(plain.role == nil && !plain.isNumeric && !plain.isEmpty)
}

@Test func anOutputIsOneCellWithItsNewlinesShown() {
    #expect(Output(text: "a\nb", status: .success).cell == "a↵b")
}

@Test func fileTypesAreStyledByWhatTheyAre() {
    #expect(FileType.directory.displayStyle != nil)
    #expect(FileType.symlink.displayStyle != nil)
    #expect(FileType.file.displayStyle == nil)
}
