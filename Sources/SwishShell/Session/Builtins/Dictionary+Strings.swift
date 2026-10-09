import Swiit
import SwishKit

extension Dictionary where Key == String, Value == SwishKit.Value {
    /// A String or list-of-Strings argument as an array; empty if absent.
    package func strings(_ key: String) -> [String] {
        switch self[key] {
        case .string(let text)?: [text]
        case .list(let items)?: items.map(\.description)
        default: []
        }
    }
}
