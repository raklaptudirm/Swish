import Swiit
import Foundation

/// Writes unbuffered, so output from the shell and its children never
/// interleaves out of order. False if the write failed, as when the
/// reader of a pipe has exited.
@discardableResult
func writeAll(_ fd: Int32, _ text: String) -> Bool {
    var text = text
    return text.withUTF8 { buffer in
        var offset = 0
        while offset < buffer.count {
            let written = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if written > 0 {
                offset += written
            } else if written == -1 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

func errorMessage(_ code: Int32) -> String {
    String(cString: strerror(code))
}

func env(_ name: String) -> String? {
    getenv(name).map { String(cString: $0) }
}
