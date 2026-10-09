import SwishKit

/// What an output stream can show, so values are laid out for it: a terminal
/// gets tables fitted to its width and in color, a file or a pipe gets every
/// character, plain.
package struct StreamTraits {
    package var isTerminal: Bool
    /// Its width in columns, when it has one.
    package var width: Int?
    /// Whether to color what's written to it.
    package var styled: Bool

    package static let plain = StreamTraits(isTerminal: false, width: nil, styled: false)

    package init(isTerminal: Bool, width: Int? = nil, styled: Bool) {
        self.isTerminal = isTerminal
        self.width = width
        self.styled = styled
    }
}

/// Where one of the interpreter's output streams goes, and what it can show.
package struct OutputSink {
    private let send: (String) -> Bool
    package let traits: () -> StreamTraits

    /// `write` says whether the text went: false once the reader has gone, as
    /// with a closed pipe. `traits` is asked each time, since where output
    /// goes can change while a script runs.
    package init(write: @escaping (String) -> Bool, traits: @escaping () -> StreamTraits = { .plain }) {
        send = write
        self.traits = traits
    }

    @discardableResult
    package func write(_ text: String) -> Bool {
        send(text)
    }

    /// Output nobody reads.
    package static var discard: OutputSink { OutputSink(write: { _ in true }) }
}

/// Why the host asked the program to stop. The interpreter only carries it:
/// whoever asked reads it back from the `Interrupted` error. (The shell's is
/// the signal number, so it can end by that signal.)
package struct StopReason {
    package var code: Int32

    package init(code: Int32) {
        self.code = code
    }
}

/// How the interpreter is run: where its output goes and how to tell it to
/// stop. This is the plumbing every embedder supplies, and all there is to
/// it: what a script can name (`env`, `jobs`, functions, types) is registered,
/// not passed here, and what syntax it accepts is a layer on top. The
/// defaults do nothing, so a host gives only what it wants. Modeled on how
/// other embeddable languages are configured (Wren's write and error
/// callbacks, Rhai's progress hook); see Docs/Design/embedding.md.
package struct SwishHost {
    package var output: OutputSink = .discard
    package var error: OutputSink = .discard
    /// Asked at each step: a reason to stop, if there is one.
    package var interrupt: () -> StopReason? = { nil }

    package init(output: OutputSink = .discard, error: OutputSink = .discard, interrupt: @escaping () -> StopReason? = { nil }) {
        self.output = output
        self.error = error
        self.interrupt = interrupt
    }
}
