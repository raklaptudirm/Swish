import Foundation

/// A line of standard input, or nil at its end.
/// - Parameter strippingNewline: leave the line's newline off
public func readLine(strippingNewline: Bool = true) -> String? {
    // A byte at a time, so nothing past the line is taken from programs
    // that read the rest.
    var bytes: [UInt8] = []
    var byte: UInt8 = 0
    while true {
        let count = read(STDIN_FILENO, &byte, 1)
        if count == -1 && errno == EINTR { continue }
        guard count == 1 else { break }
        bytes.append(byte)
        if byte == UInt8(ascii: "\n") { break }
    }
    guard !bytes.isEmpty else { return nil }
    if strippingNewline, bytes.last == UInt8(ascii: "\n") { bytes.removeLast() }
    return String(decoding: bytes, as: UTF8.self)
}
