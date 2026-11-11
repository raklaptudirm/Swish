import Foundation
import Swiit

// What a descriptor is to show values on: a terminal of some size, or a file or pipe.

/// What a client asks of the terminal it draws on.
public enum Terminal {
    /// The width of the terminal `descriptor` is, in columns, if it is one.
    public static func width(of descriptor: Int32) -> Int? {
        terminalWidth(descriptor)
    }

    /// The height of the terminal `descriptor` is, in rows, if it is one.
    public static func height(of descriptor: Int32) -> Int? {
        terminalHeight(descriptor)
    }

    /// Writes unbuffered, so output from the shell and its children never interleaves out of
    /// order. Says whether the write worked: not when the reader of a pipe has exited.
    @discardableResult
    public static func write(_ text: String, to descriptor: Int32) -> Bool {
        writeAll(descriptor, text)
    }
}

extension OutputSink.Traits {
    /// What the descriptor is: a terminal of some width, or a file or pipe.
    init(fd: Int32) {
        self.init(
            isTerminal: isatty(fd) != 0,
            width: terminalWidth(fd),
            isStyled: DisplayStyle.enabled(for: fd)
        )
    }
}

extension DisplayFormatter {
    /// Writes to `fd`, fitting the terminal and styling the header when it
    /// is one. A file gets every character: nothing is cut to fit.
    convenience init(fd: Int32, registry: DisplayRegistry) {
        self.init(traits: OutputSink.Traits(fd: fd), registry: registry) { writeAll(fd, $0) }
    }

    /// Rows for another program to read, as in `ls | grep x`: the view's
    /// columns, no header, nothing cut short.
    static func forProgram(fd: Int32, registry: DisplayRegistry) -> DisplayFormatter {
        DisplayFormatter(header: false, columnCap: .max, registry: registry) { writeAll(fd, $0) }
    }
}

/// The width of the terminal `fd` is, if it is one.
func terminalWidth(_ fd: Int32) -> Int? {
    var size = winsize()
    // TIOCGWINSZ is a UInt on macOS and an Int32 on Linux.
    guard isatty(fd) != 0, ioctl(fd, UInt(TIOCGWINSZ), &size) == 0, size.ws_col > 0 else {
        return nil
    }
    return Int(size.ws_col)
}

/// The height of the terminal `fd` is, in rows, if it is one.
func terminalHeight(_ fd: Int32) -> Int? {
    var size = winsize()
    guard isatty(fd) != 0, ioctl(fd, UInt(TIOCGWINSZ), &size) == 0, size.ws_row > 0 else {
        return nil
    }
    return Int(size.ws_row)
}

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
