import SwishCore
import Foundation

/// A redirect with its file name worked out.
struct ResolvedRedirect {
    enum Action {
        case open(String, Redirect.Mode)
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
                let flags = switch mode {
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
        _ redirects: [ResolvedRedirect], input: Int32 = -1, output: Int32? = nil,
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
        do {
            return try body(table[0] == 0 ? -1 : table[0], table[1])
        } catch let error as RuntimeError where table[2] != saved.1 {
            // Reported here, while `2>` is in effect, so `f 2>/dev/null`
            // silences f's errors too.
            interpreter.report("error: \(error)")
            throw AlreadyReported(error: error)
        }
    }
}
