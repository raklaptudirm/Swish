import Foundation
import Swiit

// What a script can do with a `Date` beyond Swift's own: write one as ISO 8601 text, and do sums in seconds.

extension Date {
    /// A date written as ISO 8601 text, like `2026-09-27T14:03:00Z`; nil for anything else.
    init?(isoText text: String) {
        guard let date = try? Date(text, strategy: .iso8601) else { return nil }
        self = date
    }

    /// How many seconds apart two dates are: `later - earlier`.
    static func - (lhs: Date, rhs: Date) -> TimeInterval { lhs.timeIntervalSince(rhs) }

    /// A date some whole seconds later or earlier, as `date + 60`.
    static func + (lhs: Date, rhs: Int) -> Date { lhs.addingTimeInterval(TimeInterval(rhs)) }
    static func - (lhs: Date, rhs: Int) -> Date { lhs.addingTimeInterval(-TimeInterval(rhs)) }

    /// To the second, in local time; a table shows it to the minute.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var shown: String { Date.formatter.string(from: self) }

    static let native = NativeType.Builder<Date>("Date", parse: { Date(isoText: $0) })
        .failableInitializer { (text: String) in Date(isoText: text) }
        .static("-", labels: [nil, nil]) { (a: Date, b: Date) -> Double in a - b }
        .static("+", labels: [nil, nil]) { (a: Date, b: Int) -> Date in a + b }
        .static("-", labels: [nil, nil]) { (a: Date, b: Int) -> Date in a - b }
}

extension Date: SwiitDisplayed {
    public var swiitDescription: String { shown }
}
