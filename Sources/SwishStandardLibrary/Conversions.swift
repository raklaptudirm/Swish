import SwishKit

/// What text `from` can parse.
public enum InputFormat: CaseIterable {
    case json
}

/// Parses text into values.
/// - Parameter format: json
public func from(_ format: InputFormat, @Input _ text: [String]) throws -> JSON {
    switch format {
    case .json: JSON(try JSON.parse(text.joined(separator: "\n")))
    }
}
