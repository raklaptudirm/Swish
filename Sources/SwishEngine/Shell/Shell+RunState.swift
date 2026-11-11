import Foundation

extension Shell {
    /// What a run of source leaves behind for the next step to read: how it was stopped, where it
    /// is from, and the source an error shows a line of.
    struct RunState {
        /// A `try!` failed in a script, which stops it.
        var scriptStopped = false

        /// The signal that stopped the script, which it then ends by.
        var endingSignal: Int32?

        /// The signal that asked the run to stop, as the run is stopping.
        var stoppedBySignal: Int32?

        /// The running script's directory; nil at the prompt.
        var scriptDirectory: String?

        /// The source being run, so an error can show the line it is in (and the file it is from,
        /// if it is one).
        var diagnosticSource: (text: String, path: String?)?
    }
}
