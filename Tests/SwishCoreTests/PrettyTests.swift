@testable import SwishCore
import SwishKit
import SwishStandardLibrary
import Testing

private let wide = PrettyPrinter(width: .max)
private let fileType = EnumType(name: "FileType", cases: ["file", "directory"].map { .init(name: $0) })

@Test func onOneLineItIsTheDebugDescription() {
    let status = Output(text: "hi", code: 0)
    let values: [Value] = [
        .nothing, .int(3), .string("tab\there"), .list([.int(1), .string("x"), .nothing]),
        .record(Record(["k": .string("v")])), .record(Record()), .output(status), .record(status.statusRecord),
        .enumValue(EnumValue(type: fileType, name: "directory")),
    ]
    for value in values {
        #expect(wide.format(value) == value.debugDescription)
    }
}

@Test func whatDoesNotFitBreaksOverLines() {
    let value = Value.dictionary(ValueDictionary([
        (.string("name"), .string("swish")), (.string("tags"), .list([.string("shell"), .string("swift")])),
    ]))
    #expect(PrettyPrinter(width: 30).format(value) == """
    [
      "name": "swish",
      "tags": ["shell", "swift"]
    ]
    """)
    #expect(PrettyPrinter(width: 20).format(value) == """
    [
      "name": "swish",
      "tags": [
        "shell",
        "swift"
      ]
    ]
    """)
}

@Test func multiLineStringsInsideAreBlocks() {
    let output = Value.output(Output(text: "one\ntwo \"\"\" \\ \u{1B}[1m", code: 0))
    #expect(wide.format(output) == #"""
    Output(
      text: """
        one
        two \""" \\ \u{1B}[1m
        """,
      status: Status(code: 0, signal: nil, succeeded: true)
    )
    """#)
    // On its own, a string is a literal on one line.
    #expect(wide.format(.string("a\nb")) == #""a\nb""#)
}

@Test func colorsFollowTheHighlighter() {
    let styled = PrettyPrinter(width: .max, styled: true)
    #expect(styled.format(.list([.int(1), .string("x")])) == "[\u{1B}[95m1\u{1B}[0m, \u{1B}[33m\"x\"\u{1B}[0m]")
    #expect(styled.format(.enumValue(EnumValue(type: fileType, name: "file"))) == "\u{1B}[93mFileType\u{1B}[0m.file")
}
