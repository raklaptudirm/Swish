import Foundation

// Coloring what the reader has read: the highlight spans it keeps.

extension Reader {
    mutating func mark(_ kind: HighlightKind, from start: Int, to end: Int? = nil) {
        let end = min(end ?? pos, chars.count)
        if start < end { spans.append(HighlightSpan(range: start..<end, kind: kind)) }
    }

    /// The Swift in a slice of this text, cured; its highlighting joins this reader's. `prefix`:
    /// characters put before the slice that are not in the text.
    mutating func cureSlice(
        _ slice: String,
        from start: Int,
        prefix: Int = 0,
        asExpression: Bool = true
    ) throws -> String {
        let cured = try front.cureWithSpans(
            slice,
            names: names.snapshot(atByte: text.byteOf[min(start, text.count)]),
            asExpression: asExpression
        )
        for span in cured.spans where span.range.lowerBound >= prefix {
            spans.append(
                HighlightSpan(
                    range: (span.range.lowerBound - prefix + start)..<(span.range.upperBound
                        - prefix + start),
                    kind: span.kind
                )
            )
        }
        return cured.text
    }
}
