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

/// Runs `body` on a thread with a large stack and waits for it. Swish code
/// recurses in the interpreter, so the shell runs on such a thread (see
/// main.swift); tests use this to do the same from their small-stack threads.
func onLargeStack<T>(_ body: @escaping () throws -> T) throws -> T {
    // The caller waits for the thread, so nothing runs at the same time.
    nonisolated(unsafe) var result: Result<T, any Error>?
    nonisolated(unsafe) let body = body
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        result = Result { try body() }
        done.signal()
    }
    thread.stackSize = 256 << 20
    thread.start()
    done.wait()
    return try result!.get()
}
