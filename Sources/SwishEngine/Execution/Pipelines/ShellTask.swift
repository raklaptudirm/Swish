import Foundation
import Swiit
import SwishLibrary

/// What the shell keeps for each task (the interpreter's task state): where its output and errors
/// go, and how its last statement went. The prompt's is the main task's; `async` and `Task { }`
/// make one each (`Interpreter.Host.makeTaskState`).
final class ShellTask: ItemErrors {
    /// Where builtins, displayed values and the last stage of a pipeline
    /// write. Redirected while capturing `$(…)`.
    var stdoutFD = STDOUT_FILENO
    /// Where errors are reported, and programs' standard error goes, while
    /// running something with `2>`.
    var stderrFD = STDERR_FILENO
    /// Problems with single items reported so far (a file `ls` couldn't read), and how many the
    /// last statement had seen.
    var itemErrors = 0
    var itemErrorsSeen = 0
    /// How the last statement ended, kept as statements run (`recordStatuses`).
    var lastStatus = Status.success
    /// Whether it's the task in the foreground, whose programs get the
    /// terminal and which reads the input: the prompt's, or a task while it's
    /// awaited from there. Set from the task awaiting it, on another thread.
    var inForeground: Bool {
        get { turn.isForeground }
        set { turn.isForeground = newValue }
    }
    let turn = Turn()

    /// Blocks until it's in the foreground, or `cancellation` is asked
    /// (false). (Through `suspend`, so the lock is let go.)
    func waitForForeground(unless cancellation: Interpreter.Cancellation) -> Bool {
        turn.waitForForeground(unless: cancellation)
    }
}

// safe: `foreground` is read and written holding `condition`
/// Whether a task has its turn at the terminal and the input, which another thread sets and a
/// waiting one is woken by. A `Mutex` cannot wait, so the flag is kept under the condition that can.
final class Turn: @unchecked Sendable {
    private var foreground = true
    private let condition = NSCondition()

    var isForeground: Bool {
        get { condition.withLock { foreground } }
        set {
            condition.withLock {
                foreground = newValue
                condition.broadcast()
            }
        }
    }

    func waitForForeground(unless cancellation: Interpreter.Cancellation) -> Bool {
        condition.withLock {
            while !foreground && !cancellation.isSet { condition.wait() }
            return foreground
        }
    }

    /// Wakes a wait for the foreground, to look again.
    func poke() { condition.withLock { condition.broadcast() } }
}
