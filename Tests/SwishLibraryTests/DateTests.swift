import Foundation
import Testing

@testable import SwishLibrary

// What a script can do with a `Date` beyond Swift's own.

@Test func aDateDoesSumsInSeconds() {
    let date = Date(timeIntervalSince1970: 100)
    #expect(date + 60 == Date(timeIntervalSince1970: 160))
    #expect(date - 40 == Date(timeIntervalSince1970: 60))
    #expect((date + 90) - date == 90.0)
}

@Test func aDateIsReadFromISOTextAndNothingElse() {
    #expect(Date("1970-01-01T00:01:40Z") == Date(timeIntervalSince1970: 100))
    #expect(Date("2026-09-27T14:03:00Z") != nil)
    #expect(Date("nope") == nil)
    #expect(Date("1970-01-01") == nil)
}

@Test func aDateIsShownToTheSecondInLocalTimeAndATableShowsItToTheMinute() {
    let date = Date(timeIntervalSince1970: 100)
    #expect(date.shown.count == 19)
    #expect(date.shown.contains(" "))
    #expect(date.cell == String(date.shown.prefix(16)))
}
