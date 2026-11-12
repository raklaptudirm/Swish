import Foundation
import Swiit
import SwishLibrary

extension Status {
    /// How a child ended, from `waitpid`'s status; one that neither exited nor was signaled (which
    /// `waitpid` without `WUNTRACED` doesn't give) failed.
    init(_ wait: WaitStatus) {
        if wait.exited {
            self = .exited(wait.exitCode)
        } else if wait.signaled {
            self = .signaled(wait.signal)
        } else {
            self = .exited(1)
        }
    }
}
