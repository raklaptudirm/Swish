import Foundation
import Swiit

/// A redirect with its file name worked out.
enum RedirectMode: Equatable, Sendable { case read, write, append }

struct ResolvedRedirect {
    enum Action {
        case open(String, RedirectMode)
        /// Whatever the command's descriptor `n` is at this point, as in `2>&1`.
        case duplicate(Int32)
    }

    var fd: Int32
    var action: Action
}

/// The descriptors a stage runs with: each of its descriptors mapped to one
/// of the shell's. Starts from the stage's pipes; redirects then apply in
/// order, which is why `> out 2>&1` and `2>&1 > out` differ.
struct DescriptorTable {
    private(set) var map: [Int32: Int32]
    private var opened: [Int32] = []

    init(_ initial: [Int32: Int32]) {
        map = initial
    }

    /// Opens files as it goes; if one can't be opened, closes the rest and throws.
    mutating func apply(_ redirects: [ResolvedRedirect]) throws {
        for redirect in redirects {
            switch redirect.action {
            case .open(let path, let mode):
                let flags =
                    switch mode {
                    case .read: O_RDONLY
                    case .write: O_WRONLY | O_CREAT | O_TRUNC
                    case .append: O_WRONLY | O_CREAT | O_APPEND
                    }
                let fd = open(path, flags | O_CLOEXEC, 0o666)
                guard fd >= 0 else {
                    let message = "\(path): \(errorMessage(errno).lowercased())"
                    closeFiles()
                    throw RuntimeError(message)
                }
                opened.append(fd)
                map[redirect.fd] = fd
            case .duplicate(let source):
                map[redirect.fd] = self[source]
            }
        }
    }

    /// The shell's descriptor behind the stage's descriptor `fd`.
    subscript(fd: Int32) -> Int32 {
        map[fd] ?? fd
    }

    /// The files the redirects opened; the stage has its own copies once
    /// it's spawned, or is done with them once it has run.
    func closeFiles() {
        for fd in opened { close(fd) }
    }
}

extension Shell {
    /// Runs in-process code (a function, builtin, or run of Swish stages)
    /// with its redirects, through `stdoutFD` and `stderrFD`: what it writes
    /// itself, and the programs it starts, go where its redirects say.
    /// `body` gets the input (-1 for the shell's own) and output to use.
    func withRedirects<T>(
        _ redirects: [ResolvedRedirect],
        input: Int32 = -1,
        output: Int32? = nil,
        _ body: (_ input: Int32, _ output: Int32) throws -> T
    ) throws -> T {
        let output = output ?? stdoutFD
        guard !redirects.isEmpty else { return try body(input, output) }

        var table = DescriptorTable([0: input >= 0 ? input : 0, 1: output, 2: stderrFD])
        try table.apply(redirects)
        defer { table.closeFiles() }

        let saved = (stdoutFD, stderrFD)
        (stdoutFD, stderrFD) = (table[1], table[2])
        defer { (stdoutFD, stderrFD) = saved }
        let (bodyInput, bodyOutput) = (table[0] == 0 ? -1 : table[0], table[1])
        guard table[2] != saved.1 else { return try body(bodyInput, bodyOutput) }
        // What `body` raises is told where `2>` points, even after it is undone, so
        // `f 2>/dev/null` silences f's errors too.
        return try interpreter.withErrorOutput(errors(at: table[2])) {
            try body(bodyInput, bodyOutput)
        }
    }
}

/// A descriptor of its own, closed when the last error that was sent to it is gone.
private final class ErrorDescriptor: Sendable {
    let fd: Int32

    init(copying fd: Int32) { self.fd = dup(fd) }

    deinit { close(fd) }
}

extension Shell {
    /// Where errors go when `2>` points at `fd`: a copy of it, which outlives the redirect for an
    /// error that is told after it is undone.
    fileprivate func errors(at fd: Int32) -> OutputSink {
        let copy = ErrorDescriptor(copying: fd)
        return OutputSink(
            write: { writeAll(copy.fd, $0) },
            traits: { OutputSink.Traits(fd: copy.fd) }
        )
    }
}
