import Swiit
import SwishShellLibrary
import Testing

@Test func formatsFileSizes() {
    #expect(FileSize(bytes: 532).description == "532 B")
    #expect(FileSize(bytes: 1234).description == "1.2 KB")
    #expect(FileSize(bytes: 123_456_789).description == "123 MB")
    #expect(FileSize(bytes: -2000).description == "-2.0 KB")
    // As a value it shows the same.
    #expect(FileSize(bytes: 1234).swiitValue.description == "1.2 KB")
}

@Test func fileSizesParseAndDoArithmetic() throws {
    #expect(FileSize("1024")?.bytes == 1024)
    #expect(FileSize("1.5mb")?.bytes == 1_500_000)
    #expect(FileSize("1.5 MB")?.bytes == 1_500_000)
    #expect(FileSize("2kib")?.bytes == 2048)
    #expect(FileSize("lots") == nil)
    #expect(FileSize(1.5, unit: "gb")?.bytes == 1_500_000_000)
    #expect(FileSize(1, unit: "parsecs") == nil)
    // `2.mb`: a size too large to hold is the largest there is.
    #expect(FileSize(2, multiplier: 1_000_000).bytes == 2_000_000)
    #expect(FileSize(1e30, multiplier: 1_000).bytes == Int.max)
    let kb = FileSize(bytes: 1000)
    #expect(try (kb + kb).bytes == 2000)
    #expect(try (kb * 3).bytes == 3000)
    #expect(try (kb / 4).bytes == 250)
    #expect(kb / FileSize(bytes: 500) == 2.0)
    #expect(kb < FileSize(bytes: 1001))
    #expect(throws: SwiitError.self) { try kb / 0 }
    #expect(throws: SwiitError.self) { try FileSize(bytes: .max) * 2 }
}
