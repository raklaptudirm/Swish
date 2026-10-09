import Swiit
import Foundation
import SwishKit

extension Shell {
    // MARK: Capturing output

    /// Runs `body` with standard output redirected into a string, as `$(…)` does.
    func capturing(_ body: () throws -> Void) throws -> String {
        guard let pipe = makePipe() else { throw RuntimeError("pipe: \(errorMessage(errno))") }
        // Drain concurrently, so output larger than the pipe buffer can't
        // deadlock against the wait for the command to finish.
        let collector = OutputCollector(reading: pipe.read)
        let savedOutput = stdoutFD
        stdoutFD = pipe.write
        let result = Result { try body() }
        stdoutFD = savedOutput
        close(pipe.write)
        let output = collector.finish()
        try result.get()
        return output
    }
}

/// Reads a pipe on a thread of its own, and keeps all of it: as one String
/// when it ends, or line by line as lines complete.
final class OutputCollector: @unchecked Sendable {
    /// What reading the next line found.
    enum Line {
        case line(String)
        /// The output has ended, and every line has been read.
        case end
        /// No line has completed yet.
        case pending
    }

    private let condition = NSCondition()
    private var bytes: [UInt8] = []
    private var ended = false
    /// Where the next unread line starts.
    private var consumed = 0

    init(reading fd: Int32) {
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    condition.withLock {
                        bytes += buffer[..<count]
                        condition.broadcast()
                    }
                } else if count == -1 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
            close(fd)
            condition.withLock {
                ended = true
                condition.broadcast()
            }
        }
    }

    /// All of it, once it ends.
    func finish() -> String {
        condition.withLock {
            while !ended { condition.wait() }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    /// The next line, waiting up to `timeout` seconds for one to complete.
    /// What's left when the output ends without a newline is a line too.
    func nextLine(timeout: TimeInterval) -> Line {
        condition.withLock {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while true {
                if let newline = bytes[consumed...].firstIndex(of: UInt8(ascii: "\n")) {
                    defer { consumed = newline + 1 }
                    return .line(String(decoding: bytes[consumed..<newline], as: UTF8.self))
                }
                if ended {
                    guard consumed < bytes.count else { return .end }
                    defer { consumed = bytes.count }
                    return .line(String(decoding: bytes[consumed...], as: UTF8.self))
                }
                if !condition.wait(until: deadline) { return .pending }
            }
        }
    }
}
