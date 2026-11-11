import Foundation

// What a test reads of what a shell wrote to the process's own standard output or error.

/// What `body` writes to standard output.
func capturingStandardOutput(_ body: () throws -> Void) throws -> String {
    try capturing(STDOUT_FILENO, body)
}

/// What `body` writes to standard error.
func capturingStandardError(_ body: () throws -> Void) throws -> String {
    try capturing(STDERR_FILENO, body)
}

private func capturing(_ descriptor: Int32, _ body: () throws -> Void) throws -> String {
    var fds: [Int32] = [0, 0]
    precondition(pipe(&fds) == 0)
    let saved = dup(descriptor)
    dup2(fds[1], descriptor)
    close(fds[1])
    defer { dup2(saved, descriptor); close(saved) }

    let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
    nonisolated(unsafe) var collected = Data()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global()
        .async {
            collected = reader.readDataToEndOfFile()
            finished.signal()
        }
    do { try body() } catch {
        dup2(saved, descriptor)
        _ = finished.wait(timeout: .now() + 1)
        throw error
    }
    // Closing the write end (the descriptor itself) lets the reader reach the end.
    dup2(saved, descriptor)
    finished.wait()
    return String(decoding: collected, as: UTF8.self)
}
