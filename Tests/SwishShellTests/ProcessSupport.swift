@testable import Swiit
@testable import SwishShell
import Foundation

// What the tests need to know about the process they run in. In a file of
// its own: Foundation can't be imported next to Testing here.

/// This process's id.
func currentProcessID() -> Int {
    Int(ProcessInfo.processInfo.processIdentifier)
}
