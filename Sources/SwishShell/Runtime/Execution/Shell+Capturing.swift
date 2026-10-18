import Swiit
import Foundation

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
        let output = interpreter.suspend { collector.finish() }
        try result.get()
        return output
    }
}

/// Copies an `OutputCollector`'s output to a descriptor, as it arrives, on a thread of its own, until the output ends
/// or it is stopped.
final class Relay: @unchecked Sendable {
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false

    init(_ collector: OutputCollector, to fd: Int32) {
        Thread.detachNewThread { [self] in
            var offset = 0
            while true {
                let (chunk, ended) = collector.bytes(from: offset, waitingUpTo: 0.05)
                if !chunk.isEmpty {
                    chunk.withUnsafeBufferPointer { buffer in
                        var written = 0
                        while written < buffer.count {
                            let count = write(fd, buffer.baseAddress! + written, buffer.count - written)
                            if count > 0 { written += count } else if count == -1 && errno == EINTR { continue } else { break }
                        }
                    }
                    offset += chunk.count
                } else if ended || lock.withLock({ stopped }) {
                    break
                }
            }
            finished.signal()
        }
    }

    /// Ends the copying once it has caught up with what is collected.
    func stop() { lock.withLock { stopped = true } }

    /// Waits for the copying to end.
    func wait() { finished.wait() }
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

    /// What was collected from `offset` on, waiting up to `timeout` seconds for some; and whether the output has ended.
    func bytes(from offset: Int, waitingUpTo timeout: TimeInterval) -> (bytes: [UInt8], ended: Bool) {
        condition.withLock {
            let deadline = Date(timeIntervalSinceNow: timeout)
            while bytes.count <= offset && !ended {
                if !condition.wait(until: deadline) { break }
            }
            return (Array(bytes[min(offset, bytes.count)...]), ended)
        }
    }

    /// Writes all of it to `fd`, what is collected already and what comes: a task awaited from the foreground shows its output.
    func relay(to fd: Int32) -> Relay { Relay(self, to: fd) }

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
